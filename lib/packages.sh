#!/usr/bin/env bash
# ==============================================================================
# packages.sh
# ==============================================================================
#
# Shared package and automation dependency helpers for NSSA320 Lab 7.
#
# Purpose:
#  - Provide reusable system package checks and installation helpers.
#  - Support DNF-based Lab 7 Linux systems.
#  - Verify required commands and RPM packages.
#  - Install and verify required Python modules.
#  - Install and verify required Ansible collections.
#  - Preserve EPEL and system-update helpers for reusable RHEL workflows.
#  - Display package-manager and automation-tool information.
#
# Design:
#  - This file must be sourced by another script.
#  - It does not automatically update or install anything when sourced.
#  - Calling scripts explicitly choose which functions to run.
#  - Configuration values are provided by files such as:
#      - config/control-node.conf
#      - config/lab7.conf
#  - System package installation uses DNF/RPM.
#  - Python package installation uses the configured Python interpreter.
#  - Ansible collections are installed for the normal control-node user rather
#    than accidentally being installed only for root when a setup workflow is
#    executed with sudo.
#  - Output is handled through lib/common.sh.
#
# RICE Framework:
#  - Reproducibility:
#      Centralizes package, Python-module, and Ansible-collection management so
#      a Lab 7 control node can be rebuilt from declared requirements.
#
#  - Idempotency:
#      Existing packages, Python modules, commands, and collections are checked
#      before installation. Correct state is preserved on repeated runs.
#
#  - Composability:
#      Setup, bootstrap, validation, and health-check scripts can reuse these
#      functions without duplicating dependency-management logic.
#
#  - Evolvability:
#      Additional RPM packages, Python modules, Ansible collections, or future
#      dependency types can be added through configuration without redesigning
#      the existing setup workflows.
#
# Dependencies:
#  - lib/common.sh must be sourced before this library is used.
#
# Security:
#  - This library does not store passwords, API tokens, SSH private keys,
#    AWX credentials, or other secrets.
#  - Python and Ansible dependency names come from configuration only.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
#
# Version: 4.0
# Date: 2026-08-07
#
# Changes:
#  - Extended the Lab 7 package library for cross-platform Ansible management.
#  - Added configurable Python-runtime helpers.
#  - Added Python module validation and installation helpers.
#  - Added pywinrm-aware package resolution for the winrm Python module.
#  - Added Ansible collection validation and installation helpers.
#  - Added normal-user collection-path handling when setup runs with sudo.
#  - Added LAB7_REQUIRED_PYTHON_MODULES support.
#  - Added LAB7_REQUIRED_COLLECTIONS support.
#  - Preserved existing DNF, RPM, EPEL, system-update, command, Ansible,
#    and Python verification workflows.
#  - Preserved compatibility with older Lab 4 Activity 2 configuration arrays.
#
# Version: 3.0
# Date: 2026-07-24
#
# Changes:
#  - Migrated the package library from Lab 4 to Lab 7.
#  - Removed Activity 2-specific wording and variable dependencies.
#  - Added a Lab 7 source guard.
#  - Added safer command and argument validation.
#  - Added reusable array-based package and command helpers.
#  - Preserved DNF, RPM, EPEL, Ansible, and Python verification functions.
#  - Added compatibility wrappers for older Lab 4 calling scripts.
#
# Version: 2.0
#
# Changes:
#  - Added the initial package helper library for Lab 4 Activity 2.
#
# Notes:
#  - DNF and RPM helpers apply to RHEL-compatible systems.
#  - Ubuntu package support can be added separately when required.
#
# ==============================================================================


# ==============================================================================
# Execution Guard
# ==============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf '%s\n' \
        "[FAIL] lib/packages.sh is a shared library and must be sourced." \
        "[INFO] Example: source lib/packages.sh"

    exit 1
fi


# ==============================================================================
# Source Guard
# ==============================================================================

if [[ -n "${LAB7_PACKAGES_SH_LOADED:-}" ]]; then
    return 0
fi

LAB7_PACKAGES_SH_LOADED="true"


