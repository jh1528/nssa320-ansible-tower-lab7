#!/usr/bin/env bash
# ==============================================================================
# privilege.sh
# ==============================================================================
#
# Shared privilege-escalation helpers for NSSA320 Lab 7.
#
# Purpose:
#   Provides reusable functions for preparing the Lab 7 ansible service
#   account for SSH access and passwordless sudo on Linux managed hosts.
#
# Scope:
#   This library supports:
#
#     - ubuntu
#     - ansible1
#     - ansible2
#
#   Windows 11 and WinRM are intentionally excluded until the later
#   Windows activity.
#
# Design:
#   This file defines functions only.
#   It must be sourced by a runnable script.
#
#   The privilege-escalation workflow uses the existing student account
#   for initial SSH and sudo access. It then prepares the ansible service
#   account for AWX management.
#
# Safety:
#   This file does not store passwords, tokens, private keys, AWX
#   credentials, or other secrets.
#
#   Sudoers files are validated with visudo before installation.
#
# RICE Framework:
#   Reproducibility - uses a consistent privilege setup workflow.
#   Idempotency     - authorized keys and sudoers files can be applied again.
#   Composability   - setup and verification scripts can reuse the functions.
#   Evolvability    - additional groups and privilege rules can be added later.
#
# Dependencies:
#   The following files must be sourced before this library:
#
#     - config/lab7.conf
#     - config/managed-hosts.conf
#     - lib/common.sh
#
# Version History:
#   v5.0 - Migrated privilege helpers from Lab 4 to Lab 7.
#          Removed control-node sudoers management.
#          Removed ansible.cfg creation and verification.
#          Added ansible service-account SSH key installation.
#          Added passwordless sudo verification using the service account.
#          Updated all functions to use Lab 7 managed-host configuration.
#
#   v4.0 - Original Lab 4 Activity 4 privilege helper library.
#
# ==============================================================================


# ==============================================================================
# Execution Guard
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' \
        "[FAIL] lib/privilege.sh is a shared library and must be sourced." \
        "[INFO] Example: source lib/privilege.sh"

    exit 1
fi


# ==============================================================================
# Source Guard
# ==============================================================================

if [[ -n "${LAB7_PRIVILEGE_SH_LOADED:-}" ]]; then
    return 0
fi

LAB7_PRIVILEGE_SH_LOADED="true"


# ==============================================================================
# Dependency Checks
# ==============================================================================

if ! declare -F step >/dev/null 2>&1; then
    printf '%s\n' \
        "[FAIL] lib/common.sh must be sourced before lib/privilege.sh" >&2

    return 1
fi

if [[ -z "${MANAGED_HOSTS_INVENTORY_FILE:-}" ]]; then
    fail "config/managed-hosts.conf must be sourced before lib/privilege.sh"
    return 1
fi

if [[ -z "${MANAGED_HOSTS_SERVICE_USER:-}" ]]; then
    fail "MANAGED_HOSTS_SERVICE_USER is not configured"
    return 1
fi


# ==============================================================================
# Default Privilege Configuration
# ==============================================================================

# These values may later be moved into a dedicated privilege configuration
# file if the Lab 7 workflow grows.

PRIVILEGE_VERSION="${PRIVILEGE_VERSION:-v1.0}"
PRIVILEGE_NAME="${PRIVILEGE_NAME:-Lab 7 Passwordless Sudo Setup}"

PRIVILEGE_INVENTORY_FILE="${PRIVILEGE_INVENTORY_FILE:-${MANAGED_HOSTS_INVENTORY_FILE}}"

PRIVILEGE_BOOTSTRAP_USER="${PRIVILEGE_BOOTSTRAP_USER:-${MANAGED_HOSTS_REMOTE_USER}}"
PRIVILEGE_SERVICE_USER="${PRIVILEGE_SERVICE_USER:-${MANAGED_HOSTS_SERVICE_USER}}"

PRIVILEGE_TARGET_GROUP="${PRIVILEGE_TARGET_GROUP:-${MANAGED_HOSTS_LINUX_GROUP}}"

PRIVILEGE_SERVICE_HOME="${PRIVILEGE_SERVICE_HOME:-/home/${PRIVILEGE_SERVICE_USER}}"
PRIVILEGE_SERVICE_SSH_DIR="${PRIVILEGE_SERVICE_HOME}/.ssh"
PRIVILEGE_SERVICE_AUTHORIZED_KEYS="${PRIVILEGE_SERVICE_SSH_DIR}/authorized_keys"

