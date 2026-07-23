#!/usr/bin/env bash
# ==============================================================================
# common.sh
# ==============================================================================
#
# Shared output and safety helpers for NSSA320 Lab 7.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
#
# Version: 2.0
# Date: 2026-07-23
#
# Changes:
#  - Updated the source guard for the Lab 7 environment.
#  - Preserved shared output, validation, and safety helper functions.
#
# Version: 1.3
# Date: 2026-06-14
#
# Changes:
#  - Added require_not_root for workflows that must run as the normal student user.
#
# Version: 1.2
# Date: 2026-06-09
#
# Changes:
#  - Added source guard to prevent duplicate loading.
#  - Switched output helpers from echo -e to printf for safer formatting.
#  - Added shared safety helpers:
#      require_root
#      require_command
#      require_file
#      run_or_die
#  - Kept color-coded PASS/WARN/FAIL/INFO/STEP output for readable validation.
#
# Notes:
#  - This file is the shared reusable helper library for Lab 7 workflows.
#  - Lab 7 scripts should source this file instead of redefining output helpers.
#
# ==============================================================================


# ==============================================================================
# Source Guard
# ==============================================================================

if [[ -n "${LAB7_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi

LAB7_COMMON_SH_LOADED="true"


# ==============================================================================
# Color Initialization
# ==============================================================================

init_colors() {
    if [[ -t 1 ]]; then
        RED=$'\033[0;31m'
        YELLOW=$'\033[1;33m'
        GREEN=$'\033[0;32m'
        BLUE=$'\033[0;34m'
        CYAN=$'\033[0;36m'
        BOLD=$'\033[1m'
        NC=$'\033[0m'
    else
        RED=""
        YELLOW=""
        GREEN=""
        BLUE=""
        CYAN=""
        BOLD=""
        NC=""
    fi
}


# ==============================================================================
# General Output Helpers
# ==============================================================================

step() {
    printf '\n%s%s==> %s%s\n' "$BOLD" "$CYAN" "$*" "$NC"
}

info() {
    printf '%s[INFO]%s %s\n' "$BLUE" "$NC" "$*"
}


# ==============================================================================
# Check / Result Output Helpers
# ==============================================================================

pass() {
    printf '%s[PASS]%s %s\n' "$GREEN" "$NC" "$*"
}

warn() {
    printf '%s[WARN]%s %s\n' "$YELLOW" "$NC" "$*"
}

fail() {
    printf '%s[FAIL]%s %s\n' "$RED" "$NC" "$*"
}

die() {
    fail "$*"
    exit 1
}


# ==============================================================================
# Safety Helpers
# ==============================================================================

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run with sudo or as root."
    fi

    pass "Root privileges confirmed."
}

require_not_root() {
    if [[ "${EUID}" -eq 0 ]]; then
        die "This script must be run as the normal student user, not with sudo."
    fi

    pass "Normal user execution confirmed."
}

require_command() {
    local command_name="$1"

    if command -v "$command_name" >/dev/null 2>&1; then
        pass "Required command found: ${command_name}"
    else
        die "Required command not found: ${command_name}"
    fi
}

require_file() {
    local file_path="$1"

    if [[ -f "$file_path" ]]; then
        pass "Required file found: ${file_path}"
    else
        die "Required file not found: ${file_path}"
    fi
}

run_or_die() {
    local description="$1"
    shift

    info "$description"
    "$@" || die "Command failed: $description"
}


# ==============================================================================
# Initialization
# ==============================================================================

init_colors