# ==============================================================================
# Internal Validation Helpers
# ==============================================================================

_validate_package_name() {
    local package_name="${1:-}"

    if [[ -z "$package_name" ]]; then
        fail "Package name cannot be empty"
        return 2
    fi

    return 0
}


_validate_command_name() {
    local command_name="${1:-}"

    if [[ -z "$command_name" ]]; then
        fail "Command name cannot be empty"
        return 2
    fi

    return 0
}


_validate_python_module_name() {
    local module_name="${1:-}"

    if [[ -z "$module_name" ]]; then
        fail "Python module name cannot be empty"
        return 2
    fi

    if ! [[ "$module_name" =~ ^[A-Za-z_][A-Za-z0-9_.]*$ ]]; then
        fail "Invalid Python module name: ${module_name}"
        return 2
    fi

    return 0
}


_validate_python_package_name() {
    local package_name="${1:-}"

    if [[ -z "$package_name" ]]; then
        fail "Python package name cannot be empty"
        return 2
    fi

    return 0
}


_validate_ansible_collection_name() {
    local collection_spec="${1:-}"
    local collection_name

    if [[ -z "$collection_spec" ]]; then
        fail "Ansible collection name cannot be empty"
        return 2
    fi

    # Allow configuration to use:
    #
    #   ansible.windows
    #
    # or a future pinned specification such as:
    #
    #   ansible.windows:VERSION
    #
    collection_name="${collection_spec%%:*}"

    if ! [[ "$collection_name" =~ ^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$ ]]; then
        fail "Invalid Ansible collection name: ${collection_spec}"
        return 2
    fi

    return 0
}


_require_dnf_environment() {
    local failed=0

    if ! command -v dnf >/dev/null 2>&1; then
        fail "Required package manager not found: dnf"
        failed=1
    fi

    if ! command -v rpm >/dev/null 2>&1; then
        fail "Required package database command not found: rpm"
        failed=1
    fi

    if [[ "$failed" -ne 0 ]]; then
        return 2
    fi

    return 0
}


# ==============================================================================
# Privilege Checks
# ==============================================================================

require_root() {
    step "Checking root privileges"

    if [[ "${EUID}" -ne 0 ]]; then
        fail "This action requires root privileges"
        warn "Run the calling script with sudo when using an apply operation"
        return 1
    fi

    pass "Running with root privileges"
    return 0
}


# ==============================================================================
# Control Node User Helpers
# ==============================================================================

get_control_node_user() {
    if [[ -n "${LAB7_CONTROL_NODE_USER:-}" ]]; then
        printf '%s\n' "$LAB7_CONTROL_NODE_USER"
        return 0
    fi

    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
        printf '%s\n' "$SUDO_USER"
        return 0
    fi

    printf '%s\n' "$(id -un)"
}


get_control_node_home() {
    local control_user
    local control_home

    control_user="$(get_control_node_user)"

    control_home="$(
        getent passwd "$control_user" 2>/dev/null |
            awk -F: 'NR == 1 {print $6}'
    )"

    if [[ -z "$control_home" ]]; then
        fail "Unable to determine home directory for user: ${control_user}"
        return 1
    fi

    printf '%s\n' "$control_home"
}


get_ansible_collection_path() {
    local control_home

    if [[ -n "${LAB7_ANSIBLE_COLLECTION_PATH:-}" ]]; then
        printf '%s\n' "$LAB7_ANSIBLE_COLLECTION_PATH"
        return 0
    fi

    if ! control_home="$(get_control_node_home)"; then
        return 1
    fi

    printf '%s\n' "${control_home}/.ansible/collections"
}


ensure_ansible_collection_path() {
    local collection_path
    local control_user

    if ! collection_path="$(get_ansible_collection_path)"; then
        return 1
    fi

    control_user="$(get_control_node_user)"

    if [[ -d "$collection_path" ]]; then
        return 0
    fi

    info "Creating Ansible collection path: ${collection_path}"

    if [[ "${EUID}" -eq 0 && "$control_user" != "root" ]]; then
        mkdir -p "$collection_path" || return 1
        chown -R "${control_user}:${control_user}" "$(dirname "$collection_path")" \
            || return 1
    else
        mkdir -p "$collection_path" || return 1
    fi

    return 0
}


