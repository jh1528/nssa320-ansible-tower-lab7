#!/usr/bin/env bash
#
# NSSA320 Lab 7 - Managed Linux Host Setup
# File: scripts/setup-managed-hosts.sh
#
# Purpose:
#   Prepares ansible1 and ansible2 for command-line Ansible and AWX access.
#
#   The script:
#     - creates or validates the Lab 7 Linux inventory
#     - verifies password-based SSH access using the student account
#     - safely creates or reuses an ED25519 SSH key pair
#     - copies the public key to both managed hosts
#     - verifies non-interactive key-based SSH access
#
# Scope:
#   Lab 7 Linux managed hosts only:
#
#     ansible1
#     ansible2
#
#   Ubuntu and Windows are intentionally excluded.
#
# Safety:
#   Supports --dry-run and --apply.
#   Must run as the normal student user, not with sudo.
#   Never overwrites an existing SSH key.
#   Stops when only one half of an SSH key pair exists.
#   Does not configure passwordless sudo.
#   Does not store passwords or private keys in the repository.
#
# Design:
#   The existing student account is used for both initial SSH access and
#   later AWX Machine Credential authentication.
#
#   Passwordless sudo remains the responsibility of:
#
#     scripts/setup-privilege-escalation.sh
#
# RICE Notes:
#   Reproducibility - performs the same preparation sequence each run.
#   Idempotency     - reuses valid keys and avoids unnecessary inventory writes.
#   Composability   - keeps SSH preparation separate from privilege escalation.
#   Evolvability    - aligns the migrated framework with the Lab 7 AWX workflow.
#
# Version History:
#   v2.0 - Removed Ubuntu and separate ansible-service-account logic.
#          Standardized the inventory group as linux.
#          Added safe ED25519 key creation, deployment, and verification.
#   v1.0 - Initial Lab 7 migration from the earlier managed-host workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Load shared configuration and libraries
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
  cat <<EOF
Usage:
  ${SCRIPT_NAME} --dry-run
  ${SCRIPT_NAME} --apply
  ${SCRIPT_NAME} --help

Description:
  Prepares the Lab 7 Rocky Linux hosts for Ansible CLI and AWX access.

Modes:
  --dry-run   Display the planned validation and configuration actions.
  --apply     Create the inventory, prepare ED25519 authentication, and verify it.
  --help      Display this help message.

Managed-host setup actions:
  1. Confirm normal-user execution.
  2. Validate required local commands and configuration.
  3. Create or update inventory.inv.
  4. Validate the linux inventory group.
  5. Verify initial SSH access as student.
  6. Reuse or create an ED25519 SSH key pair.
  7. Copy the public key to ansible1 and ansible2.
  8. Verify passwordless key-based SSH access.

Passwordless sudo is configured separately with:
  ./scripts/setup-privilege-escalation.sh --apply
EOF
}

# ---------------------------------------------------------------------------
# Context and configuration validation
# ---------------------------------------------------------------------------

show_managed_host_context() {
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

  local host
  info "Managed hosts:"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "  - ${host}"
  done
}

check_required_commands() {
  step "Checking managed-host setup commands"

  local command_name

  for command_name in "${MANAGED_HOSTS_REQUIRED_COMMANDS[@]}"; do
    require_command "$command_name"
  done

  pass "All required managed-host commands are available"
}

validate_managed_host_configuration() {
  step "Validating managed-host configuration"

  [[ -n "${MANAGED_HOSTS_INVENTORY_FILE:-}" ]] \
    || die "MANAGED_HOSTS_INVENTORY_FILE is not configured"

  [[ -n "${MANAGED_HOSTS_LINUX_GROUP:-}" ]] \
    || die "MANAGED_HOSTS_LINUX_GROUP is not configured"

  [[ -n "${MANAGED_HOSTS_REMOTE_USER:-}" ]] \
    || die "MANAGED_HOSTS_REMOTE_USER is not configured"

  [[ -n "${MANAGED_HOSTS_SSH_KEY_PATH:-}" ]] \
    || die "MANAGED_HOSTS_SSH_KEY_PATH is not configured"

  [[ -n "${MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH:-}" ]] \
    || die "MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH is not configured"

  [[ "${#MANAGED_HOSTS_LINUX[@]}" -gt 0 ]] \
    || die "No Linux managed hosts are configured"

  pass "Managed-host configuration is valid"
}

