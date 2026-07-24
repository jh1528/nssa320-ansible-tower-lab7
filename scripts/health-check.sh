#!/usr/bin/env bash
# ==============================================================================
# health-check.sh
# ==============================================================================
#
# Read-only health-check script for NSSA320 Lab 7.
#
# Purpose:
#  - Validate that a Lab 7 Linux node is in a healthy state
#  - Check host identity, /etc/hosts resolution, network state, SSH status,
#    and basic system readiness
#  - Support checking one Linux role or displaying all Lab 7 role expectations
#  - Include the Windows 11 host in the all-role resolution overview
#  - Provide PASS, WARN, and FAIL output through shared common.sh helpers
#
# Design:
#  - This script does not change system configuration.
#  - It sources reusable configuration and libraries.
#  - It accepts one Linux role for deep local validation:
#      awx
#      ansible1
#      ansible2
#      ubuntu
#  - The all mode displays and validates resolution for:
#      awx
#      ansible1
#      ansible2
#      ubuntu
#      win11
#
# RICE Framework:
#  - Reproducibility: Runs the same validation process every time.
#  - Idempotency: Read-only checks do not alter system state.
#  - Composability: Combines common, health, hosts, network, and SSH libraries.
#  - Evolvability: Additional checks can be added without rewriting libraries.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
#
# Version: 2.0
# Date: 2026-07-24
#
# Changes:
#  - Migrated the health-check runner from Lab 4 to Lab 7.
#  - Replaced the control role with the AWX role.
#  - Added Windows 11 to the all-role host-resolution overview.
#  - Updated configuration loading to use config/lab7.conf.
#  - Preserved read-only hostname, network, SSH, disk, memory, and CPU checks.
#  - Added clearer handling for Linux-only deep health checks.
#
# Version: 1.1
# Date: 2026-06-10
#
# Changes:
#  - Added support for the all argument.
#  - Added all-role host-resolution summary.
#  - Added per-role expected IP and FQDN display.
#  - Kept deep system validation focused on the local/current node.
#
# Notes:
#  - Deep checks such as hostname, local IP, SSH service, memory, disk, and CPU
#    are only meaningful for the Linux VM where this script is running.
#  - Windows 11 is included in all mode for name-resolution verification.
#
# ==============================================================================

set -u


# ==============================================================================
# Path Setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"


# ==============================================================================
# Load Shared Configuration and Libraries
# ==============================================================================

source "${BASE_DIR}/config/lab7.conf"
source "${BASE_DIR}/lib/common.sh"
source "${BASE_DIR}/lib/health.sh"
source "${BASE_DIR}/lib/hosts.sh"
source "${BASE_DIR}/lib/network.sh"
source "${BASE_DIR}/lib/ssh.sh"


# ==============================================================================
# Globals
# ==============================================================================

LAB7_LINUX_ROLES=(
    "awx"
    "ansible1"
    "ansible2"
    "ubuntu"
)

LAB7_ALL_ROLES=(
    "awx"
    "ansible1"
    "ansible2"
    "ubuntu"
    "win11"
)


# ==============================================================================
# Usage and Argument Handling
# ==============================================================================

usage() {
    cat <<EOF
Usage:
  $0 <role>

Deep health-check roles:
  awx
  ansible1
  ansible2
  ubuntu

Overview mode:
  all

Examples:
  $0 awx
  $0 ansible1
  $0 ubuntu
  $0 all

Description:
  Runs read-only Lab 7 health checks for the selected Linux node.

  The all mode displays Lab 7 role definitions and validates local hostname
  resolution for AWX, the managed Linux hosts, Windows 11, and the gateway.

  Deep operating-system checks only apply to the Linux VM where this script
  is currently running.
EOF
}

validate_role_argument() {
    local role="${1:-}"

    case "$role" in
        awx|ansible1|ansible2|ubuntu|all)
            return 0
            ;;
        win11)
            fail "Deep local health checks are not supported for the Windows 11 host."
            info "Use '$0 all' to validate Windows 11 hostname resolution."
            exit 2
            ;;
        *)
            fail "Invalid role: ${role}"
            usage
            exit 2
            ;;
    esac
}