# ==============================================================================
# Command Checks
# ==============================================================================

check_command_available() {
    local command_name="${1:-}"

    if ! _validate_command_name "$command_name"; then
        return 2
    fi

    step "Checking required command: ${command_name}"

    if command -v "$command_name" >/dev/null 2>&1; then
        pass "Required command found: ${command_name}"
        return 0
    fi

    fail "Required command not found: ${command_name}"
    return 1
}


check_command_list() {
    local command_name
    local failed=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: check_command_list <command> [command ...]"
        return 2
    fi

    step "Checking required commands"

    for command_name in "$@"; do
        if ! check_command_available "$command_name"; then
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        fail "One or more required commands are unavailable"
        return 1
    fi

    pass "All required commands are available"
    return 0
}


check_required_commands() {
    if declare -p LAB7_REQUIRED_COMMANDS >/dev/null 2>&1; then
        check_command_list "${LAB7_REQUIRED_COMMANDS[@]}"
        return $?
    fi

    if declare -p ACTIVITY2_REQUIRED_COMMANDS >/dev/null 2>&1; then
        warn "Using legacy ACTIVITY2_REQUIRED_COMMANDS configuration"
        check_command_list "${ACTIVITY2_REQUIRED_COMMANDS[@]}"
        return $?
    fi

    fail "No required-command array is configured"
    info "Define LAB7_REQUIRED_COMMANDS in the calling configuration file"
    return 2
}


# ==============================================================================
# RPM Package Checks
# ==============================================================================

check_package_installed() {
    local package_name="${1:-}"

    if ! _validate_package_name "$package_name"; then
        return 2
    fi

    if ! command -v rpm >/dev/null 2>&1; then
        fail "Cannot check package ${package_name}: rpm command not found"
        return 2
    fi

    step "Checking installed package: ${package_name}"

    if rpm -q "$package_name" >/dev/null 2>&1; then
        pass "Package is installed: ${package_name}"
        return 0
    fi

    warn "Package is not installed: ${package_name}"
    return 1
}


check_package_list() {
    local package_name
    local missing=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: check_package_list <package> [package ...]"
        return 2
    fi

    step "Checking required packages"

    for package_name in "$@"; do
        if ! check_package_installed "$package_name"; then
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        warn "One or more required packages are not installed"
        return 1
    fi

    pass "All required packages are installed"
    return 0
}


check_required_packages() {
    if declare -p LAB7_REQUIRED_PACKAGES >/dev/null 2>&1; then
        check_package_list "${LAB7_REQUIRED_PACKAGES[@]}"
        return $?
    fi

    if declare -p ACTIVITY2_REQUIRED_PACKAGES >/dev/null 2>&1; then
        warn "Using legacy ACTIVITY2_REQUIRED_PACKAGES configuration"
        check_package_list "${ACTIVITY2_REQUIRED_PACKAGES[@]}"
        return $?
    fi

    fail "No required-package array is configured"
    info "Define LAB7_REQUIRED_PACKAGES in the calling configuration file"
    return 2
}


# ==============================================================================
# RPM Package Installation Helpers
# ==============================================================================

install_package_if_missing() {
    local package_name="${1:-}"

    if ! _validate_package_name "$package_name"; then
        return 2
    fi

    if ! _require_dnf_environment; then
        return 2
    fi

    step "Ensuring package is installed: ${package_name}"

    if rpm -q "$package_name" >/dev/null 2>&1; then
        pass "Package already installed: ${package_name}"
        return 0
    fi

    if ! require_root; then
        return 1
    fi

    info "Installing package: ${package_name}"

    if ! dnf install -y "$package_name"; then
        fail "Package installation failed: ${package_name}"
        return 1
    fi

    if rpm -q "$package_name" >/dev/null 2>&1; then
        pass "Package installation completed: ${package_name}"
        return 0
    fi

    fail "Package installation command completed, but the package was not detected: ${package_name}"
    return 1
}


