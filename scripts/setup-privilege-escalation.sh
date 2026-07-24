#!/usr/bin/env bash
#
# NSSA320 Lab 7 - Privilege Escalation Setup
# File: scripts/setup-privilege-escalation.sh
#
# Purpose:
#   Prepares the Lab 7 ansible service account for AWX management by
#   installing its SSH public key and configuring passwordless sudo on
#   the Linux managed hosts.
#
# Scope:
#   This script targets the Lab 7 Linux managed hosts:
#
#     - ubuntu
#     - ansible1
#     - ansible2
#
#   It assumes scripts/setup-managed-hosts.sh has already:
#
#     - created inventory.inv
#     - verified initial SSH access as student
#     - created the ansible service account
#     - generated the local SSH key
#
# Safety:
#   Supports --dry-run and --apply modes.
#   Must run as the normal student user, not with sudo.
#   Does not store passwords, credentials, tokens, or private keys.
#   Does not configure the AWX node itself.
#   Does not create or overwrite ansible.cfg.
#   Does not configure Windows or WinRM.
#
# RICE Notes:
#   Reproducibility - follows the same privilege setup sequence each time.
#   Idempotency     - authorized keys and sudoers files can be applied again.
#   Composability   - uses shared configuration and privilege helper functions.
#   Evolvability    - AWX and Windows workflows remain separate.
#
# Version History:
#   v5.0 - Migrated the privilege-escalation workflow from Lab 4 to Lab 7.
#          Removed control-node sudoers management.
#          Removed ansible.cfg creation.
#          Added SSH-key installation for the ansible service account.
#          Added passwordless sudo and privileged-command verification.
#
#   v4.0 - Initial Lab 4 Activity 4 privilege-escalation workflow.

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
source lib/privilege.sh

SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Evidence configuration
# ---------------------------------------------------------------------------

PRIVILEGE_EVIDENCE_DIR="${EVIDENCE_ROOT:-evidence}/privilege-escalation"
PRIVILEGE_ARCHIVE_DIR="${PRIVILEGE_EVIDENCE_DIR}/archive"

PRIVILEGE_SETUP_OUTPUT="${PRIVILEGE_EVIDENCE_DIR}/privilege-escalation-setup.txt"

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
  Prepares the Lab 7 ansible service account for AWX management.

Modes:
  --dry-run   Show the privilege-escalation plan without making changes.
  --apply     Apply SSH-key and passwordless-sudo configuration.
  --help      Display this help message.

Lab 7 actions:
  1. Confirm the script is running as the normal student user.
  2. Check required local commands.
  3. Validate the privilege configuration.
  4. Validate inventory.inv and the Linux host group.
  5. Verify that the ansible service account exists.
  6. Install the local SSH public key for the ansible account.
  7. Create a validated sudoers source file.
  8. Deploy /etc/sudoers.d/ansible to Linux managed hosts.
  9. Validate the deployed sudoers file with visudo.
  10. Verify SSH access as ansible.
  11. Verify passwordless sudo as ansible.
  12. Verify privileged access to /root.
  13. Verify the service-account task remains idempotent.
  14. Save setup evidence.

This script does not configure the AWX node, create ansible.cfg,
configure Windows 11, or store any credentials.

EOF
}

# ---------------------------------------------------------------------------
# Dry-run helpers
# ---------------------------------------------------------------------------

show_dry_run_inventory_status() {
    step "Dry-run inventory status"

    if [[ -f "$PRIVILEGE_INVENTORY_FILE" ]]; then
        pass "Inventory file exists: ${PRIVILEGE_INVENTORY_FILE}"
        info "Would validate the ${PRIVILEGE_TARGET_GROUP} inventory group"
        info "Would verify ubuntu, ansible1, and ansible2 are present"
    else
        warn "Inventory file is missing: ${PRIVILEGE_INVENTORY_FILE}"
        warn "Run scripts/setup-managed-hosts.sh before applying this workflow"
    fi
}

