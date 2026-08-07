#!/usr/bin/env bash
# ==============================================================================
# setup-control-node.sh
# ==============================================================================
#
# NSSA320 Lab 7 - Control Node Setup
#
# Purpose:
#  - Prepare the Lab 7 AWX/control node for cross-platform Ansible management.
#  - Install and validate required system packages.
#  - Install and validate required Python modules such as pywinrm.
#  - Install and validate required Ansible collections.
#  - Confirm the control node is ready to manage Linux hosts with SSH and
#    Windows hosts with WinRM.
#
# Scope:
#  - AWX/control node only.
#  - Does not configure Linux managed hosts.
#  - Does not configure Windows 11.
#  - Does not configure SSH keys or privilege escalation on managed hosts.
#  - Does not create AWX inventories, credentials, projects, or Job Templates.
#
# Design:
#  - This script is the runnable control-node setup workflow.
#  - Configuration values come from:
#      - config/lab7.conf
#      - config/control-node.conf
#  - Dependency logic comes from:
#      - lib/packages.sh
#  - Output and safety helpers come from:
#      - lib/common.sh
#  - Supports --dry-run and --apply modes.
#  - Dry-run performs validation only and makes no changes.
#  - Apply mode installs missing dependencies and performs final validation.
#
# RICE Framework:
#  - Reproducibility:
#      Uses centralized configuration and shared package-management logic so a
#      new Lab 7 control node can be prepared consistently.
#
#  - Idempotency:
#      Existing packages, Python modules, commands, and Ansible collections are
#      detected before installation. Re-running the workflow should converge on
#      the same desired state.
#
#  - Composability:
#      This script coordinates existing configuration and library components
#      rather than duplicating package-management logic.
#
#  - Evolvability:
#      Future control-node dependencies can be added through configuration and
#      shared libraries without redesigning this workflow.
#
# Security:
#  - No passwords, SSH private keys, AWX credentials, tokens, or secrets are
#    stored or requested by this script.
#  - Ansible collections are installed for the normal control-node user.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
#
# Version: 1.0
# Date: 2026-08-07
#
# Changes:
#  - Added the initial Lab 7 control-node setup workflow.
#  - Added dry-run and apply modes.
#  - Integrated config/control-node.conf.
#  - Integrated the Lab 7 package-management library.
#  - Added system package, command, Python runtime, pywinrm, and Ansible
#    collection validation.
#  - Added idempotent dependency installation through shared library helpers.
#  - Added final control-node readiness summary.
#
# ==============================================================================


set -u
set -o pipefail


# ==============================================================================
# Path Setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "$REPO_ROOT" || {
    echo "[FAIL] Unable to change to repository root: ${REPO_ROOT}"
    exit 1
}


# ==============================================================================
# Required File Validation
# ==============================================================================

require_file() {
    local file_path="${1:-}"

    if [[ -z "$file_path" ]]; then
        echo "[FAIL] Required file path cannot be empty"
        exit 1
    fi

    if [[ ! -f "$file_path" ]]; then
        echo "[FAIL] Missing required file: ${file_path}"
        exit 1
    fi
}


require_file "config/lab7.conf"
require_file "config/control-node.conf"
require_file "lib/common.sh"
require_file "lib/packages.sh"


# ==============================================================================
# Load Shared Configuration and Libraries
# ==============================================================================

source "config/lab7.conf"
source "config/control-node.conf"
source "lib/common.sh"
source "lib/packages.sh"


# ==============================================================================
# Script Metadata
# ==============================================================================

SCRIPT_NAME="$(basename "$0")"

SETUP_CONTROL_NODE_VERSION="1.0"

SETUP_CONTROL_NODE_NAME="Lab 7 Control Node Setup"


# ==============================================================================
# Usage
# ==============================================================================