PRIVILEGE_PUBLIC_KEY_PATH="${PRIVILEGE_PUBLIC_KEY_PATH:-${MANAGED_HOSTS_SSH_PUBLIC_KEY_PATH}}"
PRIVILEGE_PRIVATE_KEY_PATH="${PRIVILEGE_PRIVATE_KEY_PATH:-${MANAGED_HOSTS_SSH_KEY_PATH}}"

PRIVILEGE_SUDOERS_FILE="${PRIVILEGE_SUDOERS_FILE:-/etc/sudoers.d/${PRIVILEGE_SERVICE_USER}}"
PRIVILEGE_SUDOERS_MODE="${PRIVILEGE_SUDOERS_MODE:-0440}"

PRIVILEGE_TEMP_SUDOERS_FILE="${PRIVILEGE_TEMP_SUDOERS_FILE:-/tmp/lab7-${PRIVILEGE_SERVICE_USER}-sudoers}"
PRIVILEGE_REMOTE_PUBLIC_KEY_FILE="${PRIVILEGE_REMOTE_PUBLIC_KEY_FILE:-/tmp/lab7-${PRIVILEGE_SERVICE_USER}-authorized-key.pub}"

PRIVILEGE_SUDOERS_CONTENT="${PRIVILEGE_SUDOERS_CONTENT:-${PRIVILEGE_SERVICE_USER} ALL=(ALL) NOPASSWD: ALL}"


# ==============================================================================
# Context
# ==============================================================================

show_privilege_context() {
    step "Lab 7 privilege-escalation context"

    info "Workflow: ${PRIVILEGE_NAME}"
    info "Version: ${PRIVILEGE_VERSION}"
    info "Inventory: ${PRIVILEGE_INVENTORY_FILE}"
    info "Target group: ${PRIVILEGE_TARGET_GROUP}"
    info "Bootstrap user: ${PRIVILEGE_BOOTSTRAP_USER}"
    info "Service user: ${PRIVILEGE_SERVICE_USER}"
    info "Service home: ${PRIVILEGE_SERVICE_HOME}"
    info "Public key: ${PRIVILEGE_PUBLIC_KEY_PATH}"
    info "Sudoers file: ${PRIVILEGE_SUDOERS_FILE}"
    info "Sudoers mode: ${PRIVILEGE_SUDOERS_MODE}"
}


# ==============================================================================
# Required Commands
# ==============================================================================

check_privilege_required_commands() {
    local command_name
    local required_commands=(
        ansible
        ansible-inventory
        ssh
    )

    step "Checking privilege-escalation commands"

    for command_name in "${required_commands[@]}"; do
        require_command "$command_name"
    done

    pass "All required privilege-escalation commands are available"
}


# ==============================================================================
# Configuration Validation
# ==============================================================================

validate_privilege_configuration() {
    local failed=0

    step "Validating privilege-escalation configuration"

    if [[ -z "$PRIVILEGE_INVENTORY_FILE" ]]; then
        fail "Privilege inventory file is not configured"
        failed=1
    fi

    if [[ -z "$PRIVILEGE_BOOTSTRAP_USER" ]]; then
        fail "Privilege bootstrap user is not configured"
        failed=1
    fi

    if [[ -z "$PRIVILEGE_SERVICE_USER" ]]; then
        fail "Privilege service user is not configured"
        failed=1
    fi

    if [[ -z "$PRIVILEGE_TARGET_GROUP" ]]; then
        fail "Privilege target group is not configured"
        failed=1
    fi

    if [[ -z "$PRIVILEGE_SUDOERS_FILE" ]]; then
        fail "Privilege sudoers file is not configured"
        failed=1
    fi

    if [[ -z "$PRIVILEGE_SUDOERS_CONTENT" ]]; then
        fail "Privilege sudoers content is not configured"
        failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        return 1
    fi

    pass "Privilege-escalation configuration is valid"
    return 0
}


# ==============================================================================
# Inventory Pre-Check
# ==============================================================================