install_package_list() {
    local package_name
    local failed=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: install_package_list <package> [package ...]"
        return 2
    fi

    step "Installing required packages"

    for package_name in "$@"; do
        if ! install_package_if_missing "$package_name"; then
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        fail "One or more package installations failed"
        return 1
    fi

    pass "All required packages are installed"
    return 0
}


install_required_packages() {
    if declare -p LAB7_REQUIRED_PACKAGES >/dev/null 2>&1; then
        install_package_list "${LAB7_REQUIRED_PACKAGES[@]}"
        return $?
    fi

    if declare -p ACTIVITY2_REQUIRED_PACKAGES >/dev/null 2>&1; then
        warn "Using legacy ACTIVITY2_REQUIRED_PACKAGES configuration"
        install_package_list "${ACTIVITY2_REQUIRED_PACKAGES[@]}"
        return $?
    fi

    fail "No required-package array is configured"
    info "Define LAB7_REQUIRED_PACKAGES in the calling configuration file"
    return 2
}


# ==============================================================================
# Python Runtime Helpers
# ==============================================================================

get_lab7_python_bin() {
    if [[ -n "${LAB7_PYTHON_BIN:-}" ]]; then
        printf '%s\n' "$LAB7_PYTHON_BIN"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        command -v python3
        return 0
    fi

    fail "No Lab 7 Python interpreter is configured or available"
    return 1
}


check_python_runtime() {
    local python_bin

    step "Checking configured Python runtime"

    if ! python_bin="$(get_lab7_python_bin)"; then
        return 1
    fi

    if [[ ! -x "$python_bin" ]]; then
        fail "Configured Python interpreter is not executable: ${python_bin}"
        return 1
    fi

    "$python_bin" --version
    pass "Python runtime available: ${python_bin}"
    return 0
}


check_python_pip() {
    local python_bin

    step "Checking pip for the configured Python runtime"

    if ! python_bin="$(get_lab7_python_bin)"; then
        return 1
    fi

    if "$python_bin" -m pip --version >/dev/null 2>&1; then
        "$python_bin" -m pip --version
        pass "pip is available for: ${python_bin}"
        return 0
    fi

    fail "pip is not available for: ${python_bin}"
    return 1
}


# ==============================================================================
# Python Module Resolution Helpers
# ==============================================================================

get_python_package_for_module() {
    local module_name="${1:-}"

    if ! _validate_python_module_name "$module_name"; then
        return 2
    fi

    case "$module_name" in
        winrm)
            printf '%s\n' "${LAB7_WINRM_PYTHON_PACKAGE:-pywinrm}"
            ;;
        *)
            printf '%s\n' "$module_name"
            ;;
    esac
}


# ==============================================================================
# Python Module Checks
# ==============================================================================

check_python_module() {
    local module_name="${1:-}"
    local python_bin

    if ! _validate_python_module_name "$module_name"; then
        return 2
    fi

    if ! python_bin="$(get_lab7_python_bin)"; then
        return 1
    fi

    step "Checking Python module: ${module_name}"

    if "$python_bin" -c "import ${module_name}" >/dev/null 2>&1; then
        pass "Python module is available: ${module_name}"
        return 0
    fi

    warn "Python module is not available: ${module_name}"
    return 1
}


check_python_module_list() {
    local module_name
    local missing=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: check_python_module_list <module> [module ...]"
        return 2
    fi

    step "Checking required Python modules"

    for module_name in "$@"; do
        if ! check_python_module "$module_name"; then
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        warn "One or more required Python modules are unavailable"
        return 1
    fi

    pass "All required Python modules are available"
    return 0
}


check_required_python_modules() {
    if ! declare -p LAB7_REQUIRED_PYTHON_MODULES >/dev/null 2>&1; then
        fail "No required Python-module array is configured"
        info "Define LAB7_REQUIRED_PYTHON_MODULES in config/control-node.conf"
        return 2
    fi

    check_python_module_list "${LAB7_REQUIRED_PYTHON_MODULES[@]}"
}