usage() {
    cat <<EOF
Usage:
  ${SCRIPT_NAME} --dry-run
  sudo ${SCRIPT_NAME} --apply
  ${SCRIPT_NAME} --help

Description:
  Prepares the NSSA320 Lab 7 AWX/control node for cross-platform
  Ansible management.

Modes:
  --dry-run
      Show the expected control-node configuration and validate the current
      dependency state. No changes are made.

  --apply
      Install missing system packages, Python modules, and Ansible
      collections, then perform final validation.

  --help
      Display this help message.

Control-node requirements include:
  - Required RPM packages
  - Required commands
  - Configured Python runtime
  - pip
  - Required Python modules such as pywinrm
  - Required Ansible collections

Important:
  Run --dry-run first.

  Apply mode must be run with sudo because system package and Python package
  installation may require root privileges.

  Ansible collections are installed for the normal control-node user rather
  than root.
EOF
}


# ==============================================================================
# Context Display
# ==============================================================================

show_control_node_context() {
    local control_user
    local collection_path

    control_user="$(get_control_node_user)"

    if ! collection_path="$(get_ansible_collection_path)"; then
        collection_path="Unable to determine"
    fi

    step "Lab 7 control-node context"

    info "Workflow: ${SETUP_CONTROL_NODE_NAME}"
    info "Workflow version: ${SETUP_CONTROL_NODE_VERSION}"
    info "Repository root: ${REPO_ROOT}"

    info "Lab name: ${LAB_NAME:-NSSA320 Lab 7}"
    info "Lab version: ${LAB_VERSION:-unknown}"

    info "Control-node role: ${CONTROL_NODE_ROLE:-awx}"
    info "Control-node name: ${CONTROL_NODE_NAME:-Lab 7 AWX Control Node}"

    info "Current hostname: $(hostname)"
    info "Expected AWX hostname: ${AWX_FQDN:-${AWX_HOST:-awx}}"

    info "Control-node user: ${control_user}"
    info "Configured Python: ${LAB7_PYTHON_BIN:-python3}"
    info "Ansible collection path: ${collection_path}"
}


# ==============================================================================
# Requirement Display
# ==============================================================================

show_required_packages() {
    local item

    step "Required system packages"

    if ! declare -p LAB7_REQUIRED_PACKAGES >/dev/null 2>&1; then
        warn "LAB7_REQUIRED_PACKAGES is not configured"
        return 1
    fi

    for item in "${LAB7_REQUIRED_PACKAGES[@]}"; do
        info "  - ${item}"
    done

    return 0
}


show_required_commands() {
    local item

    step "Required commands"

    if ! declare -p LAB7_REQUIRED_COMMANDS >/dev/null 2>&1; then
        warn "LAB7_REQUIRED_COMMANDS is not configured"
        return 1
    fi

    for item in "${LAB7_REQUIRED_COMMANDS[@]}"; do
        info "  - ${item}"
    done

    return 0
}


show_required_python_modules() {
    local item

    step "Required Python modules"

    if ! declare -p LAB7_REQUIRED_PYTHON_MODULES >/dev/null 2>&1; then
        warn "LAB7_REQUIRED_PYTHON_MODULES is not configured"
        return 1
    fi

    for item in "${LAB7_REQUIRED_PYTHON_MODULES[@]}"; do
        info "  - ${item}"
    done

    return 0
}


show_required_ansible_collections() {
    local item

    step "Required Ansible collections"

    if ! declare -p LAB7_REQUIRED_COLLECTIONS >/dev/null 2>&1; then
        warn "LAB7_REQUIRED_COLLECTIONS is not configured"
        return 1
    fi

    for item in "${LAB7_REQUIRED_COLLECTIONS[@]}"; do
        info "  - ${item}"
    done

    return 0
}


show_control_node_requirements() {
    step "Lab 7 control-node desired state"

    show_required_packages || true
    show_required_commands || true
    show_required_python_modules || true
    show_required_ansible_collections || true
}


# ==============================================================================
# Host Identity Check
# ==============================================================================