show_dry_run_key_status() {
    step "Dry-run SSH-key status"

    if [[ -f "$PRIVILEGE_PUBLIC_KEY_PATH" ]]; then
        pass "SSH public key exists: ${PRIVILEGE_PUBLIC_KEY_PATH}"
    else
        warn "SSH public key is missing: ${PRIVILEGE_PUBLIC_KEY_PATH}"
        warn "The managed-host setup workflow should create this key"
    fi

    if [[ -f "$PRIVILEGE_PRIVATE_KEY_PATH" ]]; then
        pass "SSH private key exists: ${PRIVILEGE_PRIVATE_KEY_PATH}"
    else
        warn "SSH private key is missing: ${PRIVILEGE_PRIVATE_KEY_PATH}"
    fi
}

show_dry_run_setup_plan() {
    step "Dry-run privilege-escalation plan"

    info "Would connect initially as: ${PRIVILEGE_BOOTSTRAP_USER}"
    info "Would verify service account: ${PRIVILEGE_SERVICE_USER}"
    info "Would target inventory group: ${PRIVILEGE_TARGET_GROUP}"

    info "Would create the service-account SSH directory:"
    info "  ${PRIVILEGE_SERVICE_SSH_DIR}"

    info "Would install the public key in:"
    info "  ${PRIVILEGE_SERVICE_AUTHORIZED_KEYS}"

    info "Would create temporary sudoers source file:"
    info "  ${PRIVILEGE_TEMP_SUDOERS_FILE}"

    info "Would deploy passwordless sudoers file:"
    info "  ${PRIVILEGE_SUDOERS_FILE}"

    info "Expected sudoers rule:"
    info "  ${PRIVILEGE_SUDOERS_CONTENT}"

    info "Would validate the sudoers file with visudo"

    info "Would verify SSH access as:"
    info "  ${PRIVILEGE_SERVICE_USER}"

    info "Would verify noninteractive passwordless sudo"

    info "Would verify privileged access with:"
    info "  ls -ld /root"

    info "Would rerun the service-account user task to demonstrate idempotency"
}

# ---------------------------------------------------------------------------
# Dry-run workflow
# ---------------------------------------------------------------------------

dry_run() {
    step "Lab 7 privilege-escalation dry run starting"

    require_not_root
    show_privilege_context
    check_privilege_required_commands
    validate_privilege_configuration

    show_dry_run_inventory_status
    show_dry_run_key_status
    show_dry_run_setup_plan

    step "Lab 7 privilege-escalation dry run complete"
    pass "No changes were made"
}

# ---------------------------------------------------------------------------
# Apply workflow
# ---------------------------------------------------------------------------

apply_actions() {
    step "Lab 7 privilege-escalation apply starting"

    require_not_root
    show_privilege_context
    check_privilege_required_commands

    validate_privilege_configuration \
        || die "Privilege-escalation configuration is invalid"

    precheck_privilege_inventory

    verify_service_user_exists

    install_service_user_authorized_key

    create_temp_ansible_sudoers_file

    deploy_ansible_sudoers_to_group \
        "$PRIVILEGE_TARGET_GROUP"

    validate_managed_sudoers

    verify_service_user_ssh_access

    verify_service_user_passwordless_sudo

    verify_privileged_ansible_command

    verify_service_user_idempotency

    cleanup_temp_ansible_sudoers_file

    step "Lab 7 privilege-escalation apply complete"

    pass "The ansible service account is ready for AWX management"
    info "Service account: ${PRIVILEGE_SERVICE_USER}"
    info "Target group: ${PRIVILEGE_TARGET_GROUP}"
    info "Sudoers file: ${PRIVILEGE_SUDOERS_FILE}"
    info "Setup evidence: ${PRIVILEGE_SETUP_OUTPUT}"
}

apply_setup() {
    prepare_evidence_directories \
        "$PRIVILEGE_EVIDENCE_DIR" \
        "$PRIVILEGE_ARCHIVE_DIR"

    archive_existing_evidence \
        "$PRIVILEGE_SETUP_OUTPUT" \
        "$PRIVILEGE_ARCHIVE_DIR" \
        "privilege-escalation-setup"

    exec > >(tee "$PRIVILEGE_SETUP_OUTPUT") 2>&1

    apply_actions
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------

cleanup_on_exit() {
    local exit_code=$?

    if [[ -e "${PRIVILEGE_TEMP_SUDOERS_FILE:-}" ]]; then
        rm -f "$PRIVILEGE_TEMP_SUDOERS_FILE" || true
    fi

    return "$exit_code"
}

trap cleanup_on_exit EXIT

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