# ==============================================================================
# Host Resolution Helpers
# ==============================================================================

resolve_host() {
    local short_name="${1:-}"
    local fqdn="${2:-}"

    if [[ -z "$short_name" || -z "$fqdn" ]]; then
        return 1
    fi

    if getent hosts "$short_name" >/dev/null 2>&1; then
        return 0
    fi

    if getent hosts "$fqdn" >/dev/null 2>&1; then
        return 0
    fi

    return 1
}

show_resolution_result() {
    local role="${1:-}"
    local role_ip="${2:-}"
    local role_fqdn="${3:-}"

    if resolve_host "$role" "$role_fqdn"; then
        printf '%-10s %-16s %-32s %-10s\n' \
            "$role" \
            "$role_ip" \
            "$role_fqdn" \
            "PASS"
    else
        printf '%-10s %-16s %-32s %-10s\n' \
            "$role" \
            "$role_ip" \
            "$role_fqdn" \
            "FAIL"
    fi
}


# ==============================================================================
# All-Role Summary Helpers
# ==============================================================================

show_all_role_expectations() {
    local role
    local role_fqdn
    local role_ip

    step "Lab 7 role expectations"

    printf '%-10s %-16s %-32s %-10s\n' \
        "ROLE" \
        "IP" \
        "FQDN" \
        "RESOLUTION"

    printf '%-10s %-16s %-32s %-10s\n' \
        "----------" \
        "----------------" \
        "--------------------------------" \
        "----------"

    for role in "${LAB7_ALL_ROLES[@]}"; do
        role_ip="$(get_host_ip_for_role "$role")"
        role_fqdn="$(get_host_fqdn_for_role "$role")"

        show_resolution_result \
            "$role" \
            "$role_ip" \
            "$role_fqdn"
    done

    if resolve_host "$GATEWAY_HOST" "$GATEWAY_FQDN"; then
        printf '%-10s %-16s %-32s %-10s\n' \
            "$GATEWAY_HOST" \
            "$GATEWAY_IP" \
            "$GATEWAY_FQDN" \
            "PASS"
    else
        printf '%-10s %-16s %-32s %-10s\n' \
            "$GATEWAY_HOST" \
            "$GATEWAY_IP" \
            "$GATEWAY_FQDN" \
            "FAIL"
    fi
}

validate_all_role_resolution() {
    local failed=0
    local role
    local role_fqdn
    local result

    step "Validating all Lab 7 role name resolution"

    for role in "${LAB7_ALL_ROLES[@]}"; do
        role_fqdn="$(get_host_fqdn_for_role "$role")"

        if resolve_host "$role" "$role_fqdn"; then
            result="$(
                getent hosts "$role" 2>/dev/null |
                    head -n 1
            )"

            if [[ -z "$result" ]]; then
                result="$(
                    getent hosts "$role_fqdn" 2>/dev/null |
                        head -n 1
                )"
            fi

            pass "Resolved ${role}: ${result}"
        else
            fail "Could not resolve ${role} or ${role_fqdn}"
            failed=1
        fi
    done

    if resolve_host "$GATEWAY_HOST" "$GATEWAY_FQDN"; then
        result="$(
            getent hosts "$GATEWAY_HOST" 2>/dev/null |
                head -n 1
        )"

        if [[ -z "$result" ]]; then
            result="$(
                getent hosts "$GATEWAY_FQDN" 2>/dev/null |
                    head -n 1
            )"
        fi

        pass "Resolved ${GATEWAY_HOST}: ${result}"
    else
        fail "Could not resolve ${GATEWAY_HOST} or ${GATEWAY_FQDN}"
        failed=1
    fi

    return "$failed"
}