# ---------------------------------------------------------------------------
# Inventory management
# ---------------------------------------------------------------------------

create_or_update_inventory() {
  step "Creating or updating the Lab 7 inventory"

  local inventory_directory
  local current_content
  local expected_content

  inventory_directory="$(dirname "$MANAGED_HOSTS_INVENTORY_FILE")"
  expected_content="${MANAGED_HOSTS_INVENTORY_CONTENT%$'\n'}"

  mkdir -p "$inventory_directory" \
    || die "Failed to create inventory directory: ${inventory_directory}"

  if [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    current_content="$(cat "$MANAGED_HOSTS_INVENTORY_FILE")"

    if [[ "$current_content" == "$expected_content" ]]; then
      pass "Inventory already matches the expected Lab 7 content"
      info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
      return 0
    fi

    warn "Inventory content differs from the expected Lab 7 configuration"
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
  step "Validating the Lab 7 Ansible inventory"

  require_file "$MANAGED_HOSTS_INVENTORY_FILE"

  ansible-inventory \
    -i "$MANAGED_HOSTS_INVENTORY_FILE" \
    --graph \
    || die "Ansible inventory validation failed"

  if ! ansible-inventory \
      -i "$MANAGED_HOSTS_INVENTORY_FILE" \
      --graph |
      grep -Fq -- "@${MANAGED_HOSTS_LINUX_GROUP}:"; then
    die "Inventory group is missing: ${MANAGED_HOSTS_LINUX_GROUP}"
  fi

  local host

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    if ! ansible-inventory \
        -i "$MANAGED_HOSTS_INVENTORY_FILE" \
        --graph |
        grep -Fq -- "--${host}"; then
      die "Inventory host is missing: ${host}"
    fi

    pass "Inventory contains managed host: ${host}"
  done

  pass "Lab 7 inventory validation completed successfully"
}

# ---------------------------------------------------------------------------
# SSH access validation
# ---------------------------------------------------------------------------

verify_basic_ssh_access() {
  step "Verifying basic SSH access"

  info "Remote user: ${MANAGED_HOSTS_REMOTE_USER}"
  info "First-time host-key and password prompts are allowed during this check."

  local host

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Testing SSH access to ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    ssh \
      -o ConnectTimeout="${MANAGED_HOSTS_SSH_CONNECT_TIMEOUT_SECONDS}" \
      "${MANAGED_HOSTS_REMOTE_USER}@${host}" \
      'echo "remote hostname: $(hostname)"; echo "remote user: $(whoami)"; echo "remote date: $(date)"' \
      || die "Basic SSH access failed: ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    pass "Basic SSH access succeeded: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done
}

# ---------------------------------------------------------------------------
# ED25519 key management
# ---------------------------------------------------------------------------

ensure_ed25519_key_pair() {
  step "Checking the local ED25519 SSH key pair"

  local private_key="$MANAGED_HOSTS_SSH_KEY_PATH"
  local public_key="$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH"
  local ssh_directory

  ssh_directory="$(dirname "$private_key")"

  if [[ -f "$private_key" && -f "$public_key" ]]; then
    pass "Existing ED25519 SSH key pair found"
    info "Reusing private key: ${private_key}"
    info "Reusing public key: ${public_key}"
    return 0
  fi

  if [[ -f "$private_key" && ! -f "$public_key" ]]; then
    die "Private key exists, but the public key is missing: ${public_key}"
  fi

  if [[ ! -f "$private_key" && -f "$public_key" ]]; then
    die "Public key exists, but the private key is missing: ${private_key}"
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
    -C "${USER}@${HOSTNAME}-nssa320-lab7" \
    || die "Failed to generate ED25519 SSH key pair"

  chmod 600 "$private_key" \
    || die "Failed to set private-key permissions"

  chmod 644 "$public_key" \
    || die "Failed to set public-key permissions"

  [[ -f "$private_key" && -f "$public_key" ]] \
    || die "ED25519 key generation did not produce both required files"

  pass "ED25519 SSH key pair created successfully"
  info "Private key: ${private_key}"
  info "Public key: ${public_key}"
}

copy_public_key_to_managed_hosts() {
  step "Copying the ED25519 public key to managed hosts"

  require_file "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH"

  info "You may be prompted for the student password on each host."

  local host

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
  step "Verifying passwordless ED25519 SSH access"

  info "BatchMode=yes prevents SSH from falling back to a password prompt."

  local host

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Testing key authentication to ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    ssh \
      -i "$MANAGED_HOSTS_SSH_KEY_PATH" \
      -o BatchMode=yes \
      -o PasswordAuthentication=no \
      -o ConnectTimeout="${MANAGED_HOSTS_SSH_CONNECT_TIMEOUT_SECONDS}" \
      "${MANAGED_HOSTS_REMOTE_USER}@${host}" \
      'echo "remote hostname: $(hostname)"; echo "remote user: $(whoami)"; echo "authentication: ssh-key"' \
      || die "Key-based SSH access failed: ${MANAGED_HOSTS_REMOTE_USER}@${host}"

    pass "Key-based SSH access succeeded: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done
}

verify_ansible_connectivity() {
  step "Verifying Ansible connectivity to managed Linux hosts"

  ansible \
    -i "$MANAGED_HOSTS_INVENTORY_FILE" \
    "$MANAGED_HOSTS_LINUX_GROUP" \
    -m ping \
    --private-key "$MANAGED_HOSTS_SSH_KEY_PATH" \
    || die "Ansible ping failed for the Lab 7 Linux group"

  pass "Ansible connectivity succeeded for all Linux managed hosts"
}

# ---------------------------------------------------------------------------
# Dry-run workflow
# ---------------------------------------------------------------------------

dry_run() {
  step "Lab 7 managed-host dry run starting"

  require_not_root
  show_managed_host_context
  check_required_commands
  validate_managed_host_configuration

  step "Dry-run inventory plan"

  if [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    info "Inventory exists: ${MANAGED_HOSTS_INVENTORY_FILE}"
    info "Would rewrite it only when its content differs."
  else
    warn "Would create inventory: ${MANAGED_HOSTS_INVENTORY_FILE}"
  fi

  step "Dry-run SSH-access plan"

  local host

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Would verify initial SSH access: ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done

  step "Dry-run ED25519 key plan"

  if [[ -f "$MANAGED_HOSTS_SSH_KEY_PATH" &&
        -f "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH" ]]; then
    pass "Would reuse the existing ED25519 key pair"
  elif [[ ! -f "$MANAGED_HOSTS_SSH_KEY_PATH" &&
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
  info "Next workflow:"
  info "  ./scripts/setup-privilege-escalation.sh --apply"
  info "Evidence saved to: ${MANAGED_HOSTS_SETUP_OUTPUT}"
}

apply_setup() {
  prepare_evidence_directories \
    "$MANAGED_HOSTS_EVIDENCE_DIR" \
    "$MANAGED_HOSTS_ARCHIVE_DIR"

  archive_existing_log \
    "$MANAGED_HOSTS_SETUP_OUTPUT" \
    "$MANAGED_HOSTS_ARCHIVE_DIR" \
    "managed-hosts-setup"

  exec > >(tee "$MANAGED_HOSTS_SETUP_OUTPUT") 2>&1

  apply_actions
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  case "${1:-}" in
    --dry-run)
      dry_run
      ;;

    --apply)
      apply_setup
      ;;

    -h|--help)
      usage
      ;;

    "")
      fail "Missing required mode"
      usage
      exit 2
      ;;

    *)
      fail "Unknown argument: $1"
      usage
      exit 2
      ;;
  esac
}