# ==============================================================================
# Python Module Installation Helpers
# ==============================================================================

install_python_module_if_missing() {
    local module_name="${1:-}"
    local python_package
    local python_bin

    if ! _validate_python_module_name "$module_name"; then
        return 2
    fi

    if check_python_module "$module_name"; then
        return 0
    fi

    if ! python_bin="$(get_lab7_python_bin)"; then
        return 1
    fi

    if ! python_package="$(get_python_package_for_module "$module_name")"; then
        return 1
    fi

    if ! _validate_python_package_name "$python_package"; then
        return 2
    fi

    step "Installing Python dependency for module: ${module_name}"

    if ! "$python_bin" -m pip --version >/dev/null 2>&1; then
        fail "pip is unavailable for configured Python runtime: ${python_bin}"
        info "Install the configured pip RPM before installing Python modules"
        return 1
    fi

    if ! require_root; then
        return 1
    fi

    info "Python interpreter: ${python_bin}"
    info "Python package: ${python_package}"
    info "Python import name: ${module_name}"

    if ! "$python_bin" -m pip install "$python_package"; then
        fail "Python package installation failed: ${python_package}"
        return 1
    fi

    if "$python_bin" -c "import ${module_name}" >/dev/null 2>&1; then
        pass "Python module installation completed: ${module_name}"
        return 0
    fi

    fail "Python package installed, but module import still failed: ${module_name}"
    return 1
}


install_python_module_list() {
    local module_name
    local failed=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: install_python_module_list <module> [module ...]"
        return 2
    fi

    step "Installing required Python modules"

    for module_name in "$@"; do
        if ! install_python_module_if_missing "$module_name"; then
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        fail "One or more Python module installations failed"
        return 1
    fi

    pass "All required Python modules are available"
    return 0
}


install_required_python_modules() {
    if ! declare -p LAB7_REQUIRED_PYTHON_MODULES >/dev/null 2>&1; then
        fail "No required Python-module array is configured"
        info "Define LAB7_REQUIRED_PYTHON_MODULES in config/control-node.conf"
        return 2
    fi

    install_python_module_list "${LAB7_REQUIRED_PYTHON_MODULES[@]}"
}


# ==============================================================================
# Ansible Collection Helpers
# ==============================================================================

get_collection_base_name() {
    local collection_spec="${1:-}"

    if ! _validate_ansible_collection_name "$collection_spec"; then
        return 2
    fi

    printf '%s\n' "${collection_spec%%:*}"
}


get_collection_namespace() {
    local collection_name="${1:-}"

    collection_name="${collection_name%%:*}"

    printf '%s\n' "${collection_name%%.*}"
}


get_collection_short_name() {
    local collection_name="${1:-}"

    collection_name="${collection_name%%:*}"

    printf '%s\n' "${collection_name#*.}"
}


get_collection_directory() {
    local collection_spec="${1:-}"
    local collection_path
    local collection_name
    local namespace
    local short_name

    if ! collection_path="$(get_ansible_collection_path)"; then
        return 1
    fi

    if ! collection_name="$(get_collection_base_name "$collection_spec")"; then
        return 1
    fi

    namespace="$(get_collection_namespace "$collection_name")"
    short_name="$(get_collection_short_name "$collection_name")"

    printf '%s\n' \
        "${collection_path}/ansible_collections/${namespace}/${short_name}"
}


run_as_control_node_user() {
    local control_user

    control_user="$(get_control_node_user)"

    if [[ "${EUID}" -eq 0 && "$control_user" != "root" ]]; then
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "$control_user" -- "$@"
            return $?
        fi

        if command -v sudo >/dev/null 2>&1; then
            sudo -u "$control_user" -- "$@"
            return $?
        fi

        fail "Unable to execute command as control-node user: ${control_user}"
        fail "Neither runuser nor sudo is available"
        return 1
    fi

    "$@"
}


# ==============================================================================
# Ansible Collection Checks
# ==============================================================================

