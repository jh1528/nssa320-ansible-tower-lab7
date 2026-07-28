#!/usr/bin/env bash
#
# NSSA320 Lab 7 - Managed Linux Host Setup
# File: scripts/setup-managed-hosts.sh
#
# Purpose:
#   Prepares ansible1 and ansible2 for command-line Ansible and AWX access.
#
# Scope:
#   Linux managed hosts only:
#     - ansible1
#     - ansible2
#
#   Ubuntu and Windows are intentionally excluded.
#
# Safety:
#   - Supports --dry-run and --apply.
#   - Must run as the normal student user, not with sudo.
#   - Reuses an existing ED25519 key pair.
#   - Never overwrites an existing SSH key.
#   - Stops if only one half of the configured key pair exists.
#   - Does not configure passwordless sudo.
#   - Does not store passwords or private keys in the repository.
#
# RICE Notes:
#   Reproducibility - performs the same managed-host workflow each run.
#   Idempotency     - reuses keys and rewrites inventory only when needed.
#   Composability   - keeps SSH setup separate from privilege escalation.
#   Evolvability    - supports CLI validation before AWX configuration.
#
# Version History:
#   v2.1 - Clean Lab 7 replacement based on the Lab 4 workflow.
#          Removed Ubuntu and separate service-account creation.
#          Standardized managed hosts under the linux inventory group.
#          Added SSH-key and Ansible connectivity verification.
#   v1.0 - Initial Lab 7 migration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Shared configuration and libraries
# ---------------------------------------------------------------------------

source "${REPO_ROOT}/config/lab7.conf"
source "${REPO_ROOT}/config/managed-hosts.conf"
source "${REPO_ROOT}/lib/common.sh"
source "${REPO_ROOT}/lib/evidence.sh"

SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF_USAGE
Usage:
  ${SCRIPT_NAME} --dry-run
  ${SCRIPT_NAME} --apply
  ${SCRIPT_NAME} --help

Description:
  Prepares the Lab 7 Rocky Linux managed hosts for Ansible CLI and AWX access.

Modes:
  --dry-run   Show what would be checked or changed without changing hosts.
  --apply     Create or update inventory, prepare SSH keys, and verify access.
  --help      Display this help message.

Managed-host workflow:
  1. Confirm normal-user execution.
  2. Validate required commands and configuration.
  3. Create or update the Lab 7 inventory.
  4. Validate the linux inventory group.
  5. Verify initial SSH access as the student user.
  6. Reuse or create an ED25519 SSH key pair.
  7. Copy the public key to ansible1 and ansible2.
  8. Verify passwordless key-based SSH access.
  9. Verify Ansible ping connectivity.

Passwordless sudo is configured separately with:
  ./scripts/setup-privilege-escalation.sh --apply
EOF_USAGE
}

# ---------------------------------------------------------------------------
# Context and validation
# ---------------------------------------------------------------------------

show_managed_host_context() {
  local host

  step "Lab 7 managed-host setup context"

  info "Workflow: ${MANAGED_HOSTS_NAME}"
  info "Version: ${MANAGED_HOSTS_VERSION}"
  info "Repository root: ${REPO_ROOT}"
  info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  info "Inventory group: ${MANAGED_HOSTS_LINUX_GROUP}"
  info "Remote user: ${MANAGED_HOSTS_REMOTE_USER}"
  info "SSH private key: ${MANAGED_HOSTS_SSH_KEY_PATH}"
  info "SSH public key: ${MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH}"
  info "Evidence directory: ${MANAGED_HOSTS_EVIDENCE_DIR}"
  info "Archive directory: ${MANAGED_HOSTS_ARCHIVE_DIR}"

  info "Managed Linux hosts:"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "  - ${host}"
  done
}

check_required_commands() {
  local command_name

  step "Checking managed-host setup commands"

  for command_name in "${MANAGED_HOSTS_REQUIRED_COMMANDS[@]}"; do
    require_command "$command_name"
  done

  pass "All required managed-host commands are available"
}