main "$@"#   v4.0 - Migrated the managed-host workflow from Lab 4 to Lab 7.
#          Replaced Activity 3 configuration with managed-host configuration.
#          Added repository inventory generation and syntax validation.
#          Removed the hard-coded ansible service-account password.
#          Updated calls to the renamed Lab 7 SSH helper functions.
#
#   v3.0 - Initial Lab 4 Activity 3 managed-host setup workflow.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Source shared configuration and libraries
# ---------------------------------------------------------------------------

source config/lab7.conf
source config/managed-hosts.conf
source lib/common.sh
source lib/evidence.sh
source lib/ssh.sh

SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --apply
  $SCRIPT_NAME --help

Description:
  Prepares the Lab 7 Linux managed hosts for Ansible and later AWX access.

Modes:
  --dry-run   Show what would be checked or changed without changing hosts.
  --apply     Apply the managed-host setup workflow.
  --help      Display this help message.

Lab 7 actions:
  1. Confirm the script is running as the normal student user.
  2. Check required local commands.
  3. Create or update ${MANAGED_HOSTS_INVENTORY_FILE}.
  4. Validate the generated Ansible inventory.
  5. Verify initial SSH access as ${MANAGED_HOSTS_REMOTE_USER}.
  6. Create the ${MANAGED_HOSTS_SERVICE_USER} service account.
  7. Generate a local SSH key only when one is missing.
  8. Copy the public key to the bootstrap account on each Linux host.
  9. Verify key-based SSH access to each Linux host.
  10. Save setup evidence.