check_control_node_identity() {
    local current_short
    local current_fqdn

    step "Checking control-node identity"

    current_short="$(hostname -s 2>/dev/null || hostname)"
    current_fqdn="$(hostname -f 2>/dev/null || hostname)"

    info "Current short hostname: ${current_short}"
    info "Current FQDN: ${current_fqdn}"
    info "Expected short hostname: ${AWX_HOST:-awx}"
    info "Expected FQDN: ${AWX_FQDN:-awx}"

    if [[ "${current_short,,}" == "${AWX_HOST,,}" ]]; then
        pass "Control-node short hostname is correct"
        return 0
    fi

    if [[ "${current_fqdn,,}" == "${AWX_FQDN,,}" ]]; then
        pass "Control-node FQDN is correct"
        return 0
    fi

    warn "Current hostname does not match the configured AWX role"
    warn "Run the Lab 7 node bootstrap separately if hostname configuration is required"

    return 1
}


# ==============================================================================
# Dry Run Workflow
# ==============================================================================

dry_run() {
    local failed=0

    step "Starting Lab 7 control-node dry run"

    info "No changes will be made"

    show_control_node_context

    show_control_node_requirements

    check_control_node_identity || failed=1

    step "Checking current dependency state"

    if ! check_control_node_dependencies; then
        failed=1
    fi

    step "Dry-run summary"

    if [[ "$failed" -eq 0 ]]; then
        pass "Control node already satisfies the Lab 7 dependency requirements"
        return 0
    fi

    warn "Control node does not currently satisfy all Lab 7 requirements"
    info "Run the following when ready:"
    info "  sudo ./scripts/setup-control-node.sh --apply"

    return 1
}


# ==============================================================================
# Apply Safety Checks
# ==============================================================================

check_apply_context() {
    step "Validating apply context"

    if [[ "${EUID}" -ne 0 ]]; then
        fail "Apply mode requires root privileges"
        info "Run:"
        info "  sudo ./scripts/setup-control-node.sh --apply"
        return 1
    fi

    pass "Apply mode is running with root privileges"

    if [[ -z "${SUDO_USER:-}" || "${SUDO_USER}" == "root" ]]; then
        warn "Unable to detect a normal sudo user"
        warn "Ansible collections may be installed for root unless LAB7_CONTROL_NODE_USER is configured"
    else
        pass "Normal control-node user detected: ${SUDO_USER}"
    fi

    return 0
}


# ==============================================================================
# Apply Workflow
# ==============================================================================

apply_setup() {
    local failed=0

    step "Starting Lab 7 control-node setup"

    show_control_node_context

    show_control_node_requirements

    if ! check_apply_context; then
        return 1
    fi

    check_control_node_identity || true

    step "Installing control-node dependencies"

    if ! install_control_node_dependencies; then
        failed=1
    fi

    step "Performing final control-node validation"

    if ! check_control_node_dependencies; then
        failed=1
    fi

    step "Displaying installed automation environment"

    show_ansible_version || failed=1

    show_ansible_galaxy_version || failed=1

    show_python_version || failed=1

    if declare -p LAB7_REQUIRED_PYTHON_MODULES >/dev/null 2>&1; then
        local module_name

        for module_name in "${LAB7_REQUIRED_PYTHON_MODULES[@]}"; do
            show_python_module_location "$module_name" || failed=1
        done
    fi

    show_ansible_collection_list || failed=1

    step "Final Lab 7 control-node setup summary"

    if [[ "$failed" -ne 0 ]]; then
        fail "Lab 7 control-node setup completed with one or more failures"
        return 1
    fi

    pass "Lab 7 control node is ready for cross-platform Ansible management"

    info "Linux management protocol: SSH"
    info "Windows management protocol: WinRM"
    info "Windows WinRM port: ${WINRM_PORT:-5985}"
    info "Windows WinRM transport: ${WINRM_TRANSPORT:-ntlm}"

    return 0
}


# ==============================================================================
# Main
# ==============================================================================

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
            fail "Unknown argument: ${1}"
            usage
            exit 2
            ;;
    esac
}


main "$@"