validate_managed_host_configuration() {
  step "Validating managed-host configuration"

  [[ -n "${MANAGED_HOSTS_NAME:-}" ]] \
    || die "MANAGED_HOSTS_NAME is not configured"

  [[ -n "${MANAGED_HOSTS_VERSION:-}" ]] \
    || die "MANAGED_HOSTS_VERSION is not configured"

  [[ -n "${MANAGED_HOSTS_INVENTORY_FILE:-}" ]] \
    || die "MANAGED_HOSTS_INVENTORY_FILE is not configured"

  [[ -n "${MANAGED_HOSTS_INVENTORY_CONTENT:-}" ]] \
    || die "MANAGED_HOSTS_INVENTORY_CONTENT is not configured"

  [[ -n "${MANAGED_HOSTS_LINUX_GROUP:-}" ]] \
    || die "MANAGED_HOSTS_LINUX_GROUP is not configured"

  [[ -n "${MANAGED_HOSTS_REMOTE_USER:-}" ]] \
    || die "MANAGED_HOSTS_REMOTE_USER is not configured"

  [[ -n "${MANAGED_HOSTS_SSH_KEY_PATH:-}" ]] \
    || die "MANAGED_HOSTS_SSH_KEY_PATH is not configured"

  [[ -n "${MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH:-}" ]] \
    || die "MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH is not configured"

  [[ -n "${MANAGED_HOSTS_SSH_CONNECT_TIMEOUT_SECONDS:-}" ]] \
    || die "MANAGED_HOSTS_SSH_CONNECT_TIMEOUT_SECONDS is not configured"

  [[ -n "${MANAGED_HOSTS_EVIDENCE_DIR:-}" ]] \
    || die "MANAGED_HOSTS_EVIDENCE_DIR is not configured"

  [[ -n "${MANAGED_HOSTS_ARCHIVE_DIR:-}" ]] \
    || die "MANAGED_HOSTS_ARCHIVE_DIR is not configured"

  [[ -n "${MANAGED_HOSTS_SETUP_OUTPUT:-}" ]] \
    || die "MANAGED_HOSTS_SETUP_OUTPUT is not configured"

  [[ "${#MANAGED_HOSTS_LINUX[@]}" -gt 0 ]] \
    || die "No Linux managed hosts are configured"

  pass "Managed-host configuration is valid"
}

# ---------------------------------------------------------------------------
# Inventory management
# ---------------------------------------------------------------------------

inventory_matches_expected_content() {
  local current_content
  local expected_content

  [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]] || return 1

  current_content="$(cat "$MANAGED_HOSTS_INVENTORY_FILE")"
  expected_content="${MANAGED_HOSTS_INVENTORY_CONTENT%$'\n'}"

  [[ "$current_content" == "$expected_content" ]]
}

create_or_update_inventory() {
  local inventory_directory

  step "Creating or updating the Lab 7 inventory"

  inventory_directory="$(dirname "$MANAGED_HOSTS_INVENTORY_FILE")"

  mkdir -p "$inventory_directory" \
    || die "Failed to create inventory directory: ${inventory_directory}"

  if inventory_matches_expected_content; then
    pass "Inventory already matches the expected Lab 7 content"
    info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
    return 0
  fi

  if [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    warn "Inventory differs from the expected Lab 7 configuration"
    info "Rewriting inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  else
    info "Creating inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  fi

  printf '%s' "$MANAGED_HOSTS_INVENTORY_CONTENT" \
    > "$MANAGED_HOSTS_INVENTORY_FILE" \
    || die "Failed to write inventory: ${MANAGED_HOSTS_INVENTORY_FILE}"

  pass "Inventory file is ready: ${MANAGED_HOSTS_INVENTORY_FILE}"
}

validate_inventory() {
  local inventory_graph
  local host

  step "Validating the Lab 7 Ansible inventory"

  require_file "$MANAGED_HOSTS_INVENTORY_FILE"

  inventory_graph="$(
    ansible-inventory \
      -i "$MANAGED_HOSTS_INVENTORY_FILE" \
      --graph
  )" || die "Ansible inventory validation failed"

  printf '%s\n' "$inventory_graph"

  grep -Fq -- "@${MANAGED_HOSTS_LINUX_GROUP}:" <<< "$inventory_graph" \
    || die "Inventory group is missing: ${MANAGED_HOSTS_LINUX_GROUP}"

  pass "Inventory contains group: ${MANAGED_HOSTS_LINUX_GROUP}"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    grep -Fq -- "--${host}" <<< "$inventory_graph" \
      || die "Inventory host is missing: ${host}"

    pass "Inventory contains managed host: ${host}"
  done

  pass "Lab 7 inventory validation completed successfully"
}