This script does not configure passwordless sudo, AWX credentials,
Windows 11, WinRM, or Windows inventory groups.

EOF
}

# ---------------------------------------------------------------------------
# Context
# ---------------------------------------------------------------------------

show_managed_host_context() {
  local host

  step "Lab 7 managed-host context"

  info "Repository root: ${REPO_ROOT}"
  info "Workflow version: ${MANAGED_HOSTS_VERSION}"
  info "Workflow name: ${MANAGED_HOSTS_NAME}"
  info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  info "Bootstrap SSH user: ${MANAGED_HOSTS_REMOTE_USER}"
  info "Ansible service user: ${MANAGED_HOSTS_SERVICE_USER}"
  info "SSH private key: ${MANAGED_HOSTS_SSH_KEY_PATH}"
  info "SSH public key: ${MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH}"
  info "Evidence directory: ${MANAGED_HOSTS_EVIDENCE_DIR}"
  info "Archive directory: ${MANAGED_HOSTS_ARCHIVE_DIR}"

  info "Linux managed hosts:"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "  - ${host}"
  done
}

# ---------------------------------------------------------------------------
# Required command checks
# ---------------------------------------------------------------------------

check_managed_host_required_commands() {
  local command_name

  step "Checking managed-host workflow commands"

  for command_name in "${MANAGED_HOSTS_REQUIRED_COMMANDS[@]}"; do
    require_command "$command_name"
  done

  pass "All required managed-host commands are available"
}

# ---------------------------------------------------------------------------
# Inventory helpers
# ---------------------------------------------------------------------------

validate_inventory_configuration() {
  step "Validating managed-host inventory configuration"

  if [[ -z "${MANAGED_HOSTS_INVENTORY_FILE:-}" ]]; then
    fail "MANAGED_HOSTS_INVENTORY_FILE is not configured"
    return 1
  fi

  if [[ -z "${MANAGED_HOSTS_INVENTORY_CONTENT:-}" ]]; then
    fail "MANAGED_HOSTS_INVENTORY_CONTENT is not configured"
    return 1
  fi

  if [[ "${#MANAGED_HOSTS_LINUX[@]}" -eq 0 ]]; then
    fail "No Linux managed hosts are configured"
    return 1
  fi

  pass "Managed-host inventory configuration is valid"
}