check_ansible_collection() {
    local collection_spec="${1:-}"
    local collection_name
    local collection_dir
    local system_collection_dir
    local namespace
    local short_name

    if ! _validate_ansible_collection_name "$collection_spec"; then
        return 2
    fi

    if ! collection_name="$(get_collection_base_name "$collection_spec")"; then
        return 1
    fi

    namespace="$(get_collection_namespace "$collection_name")"
    short_name="$(get_collection_short_name "$collection_name")"

    if ! collection_dir="$(get_collection_directory "$collection_spec")"; then
        return 1
    fi

    system_collection_dir="/usr/share/ansible/collections/ansible_collections/${namespace}/${short_name}"

    step "Checking Ansible collection: ${collection_name}"

    if [[ -d "$collection_dir" ]]; then
        pass "Ansible collection found in user collection path: ${collection_name}"
        return 0
    fi

    if [[ -d "$system_collection_dir" ]]; then
        pass "Ansible collection found in system collection path: ${collection_name}"
        return 0
    fi

    warn "Ansible collection is not installed: ${collection_name}"
    return 1
}


check_ansible_collection_list() {
    local collection_spec
    local missing=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: check_ansible_collection_list <collection> [collection ...]"
        return 2
    fi

    step "Checking required Ansible collections"

    for collection_spec in "$@"; do
        if ! check_ansible_collection "$collection_spec"; then
            missing=1
        fi
    done

    if [[ "$missing" -ne 0 ]]; then
        warn "One or more required Ansible collections are unavailable"
        return 1
    fi

    pass "All required Ansible collections are available"
    return 0
}


check_required_ansible_collections() {
    if ! declare -p LAB7_REQUIRED_COLLECTIONS >/dev/null 2>&1; then
        fail "No required Ansible-collection array is configured"
        info "Define LAB7_REQUIRED_COLLECTIONS in config/control-node.conf"
        return 2
    fi

    check_ansible_collection_list "${LAB7_REQUIRED_COLLECTIONS[@]}"
}


# ==============================================================================
# Ansible Collection Installation Helpers
# ==============================================================================

install_ansible_collection_if_missing() {
    local collection_spec="${1:-}"
    local collection_name
    local collection_path
    local control_user

    if ! _validate_ansible_collection_name "$collection_spec"; then
        return 2
    fi

    if check_ansible_collection "$collection_spec"; then
        return 0
    fi

    if ! command -v ansible-galaxy >/dev/null 2>&1; then
        fail "Cannot install Ansible collection: ansible-galaxy command not found"
        return 1
    fi

    if ! collection_name="$(get_collection_base_name "$collection_spec")"; then
        return 1
    fi

    if ! collection_path="$(get_ansible_collection_path)"; then
        return 1
    fi

    control_user="$(get_control_node_user)"

    step "Installing Ansible collection: ${collection_spec}"

    if ! ensure_ansible_collection_path; then
        fail "Unable to prepare Ansible collection path: ${collection_path}"
        return 1
    fi

    info "Collection: ${collection_spec}"
    info "Collection path: ${collection_path}"
    info "Collection owner: ${control_user}"

    if ! run_as_control_node_user \
        ansible-galaxy collection install \
        "$collection_spec" \
        --collections-path "$collection_path"
    then
        fail "Ansible collection installation failed: ${collection_spec}"
        return 1
    fi

    if check_ansible_collection "$collection_name"; then
        pass "Ansible collection installation completed: ${collection_name}"
        return 0
    fi

    fail "Collection installation completed, but collection was not detected: ${collection_name}"
    return 1
}


install_ansible_collection_list() {
    local collection_spec
    local failed=0

    if [[ "$#" -eq 0 ]]; then
        fail "Usage: install_ansible_collection_list <collection> [collection ...]"
        return 2
    fi

    step "Installing required Ansible collections"

    for collection_spec in "$@"; do
        if ! install_ansible_collection_if_missing "$collection_spec"; then
            failed=1
        fi
    done

    if [[ "$failed" -ne 0 ]]; then
        fail "One or more Ansible collection installations failed"
        return 1
    fi

    pass "All required Ansible collections are available"
    return 0
}