# ---------------------------------------------------------------------------
# SSH access
# ---------------------------------------------------------------------------

verify_basic_ssh_access() {
  local host

  step "Verifying initial SSH access"

  info "Remote user: ${MANAGED_HOSTS_REMOTE_USER}"
  info "First-time host-key prompts and password prompts are allowed."

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Testing SSH access to ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    ssh \
      -o ConnectTimeout="${MANAGED_HOSTS_SSH_CONNECT_TIMEOUT_SECONDS}" \
      "${MANAGED_HOSTS_REMOTE_USER}@${host}" \
      'printf "remote hostname: %s\nremote user: %s\nremote date: %s\n" "$(hostname)" "$(whoami)" "$(date)"' \
      || die "Basic SSH access failed: ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    pass "Basic SSH access succeeded: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done
}

ensure_ed25519_key_pair() {
  local private_key
  local public_key
  local ssh_directory
  local key_comment

  step "Checking the local ED25519 SSH key pair"

  private_key="$MANAGED_HOSTS_SSH_KEY_PATH"
  public_key="$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH"
  ssh_directory="$(dirname "$private_key")"
  key_comment="${USER}@$(hostname)-nssa320-lab7"

  if [[ -f "$private_key" && -f "$public_key" ]]; then
    pass "Existing ED25519 SSH key pair found"
    info "Reusing private key: ${private_key}"
    info "Reusing public key: ${public_key}"
    return 0
  fi

  if [[ -f "$private_key" && ! -f "$public_key" ]]; then
    die "Private key exists, but public key is missing: ${public_key}"
  fi

  if [[ ! -f "$private_key" && -f "$public_key" ]]; then
    die "Public key exists, but private key is missing: ${private_key}"
  fi

  info "No ED25519 key pair exists at the configured path"
  info "Creating a new ED25519 key pair for Lab 7 automation"

  mkdir -p "$ssh_directory" \
    || die "Failed to create SSH directory: ${ssh_directory}"

  chmod 700 "$ssh_directory" \
    || die "Failed to set SSH directory permissions: ${ssh_directory}"

  ssh-keygen \
    -t ed25519 \
    -f "$private_key" \
    -N "" \
    -C "$key_comment" \
    || die "Failed to generate ED25519 SSH key pair"

  chmod 600 "$private_key" \
    || die "Failed to set private-key permissions: ${private_key}"

  chmod 644 "$public_key" \
    || die "Failed to set public-key permissions: ${public_key}"

  [[ -f "$private_key" && -f "$public_key" ]] \
    || die "ED25519 key generation did not produce both required files"

  pass "ED25519 SSH key pair created successfully"
  info "Private key: ${private_key}"
  info "Public key: ${public_key}"
}

copy_public_key_to_managed_hosts() {
  local host

  step "Copying the ED25519 public key to managed hosts"

  require_file "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH"

  info "You may be prompted for the student password on each host."

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Installing the public key on ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    ssh-copy-id \
      -i "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH" \
      "${MANAGED_HOSTS_REMOTE_USER}@${host}" \
      || die "Failed to install the public key on ${host}"

    pass "Public key is installed: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done
}

verify_key_based_ssh_access() {
  local host

  step "Verifying passwordless ED25519 SSH access"

  info "BatchMode=yes prevents SSH from requesting a password."

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Testing key authentication to ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    ssh \
      -i "$MANAGED_HOSTS_SSH_KEY_PATH" \
      -o BatchMode=yes \
      -o PasswordAuthentication=no \
      -o ConnectTimeout="${MANAGED_HOSTS_SSH_CONNECT_TIMEOUT_SECONDS}" \
      "${MANAGED_HOSTS_REMOTE_USER}@${host}" \
      'printf "remote hostname: %s\nremote user: %s\nauthentication: ssh-key\n" "$(hostname)" "$(whoami)"' \
      || die "Key-based SSH access failed: ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    pass "Key-based SSH access succeeded: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done
}

# ---------------------------------------------------------------------------
# Ansible connectivity
# ---------------------------------------------------------------------------

verify_ansible_connectivity() {
  step "Verifying Ansible connectivity to managed Linux hosts"

  ansible \
    -i "$MANAGED_HOSTS_INVENTORY_FILE" \
    "$MANAGED_HOSTS_LINUX_GROUP" \
    -m ansible.builtin.ping \
    -u "$MANAGED_HOSTS_REMOTE_USER" \
    --private-key "$MANAGED_HOSTS_SSH_KEY_PATH" \
    || die "Ansible ping failed for the Lab 7 Linux group"

  pass "Ansible connectivity succeeded for all Linux managed hosts"
}