inventory_matches_expected_content() {
  local current_content
  local expected_content

  if [[ ! -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    return 1
  fi

  current_content="$(cat "$MANAGED_HOSTS_INVENTORY_FILE")"
  expected_content="${MANAGED_HOSTS_INVENTORY_CONTENT%$'\n'}"

  [[ "$current_content" == "$expected_content" ]]
}

create_or_update_inventory() {
  step "Creating or updating the Lab 7 inventory"

  validate_inventory_configuration \
    || die "Managed-host inventory configuration is invalid"

  mkdir -p "$(dirname "$MANAGED_HOSTS_INVENTORY_FILE")" \
    || die "Failed to create the inventory directory"

  if inventory_matches_expected_content; then
    pass "Inventory already matches the expected Lab 7 content"
    info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
    return 0
  fi

  if [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    warn "Inventory exists but does not match the expected Lab 7 content"
    info "Updating inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  else
    info "Creating inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  fi

  printf '%s' "$MANAGED_HOSTS_INVENTORY_CONTENT" \
    > "$MANAGED_HOSTS_INVENTORY_FILE" \
    || die "Failed to write inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"

  pass "Inventory file is ready: ${MANAGED_HOSTS_INVENTORY_FILE}"

  info "Inventory content:"
  cat "$MANAGED_HOSTS_INVENTORY_FILE"
}

validate_inventory_syntax() {
  step "Validating the Lab 7 Ansible inventory"

  if [[ ! -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    fail "Inventory file was not found: ${MANAGED_HOSTS_INVENTORY_FILE}"
    return 1
  fi

  if ansible-inventory \
    -i "$MANAGED_HOSTS_INVENTORY_FILE" \
    --graph; then

    pass "Ansible inventory validation completed successfully"
    return 0
  fi

  fail "Ansible inventory validation failed"
  return 1
}

# ---------------------------------------------------------------------------
# Service-account setup
# ---------------------------------------------------------------------------

run_ansible_user_creation() {
  step "Creating the Ansible service account on Linux managed hosts"

  info "Ensuring ${MANAGED_HOSTS_SERVICE_USER} exists on Ubuntu hosts"

  ansible \
    -i "$MANAGED_HOSTS_INVENTORY_FILE" \
    "$MANAGED_HOSTS_UBUNTU_GROUP" \
    -m ansible.builtin.user \
    -a "name=${MANAGED_HOSTS_SERVICE_USER} create_home=yes state=present" \
    -u "$MANAGED_HOSTS_REMOTE_USER" \
    -b -k -K \
    || die "Failed to create ${MANAGED_HOSTS_SERVICE_USER} on Ubuntu hosts"

  pass "Ubuntu service-account task completed"

  info "Ensuring ${MANAGED_HOSTS_SERVICE_USER} exists on Rocky hosts"

  ansible \
    -i "$MANAGED_HOSTS_INVENTORY_FILE" \
    "$MANAGED_HOSTS_ROCKY_GROUP" \
    -m ansible.builtin.user \
    -a "name=${MANAGED_HOSTS_SERVICE_USER} create_home=yes state=present" \
    -u "$MANAGED_HOSTS_REMOTE_USER" \
    -b -k -K \
    || die "Failed to create ${MANAGED_HOSTS_SERVICE_USER} on Rocky hosts"

  pass "Rocky service-account task completed"
}

# ---------------------------------------------------------------------------
# Dry-run workflow
# ---------------------------------------------------------------------------

dry_run() {
  local host

  step "Lab 7 managed-host dry run starting"

  require_not_root
  show_managed_host_context
  check_managed_host_required_commands
  validate_inventory_configuration

  step "Dry-run inventory plan"

  if [[ -f "$MANAGED_HOSTS_INVENTORY_FILE" ]]; then
    info "Inventory file exists: ${MANAGED_HOSTS_INVENTORY_FILE}"

    if inventory_matches_expected_content; then
      pass "Inventory already matches the expected Lab 7 content"
    else
      warn "Would update the inventory because its content differs"
    fi
  else
    warn "Would create inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  fi

  info "Expected inventory content:"
  printf '%s' "$MANAGED_HOSTS_INVENTORY_CONTENT"

  step "Dry-run SSH plan"

  info "Would verify initial SSH access as ${MANAGED_HOSTS_REMOTE_USER}:"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Would run: ssh ${MANAGED_HOSTS_REMOTE_USER}@${host} 'hostname; whoami; date'"
  done

  step "Dry-run service-account plan"

  info "Would ensure ${MANAGED_HOSTS_SERVICE_USER} exists on:"
  info "  - ${MANAGED_HOSTS_UBUNTU_GROUP}"
  info "  - ${MANAGED_HOSTS_ROCKY_GROUP}"

  info "Would use the existing ${MANAGED_HOSTS_REMOTE_USER} account"
  info "for initial Ansible connectivity and privilege escalation"

  step "Dry-run SSH key plan"

  if [[ -f "$MANAGED_HOSTS_SSH_KEY_PATH" &&
        -f "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH" ]]; then

    pass "Existing SSH key pair would be reused"
    info "Private key: ${MANAGED_HOSTS_SSH_KEY_PATH}"
  else
    warn "Would generate SSH key pair: ${MANAGED_HOSTS_SSH_KEY_PATH}"
  fi

  info "Would copy the public key to the bootstrap account:"

  for host in "${MANAGED_HOSTS_LINUX[@]}"; do
    info "Would run: ssh-copy-id ${MANAGED_HOSTS_REMOTE_USER}@${host}"
  done

  info "Would verify key-based SSH access as ${MANAGED_HOSTS_REMOTE_USER}"

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
  check_managed_host_required_commands

  create_or_update_inventory

  validate_inventory_syntax \
    || die "Generated inventory validation failed"

  verify_basic_ssh_access \
    "$MANAGED_HOSTS_REMOTE_USER" \
    "${MANAGED_HOSTS_LINUX[@]}"

  run_ansible_user_creation

  ensure_local_ssh_key \
    "$MANAGED_HOSTS_SSH_KEY_PATH" \
    "$MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH"

  copy_ssh_key_to_managed_hosts \
    "$MANAGED_HOSTS_REMOTE_USER" \
    "${MANAGED_HOSTS_LINUX[@]}"

  verify_key_based_ssh_access \
    "$MANAGED_HOSTS_REMOTE_USER" \
    "${MANAGED_HOSTS_LINUX[@]}"

  step "Lab 7 managed-host apply complete"

  pass "Linux managed-host setup completed"
  info "Inventory file: ${MANAGED_HOSTS_INVENTORY_FILE}"
  info "Setup evidence: ${MANAGED_HOSTS_SETUP_OUTPUT}"

  warn "The SSH key currently authenticates the bootstrap account:"
  warn "${MANAGED_HOSTS_REMOTE_USER}"

  info "Service-account SSH and passwordless sudo configuration will be"
  info "completed in the privilege-escalation workflow"
}

apply_setup() {
  prepare_evidence_directories \
    "$MANAGED_HOSTS_EVIDENCE_DIR" \
    "$MANAGED_HOSTS_ARCHIVE_DIR"

  archive_existing_evidence \
    "$MANAGED_HOSTS_SETUP_OUTPUT" \
    "$MANAGED_HOSTS_ARCHIVE_DIR" \
    "managed-hosts-setup"

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

  case "${1:-}" in
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
      fail "Unknown argument: ${1:-}"
      usage
      exit 2
      ;;
  esac
}

main "$@"