install_required_ansible_collections() {
    if ! declare -p LAB7_REQUIRED_COLLECTIONS >/dev/null 2>&1; then
        fail "No required Ansible-collection array is configured"
        info "Define LAB7_REQUIRED_COLLECTIONS in config/control-node.conf"
        return 2
    fi

    install_ansible_collection_list "${LAB7_REQUIRED_COLLECTIONS[@]}"
}


# ==============================================================================
# EPEL Helpers
# ==============================================================================

get_epel_package_name() {
    if [[ -n "${LAB7_EPEL_PACKAGE:-}" ]]; then
        printf '%s\n' "$LAB7_EPEL_PACKAGE"
        return 0
    fi

    if [[ -n "${ACTIVITY2_EPEL_PACKAGE:-}" ]]; then
        printf '%s\n' "$ACTIVITY2_EPEL_PACKAGE"
        return 0
    fi

    printf '%s\n' "epel-release"
}


get_epel_install_source() {
    if [[ -n "${LAB7_EPEL_RPM_URL:-}" ]]; then
        printf '%s\n' "$LAB7_EPEL_RPM_URL"
        return 0
    fi

    if [[ -n "${ACTIVITY2_EPEL_RPM_URL:-}" ]]; then
        printf '%s\n' "$ACTIVITY2_EPEL_RPM_URL"
        return 0
    fi

    printf '%s\n' "epel-release"
}


check_epel_installed() {
    local epel_package

    epel_package="$(get_epel_package_name)"
    check_package_installed "$epel_package"
}


install_epel_if_missing() {
    local epel_package
    local epel_source

    if ! _require_dnf_environment; then
        return 2
    fi

    epel_package="$(get_epel_package_name)"
    epel_source="$(get_epel_install_source)"

    step "Ensuring EPEL is installed"

    if rpm -q "$epel_package" >/dev/null 2>&1; then
        pass "EPEL package already installed: ${epel_package}"
        return 0
    fi

    if ! require_root; then
        return 1
    fi

    info "Installing EPEL from: ${epel_source}"

    if ! dnf install -y "$epel_source"; then
        fail "EPEL installation failed"
        return 1
    fi

    if rpm -q "$epel_package" >/dev/null 2>&1; then
        pass "EPEL installation completed"
        return 0
    fi

    fail "EPEL installation command completed, but ${epel_package} was not detected"
    return 1
}


# ==============================================================================
# System Update Helper
# ==============================================================================

dnf_update_system() {
    if ! command -v dnf >/dev/null 2>&1; then
        fail "Cannot update system packages: dnf command not found"
        return 2
    fi

    step "Updating system packages with DNF"

    if ! require_root; then
        return 1
    fi

    info "Running: dnf update -y"

    if ! dnf update -y; then
        fail "DNF system update failed"
        return 1
    fi

    pass "DNF system update completed"
    return 0
}


# ==============================================================================
# Verification Helpers
# ==============================================================================

show_ansible_version() {
    step "Checking Ansible version"

    if ! command -v ansible >/dev/null 2>&1; then
        fail "Ansible command not found"
        return 1
    fi

    ansible --version
    pass "Ansible version displayed successfully"
    return 0
}


show_ansible_galaxy_version() {
    step "Checking Ansible Galaxy version"

    if ! command -v ansible-galaxy >/dev/null 2>&1; then
        fail "ansible-galaxy command not found"
        return 1
    fi

    ansible-galaxy --version
    pass "Ansible Galaxy version displayed successfully"
    return 0
}


show_ansible_navigator_version() {
    step "Checking Ansible Navigator version"

    if ! command -v ansible-navigator >/dev/null 2>&1; then
        warn "ansible-navigator command not found"
        return 1
    fi

    ansible-navigator --version
    pass "Ansible Navigator version displayed successfully"
    return 0
}


show_python_version() {
    local python_bin

    step "Checking configured Python version"

    if ! python_bin="$(get_lab7_python_bin)"; then
        return 1
    fi

    if [[ ! -x "$python_bin" ]]; then
        fail "Configured Python interpreter is not executable: ${python_bin}"
        return 1
    fi

    "$python_bin" --version
    pass "Configured Python version displayed successfully"
    return 0
}