run_all_mode() {
    local failed=0

    step "Starting Lab 7 all-role health overview"

    info "Repository base directory: ${BASE_DIR}"
    info "Mode: all"

    show_all_role_expectations

    if ! validate_all_role_resolution; then
        failed=1
    fi

    step "All-role overview summary"

    if [[ "$failed" -eq 0 ]]; then
        pass "All Lab 7 roles resolve successfully from this node"
        return 0
    fi

    fail "One or more Lab 7 roles failed to resolve from this node"
    return 1
}


# ==============================================================================
# Health-Check Status Helper
# ==============================================================================

record_check_status() {
    local status="${1:-2}"
    local failed_variable="${2:-}"
    local warned_variable="${3:-}"

    case "$status" in
        0)
            return 0
            ;;
        1)
            printf -v "$warned_variable" '%d' 1
            return 0
            ;;
        *)
            printf -v "$failed_variable" '%d' 1
            return 0
            ;;
    esac
}


# ==============================================================================
# Single-Role Deep Health Check Logic
# ==============================================================================

run_single_role_health_check() {
    local role="${1:-}"
    local expected_fqdn
    local expected_ip
    local failed=0
    local warned=0
    local status=0

    expected_fqdn="$(get_host_fqdn_for_role "$role")"
    expected_ip="$(get_host_ip_for_role "$role")"

    step "Starting Lab 7 Linux health check"

    info "Repository base directory: ${BASE_DIR}"
    info "Selected role: ${role}"
    info "Expected FQDN: ${expected_fqdn}"
    info "Expected IP: ${expected_ip}/${SUBNET_PREFIX}"
    info "Expected gateway: ${GATEWAY_IP}"

    step "Checking required local commands"

    require_command hostname
    require_command hostnamectl
    require_command getent
    require_command ip
    require_command ping
    require_command systemctl
    require_command df
    require_command free
    require_command awk

    if command -v nmcli >/dev/null 2>&1; then
        pass "Required command found: nmcli"
    else
        fail "Required command not found: nmcli"
        failed=1
    fi

    step "Showing current network state"

    if ! show_network_state; then
        warned=1
    fi

    step "Validating host identity and network state"

    if ! validate_hostname_for_role "$role"; then
        failed=1
    fi

    if ! validate_hosts_resolution; then
        failed=1
    fi

    if ! validate_ip_for_role "$role"; then
        failed=1
    fi

    if ! validate_default_gateway; then
        failed=1
    fi

    if ! validate_gateway_ping; then
        failed=1
    fi

    if ! validate_dns_resolution "github.com"; then
        warned=1
    fi

    if ! validate_ssh_service; then
        failed=1
    fi

    step "Checking basic system readiness"

    check_disk "/" 80 90
    status=$?
    record_check_status "$status" failed warned

    check_disk_free_gb "/" 5 2
    status=$?
    record_check_status "$status" failed warned

    check_memory 80 95
    status=$?
    record_check_status "$status" failed warned

    check_memory_total_gb 2 1
    status=$?
    record_check_status "$status" failed warned

    check_cpu_load 2.00 4.00
    status=$?
    record_check_status "$status" failed warned

    step "Health check summary"

    if [[ "$failed" -eq 0 && "$warned" -eq 0 ]]; then
        pass "Lab 7 health check passed with no warnings for role: ${role}"
        return 0
    fi

    if [[ "$failed" -eq 0 && "$warned" -eq 1 ]]; then
        warn "Lab 7 health check passed with warnings for role: ${role}"
        return 0
    fi

    fail "Lab 7 health check failed for role: ${role}"
    return 1
}


# ==============================================================================
# Main
# ==============================================================================

main() {
    local role="${1:-}"

    if [[ -z "$role" ]]; then
        usage
        exit 2
    fi

    if [[ "$#" -gt 1 ]]; then
        fail "Too many arguments were provided"
        usage
        exit 2
    fi

    validate_role_argument "$role"

    if [[ "$role" == "all" ]]; then
        run_all_mode
        exit $?
    fi

    run_single_role_health_check "$role"
    exit $?
}

main "$@"