precheck_privilege_inventory() {
    local inventory_graph
    local host

    step "Pre-checking the Lab 7 inventory"

    require_file "$PRIVILEGE_INVENTORY_FILE"

    if ! inventory_graph="$(
        ansible-inventory \
            -i "$PRIVILEGE_INVENTORY_FILE" \
            --graph
    )"; then
        die "Unable to parse inventory: ${PRIVILEGE_INVENTORY_FILE}"
    fi

    printf '%s\n' "$inventory_graph"

    if ! grep -Fq "@${PRIVILEGE_TARGET_GROUP}:" <<< "$inventory_graph"; then
        die "Inventory group is missing: ${PRIVILEGE_TARGET_GROUP}"
    fi

    pass "Inventory contains target group: ${PRIVILEGE_TARGET_GROUP}"

    for host in "${MANAGED_HOSTS_LINUX[@]}"; do
        if grep -Fq -- "--${host}" <<< "$inventory_graph"; then
            pass "Inventory contains managed host: ${host}"
        else
            die "Inventory does not contain managed host: ${host}"
        fi
    done

    pass "Lab 7 inventory pre-check completed"
}


# ==============================================================================
# Service-Account Pre-Check
# ==============================================================================

verify_service_user_exists() {
    step "Verifying the service account exists on Linux managed hosts"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.command \
        -a "id ${PRIVILEGE_SERVICE_USER}" \
        || die "The ${PRIVILEGE_SERVICE_USER} service account is missing on one or more hosts"

    pass "Service account exists on all Linux managed hosts"
}


# ==============================================================================
# SSH Key Installation
# ==============================================================================

install_service_user_authorized_key() {
    step "Installing the SSH public key for ${PRIVILEGE_SERVICE_USER}"

    require_file "$PRIVILEGE_PUBLIC_KEY_PATH"

    info "Preparing ${PRIVILEGE_SERVICE_SSH_DIR}"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.file \
        -a "path=${PRIVILEGE_SERVICE_SSH_DIR} state=directory owner=${PRIVILEGE_SERVICE_USER} group=${PRIVILEGE_SERVICE_USER} mode=0700" \
        || die "Failed to prepare ${PRIVILEGE_SERVICE_SSH_DIR}"

    info "Copying the public key to a temporary remote location"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.copy \
        -a "src=${PRIVILEGE_PUBLIC_KEY_PATH} dest=${PRIVILEGE_REMOTE_PUBLIC_KEY_FILE} owner=root group=root mode=0600" \
        || die "Failed to copy the temporary public key"

    info "Adding the public key to authorized_keys idempotently"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.shell \
        -a "touch ${PRIVILEGE_SERVICE_AUTHORIZED_KEYS} && chown ${PRIVILEGE_SERVICE_USER}:${PRIVILEGE_SERVICE_USER} ${PRIVILEGE_SERVICE_AUTHORIZED_KEYS} && chmod 0600 ${PRIVILEGE_SERVICE_AUTHORIZED_KEYS} && if ! grep -qxF \"\$(cat ${PRIVILEGE_REMOTE_PUBLIC_KEY_FILE})\" ${PRIVILEGE_SERVICE_AUTHORIZED_KEYS}; then cat ${PRIVILEGE_REMOTE_PUBLIC_KEY_FILE} >> ${PRIVILEGE_SERVICE_AUTHORIZED_KEYS}; fi" \
        || die "Failed to install the service-account authorized key"

    info "Removing the temporary remote public-key file"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.file \
        -a "path=${PRIVILEGE_REMOTE_PUBLIC_KEY_FILE} state=absent" \
        || die "Failed to remove the temporary public-key file"

    pass "SSH public key installed for ${PRIVILEGE_SERVICE_USER}"
}


# ==============================================================================
# Local Sudoers Source File
# ==============================================================================

create_temp_ansible_sudoers_file() {
    step "Creating the temporary Lab 7 sudoers source file"

    printf '%s\n' "$PRIVILEGE_SUDOERS_CONTENT" \
        > "$PRIVILEGE_TEMP_SUDOERS_FILE" \
        || die "Failed to write ${PRIVILEGE_TEMP_SUDOERS_FILE}"

    chmod 0600 "$PRIVILEGE_TEMP_SUDOERS_FILE" \
        || die "Failed to secure ${PRIVILEGE_TEMP_SUDOERS_FILE}"

    pass "Temporary sudoers source file is ready"
    info "Temporary file: ${PRIVILEGE_TEMP_SUDOERS_FILE}"
}


# ==============================================================================
# Sudoers Deployment
# ==============================================================================