# ---------------------------------------------------------------------------
# Evidence compatibility
# ---------------------------------------------------------------------------

archive_previous_setup_evidence() {
  if declare -F archive_existing_evidence >/dev/null 2>&1; then
    archive_existing_evidence \
      "$MANAGED_HOSTS_SETUP_OUTPUT" \
      "$MANAGED_HOSTS_ARCHIVE_DIR" \
      "managed-hosts-setup"
    return 0
  fi

  if declare -F archive_existing_log >/dev/null 2>&1; then
    archive_existing_log \
      "$MANAGED_HOSTS_SETUP_OUTPUT" \
      "$MANAGED_HOSTS_ARCHIVE_DIR" \
      "managed-hosts-setup"
    return 0
  fi

  warn "No compatible evidence archive function was found"
  warn "Existing setup evidence will not be archived"
}

# ---------------------------------------------------------------------------
# Dry-run workflow
# ---------------------------------------------------------------------------

dry_run() {
  local host

  step "Lab 7 managed-host dry run starting"

  require_not_root
  show_managed_host_context
  check_required_commands
  validate_managed_host_configuration

  step "Dry-run inventory plan"

  if [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    info "Inventory exists: ${MANAGED_HOSTS_INVENTORY_FILE}"

    if inventory_matches_expected_content; then
      pass "Inventory already matches the expected Lab 7 content"
    else
      warn "Would rewrite the inventory because its content differs"
    fi
  else
    warn "Would create inventory: ${MANAGED_HOSTS_INVENTORY_FILE}"
  fi

  step "Dry-run SSH-access plan"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Would verify initial SSH access: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done

  step "Dry-run ED25519 key plan"

  if [[ -f "$MANAGED_HOSTS_SSH_KEY_PATH" && \
        -f "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH" ]]; then
    pass "Would reuse the existing ED25519 key pair"
  elif [[ ! -f "$MANAGED_HOSTS_SSH_KEY_PATH" && \
          ! -f "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH" ]]; then
    warn "Would create a new ED25519 key pair"
  else
    fail "The configured SSH key pair is incomplete"
    info "Private key: ${MANAGED_HOSTS_SSH_KEY_PATH}"
    info "Public key: ${MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH}"
    return 1
  fi

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Would install the public key on ${MANAGED_HOSTS_REMOTE_USER}@${host}"
    info "Would verify non-interactive SSH access to ${host}"
  done

  info "Would run Ansible ping against group: ${MANAGED_HOSTS_LINUX_GROUP}"

  step "Lab 7 managed-host dry run complete"
  pass "No changes were made"
}

# ---------------------------------------------------------------------------
# Apply workflow
# ---------------------------------------------------------------------------

apply_actions() {
  step "Lab 7 managed-host apply starting"

  require_not_root
  show_managed_host_context
  check_required_commands
  validate_managed_host_configuration

  create_or_update_inventory
  validate_inventory
  verify_basic_ssh_access
  ensure_ed25519_key_pair
  copy_public_key_to_managed_hosts
  verify_key_based_ssh_access
  verify_ansible_connectivity

  step "Lab 7 managed-host apply complete"

  pass "Managed Linux host preparation completed successfully"
  info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  info "Evidence saved to: ${MANAGED_HOSTS_SETUP_OUTPUT}"
  info "Next workflow:"
  info "  ./scripts/setup-privilege-escalation.sh --apply"
}

apply_setup() {
  prepare_evidence_directories \
    "$MANAGED_HOSTS_EVIDENCE_DIR" \
    "$MANAGED_HOSTS_ARCHIVE_DIR"

  archive_previous_setup_evidence

  exec > >(tee "$MANAGED_HOSTS_SETUP_OUTPUT") 2>&1

  apply_actions
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  if [[ "$#" -ne 1 ]]; then
    fail "Exactly one mode is required"
    usage
    exit 2
  fi

  case "$1" in
    --dry-run)
      dry_run
      ;;

    --apply)
      apply_setup
      ;;

    -h|--help)
      usage
      ;;

    *)
      fail "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
}

main "$@"