show_python_module_location() {
    local module_name="${1:-}"
    local python_bin

    if ! _validate_python_module_name "$module_name"; then
        return 2
    fi

    if ! python_bin="$(get_lab7_python_bin)"; then
        return 1
    fi

    step "Showing Python module location: ${module_name}"

    if ! "$python_bin" -c \
        "import ${module_name}; print(${module_name}.__file__)"
    then
        warn "Python module is unavailable: ${module_name}"
        return 1
    fi

    pass "Python module location displayed: ${module_name}"
    return 0
}


show_ansible_collection_list() {
    local collection_path

    step "Showing installed Ansible collections"

    if ! command -v ansible-galaxy >/dev/null 2>&1; then
        fail "ansible-galaxy command not found"
        return 1
    fi

    if ! collection_path="$(get_ansible_collection_path)"; then
        return 1
    fi

    if [[ ! -d "$collection_path" ]]; then
        warn "User collection path does not exist: ${collection_path}"
        return 1
    fi

    if ! run_as_control_node_user \
        ansible-galaxy collection list \
        --collections-path "$collection_path"
    then
        fail "Unable to display Ansible collection list"
        return 1
    fi

    pass "Ansible collection list displayed successfully"
    return 0
}


show_dnf_repolist() {
    step "Showing enabled DNF repositories"

    if ! command -v dnf >/dev/null 2>&1; then
        fail "dnf command not found"
        return 1
    fi

    if ! dnf repolist; then
        fail "Unable to display enabled DNF repositories"
        return 1
    fi

    pass "DNF repository list displayed successfully"
    return 0
}


show_installed_package_version() {
    local package_name="${1:-}"

    if ! _validate_package_name "$package_name"; then
        return 2
    fi

    step "Showing installed package version: ${package_name}"

    if ! command -v rpm >/dev/null 2>&1; then
        fail "rpm command not found"
        return 2
    fi

    if ! rpm -q "$package_name"; then
        warn "Package is not installed: ${package_name}"
        return 1
    fi

    pass "Package version displayed successfully: ${package_name}"
    return 0
}


# ==============================================================================
# Combined Lab 7 Control Node Dependency Checks
# ==============================================================================

check_control_node_dependencies() {
    local failed=0

    step "Checking Lab 7 control-node dependencies"

    if ! check_required_packages; then
        failed=1
    fi

    if ! check_required_commands; then
        failed=1
    fi

    if ! check_python_runtime; then
        failed=1
    fi

    if ! check_python_pip; then
        failed=1
    fi

    if ! check_required_python_modules; then
        failed=1
    fi

    if ! check_required_ansible_collections; then
        failed=1
    fi

    step "Lab 7 control-node dependency summary"

    if [[ "$failed" -ne 0 ]]; then
        fail "One or more Lab 7 control-node dependencies are unavailable"
        return 1
    fi

    pass "All Lab 7 control-node dependencies are available"
    return 0
}


# ==============================================================================
# Combined Lab 7 Control Node Dependency Installation
# ==============================================================================

install_control_node_dependencies() {
    local failed=0

    step "Installing Lab 7 control-node dependencies"

    if ! install_required_packages; then
        failed=1
    fi

    # The Python runtime and pip package are expected to be supplied by the
    # required RPM package configuration before Python modules are installed.

    if ! check_python_runtime; then
        failed=1
    fi

    if ! check_python_pip; then
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        if ! install_required_python_modules; then
            failed=1
        fi
    else
        warn "Skipping Python module installation because the Python runtime or pip is not ready"
    fi

    if ! install_required_ansible_collections; then
        failed=1
    fi

    step "Lab 7 control-node installation summary"

    if [[ "$failed" -ne 0 ]]; then
        fail "One or more Lab 7 control-node dependencies could not be installed"
        return 1
    fi

    pass "Lab 7 control-node dependency installation completed successfully"
    return 0
}