deploy_ansible_sudoers_to_group() {
    local target_group="${1:-$PRIVILEGE_TARGET_GROUP}"

    if [[ -z "$target_group" ]]; then
        die "Usage: deploy_ansible_sudoers_to_group [inventory_group]"
    fi

    step "Deploying passwordless sudo to ${target_group}"

    require_file "$PRIVILEGE_TEMP_SUDOERS_FILE"

    ansible \
        "$target_group" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.copy \
        -a "src=${PRIVILEGE_TEMP_SUDOERS_FILE} dest=${PRIVILEGE_SUDOERS_FILE} owner=root group=root mode=${PRIVILEGE_SUDOERS_MODE} validate='visudo -cf %s'" \
        || die "Failed to deploy the sudoers file to ${target_group}"

    pass "Passwordless sudo deployed to ${target_group}"
}


# ==============================================================================
# Managed Sudoers Validation
# ==============================================================================

validate_managed_sudoers() {
    step "Validating the managed-host sudoers file"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_BOOTSTRAP_USER" \
        -b -k -K \
        -m ansible.builtin.command \
        -a "visudo -cf ${PRIVILEGE_SUDOERS_FILE}" \
        || die "Managed-host sudoers validation failed"

    pass "Managed-host sudoers files are valid"
}


# ==============================================================================
# Service-Account SSH Verification
# ==============================================================================

verify_service_user_ssh_access() {
    step "Verifying SSH access as ${PRIVILEGE_SERVICE_USER}"

    require_file "$PRIVILEGE_PRIVATE_KEY_PATH"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_SERVICE_USER" \
        --private-key "$PRIVILEGE_PRIVATE_KEY_PATH" \
        -m ansible.builtin.command \
        -a "whoami" \
        || die "SSH verification failed for ${PRIVILEGE_SERVICE_USER}"

    pass "SSH access works as ${PRIVILEGE_SERVICE_USER}"
}


# ==============================================================================
# Passwordless Sudo Verification
# ==============================================================================

verify_service_user_passwordless_sudo() {
    step "Verifying passwordless sudo as ${PRIVILEGE_SERVICE_USER}"

    require_file "$PRIVILEGE_PRIVATE_KEY_PATH"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_SERVICE_USER" \
        --private-key "$PRIVILEGE_PRIVATE_KEY_PATH" \
        -b \
        -e "ansible_become_flags=-n" \
        -m ansible.builtin.command \
        -a "id -u" \
        || die "Passwordless sudo verification failed for ${PRIVILEGE_SERVICE_USER}"

    pass "Passwordless sudo works as ${PRIVILEGE_SERVICE_USER}"
}


# ==============================================================================
# Privileged Command Verification
# ==============================================================================

verify_privileged_ansible_command() {
    step "Verifying privileged access to /root"

    require_file "$PRIVILEGE_PRIVATE_KEY_PATH"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_SERVICE_USER" \
        --private-key "$PRIVILEGE_PRIVATE_KEY_PATH" \
        -b \
        -e "ansible_become_flags=-n" \
        -m ansible.builtin.command \
        -a "ls -ld /root" \
        || die "Privileged Ansible command failed"

    pass "Privileged Ansible command completed successfully"
}


# ==============================================================================
# Idempotency Verification
# ==============================================================================

verify_service_user_idempotency() {
    step "Verifying the service-account task is idempotent"

    require_file "$PRIVILEGE_PRIVATE_KEY_PATH"

    ansible \
        "$PRIVILEGE_TARGET_GROUP" \
        -i "$PRIVILEGE_INVENTORY_FILE" \
        -u "$PRIVILEGE_SERVICE_USER" \
        --private-key "$PRIVILEGE_PRIVATE_KEY_PATH" \
        -b \
        -e "ansible_become_flags=-n" \
        -m ansible.builtin.user \
        -a "name=${PRIVILEGE_SERVICE_USER} create_home=yes state=present" \
        || die "Service-account idempotency verification failed"

    pass "Service-account idempotency task completed"
}


# ==============================================================================
# Cleanup
# ==============================================================================

cleanup_temp_ansible_sudoers_file() {
    step "Cleaning up the temporary sudoers source file"

    if [[ ! -e "$PRIVILEGE_TEMP_SUDOERS_FILE" ]]; then
        pass "Temporary sudoers file is already absent"
        return 0
    fi

    rm -f "$PRIVILEGE_TEMP_SUDOERS_FILE" \
        || die "Failed to remove ${PRIVILEGE_TEMP_SUDOERS_FILE}"

    pass "Temporary sudoers source file removed"
}
