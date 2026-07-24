#!/usr/bin/env bash
# ==============================================================================
# packages.sh
# ==============================================================================
#
# Shared package-management helpers for NSSA320 Lab 7.
#
# Purpose:
#  - Provide reusable package checks and installation helpers
#  - Support DNF-based Lab 7 Linux systems
#  - Verify required commands and packages
#  - Install EPEL when required
#  - Display package-manager and automation-tool information
#
# Design:
#  - This file must be sourced by another script.
#  - It does not automatically update or install packages.
#  - Calling scripts explicitly choose which functions to run.
#  - Package functions return meaningful status codes.
#  - Output is handled through lib/common.sh.
#
# RICE Framework:
#  - Reproducibility: Package checks and installations use consistent logic.
#  - Idempotency: Installed packages are detected before installation.
#  - Composability: Setup and verification scripts can reuse these functions.
#  - Evolvability: Additional package managers and requirements can be added.
#
# Dependencies:
#  - lib/common.sh must be sourced before this library is used.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
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
# Package Checks
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


# ==============================================================================
# Package Installation Helpers
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
    step "Checking Python 3 version"

    if ! command -v python3 >/dev/null 2>&1; then
        fail "python3 command not found"
        return 1
    fi

    python3 --version
    pass "Python 3 version displayed successfully"
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
