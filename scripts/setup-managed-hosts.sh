#!/usr/bin/env bash
#
# NSSA320 Lab 7 - Linux Managed Host Setup
# File: scripts/setup-managed-hosts.sh
#
# Purpose:
#   Prepares the Lab 7 Linux managed hosts for Ansible and later AWX
#   management. The script creates the repository inventory, verifies
#   initial SSH access, creates the ansible service account, prepares
#   an SSH key, and copies the key to the bootstrap account.
#
# Scope:
#   This script prepares the following Linux managed hosts:
#     - ubuntu
#     - ansible1
#     - ansible2
#
#   Windows 11 and WinRM configuration are intentionally deferred to
#   the later Windows activity.
#
# Safety:
#   Supports --dry-run and --apply modes.
#   Must run as the normal student user, not with sudo.
#   Does not store passwords or credentials.
#   Does not configure passwordless sudo.
#   Does not modify AWX credentials.
#   Does not configure Windows or WinRM.
#
# RICE Notes:
#   Reproducibility - follows the same managed-host preparation sequence.
#   Idempotency     - reuses SSH keys, preserves existing accounts, and
#                     rewrites inventory only when its content differs.
#   Composability   - uses shared configuration and library functions.
#   Evolvability    - Windows and AWX-specific setup remain separate.
#
# Version History:
#   v4.0 - Migrated the managed-host workflow from Lab 4 to Lab 7.
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
