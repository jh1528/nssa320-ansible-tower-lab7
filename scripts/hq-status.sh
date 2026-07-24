#!/usr/bin/env bash
# ==============================================================================
# hq-status.sh
# ==============================================================================
#
# AWX headquarters status dashboard for NSSA320 Lab 7.
#
# Purpose:
#  - Show the current status of the AWX node as the Lab 7 headquarters
#  - Display Git branch and working-tree status
#  - Display hostname, IP addressing, routing, and role resolution
#  - Display evidence and archive status without modifying files
#  - Monitor storage, memory, and CPU load
#  - Provide a read-only operational snapshot before running Lab 7 automation
#
# Design:
#  - This script does not change system configuration.
#  - It does not create evidence directories or archive files.
#  - It sources reusable configuration and helper libraries.
#  - It is intended to run from the AWX node.
#  - It verifies that the AWX headquarters is ready to manage lab hosts.
#
# RICE Framework:
#  - Reproducibility: Runs the same headquarters checks each time.
#  - Idempotency: Read-only status checks do not alter system state.
#  - Composability: Uses common, health, hosts, network, and evidence helpers.
#  - Evolvability: Additional AWX and automation checks can be added later.
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
#  - Migrated the headquarters dashboard from Lab 4 to Lab 7.
#  - Replaced the RHEL control-node role with the AWX role.
#  - Added Windows 11 to the Lab 7 role-resolution overview.
#  - Updated configuration loading to use config/lab7.conf.
#  - Preserved Git, network, evidence, storage, memory, and CPU reporting.
#  - Removed automatic evidence-directory creation to keep the script read-only.
#  - Added warning and failure tracking for the final dashboard summary.
#
# Version: 1.0
# Date: 2026-06-10
#
# Changes:
#  - Added the first headquarters status dashboard.
#  - Added Git branch and working-tree status.
#  - Added hostname, network, and route overview.
#  - Added Lab role-resolution overview.
#  - Added evidence file and archive status.
#  - Added storage, memory, and CPU-load monitoring.
#
# Notes:
#  - This script is read-only.
#  - Missing evidence directories are reported but are not created.
#
# ==============================================================================

set -u


# ==============================================================================
# Path Setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

EVIDENCE_DIR="${BASE_DIR}/evidence"
ARCHIVE_DIR="${EVIDENCE_DIR}/archive"
PING_LOG="${EVIDENCE_DIR}/ping.log"


# ==============================================================================
# Load Shared Configuration and Libraries
# ==============================================================================

source "${BASE_DIR}/config/lab7.conf"
source "${BASE_DIR}/lib/common.sh"
source "${BASE_DIR}/lib/health.sh"
source "${BASE_DIR}/lib/hosts.sh"
source "${BASE_DIR}/lib/network.sh"
source "${BASE_DIR}/lib/evidence.sh"


# ==============================================================================
# Globals
# ==============================================================================

LAB7_ROLES=(
    "awx"
    "ansible1"
    "ansible2"
    "ubuntu"
    "win11"
)

DASHBOARD_FAILED=0
DASHBOARD_WARNED=0


# ==============================================================================
# Usage
# ==============================================================================

usage() {
    cat <<EOF
Usage:
  $0

Options:
  -h, --help    Show this help message

Description:
  Shows a read-only headquarters status dashboard for the Lab 7 AWX node.

  Includes:
    - Git branch and working-tree status
    - AWX hostname and network state
    - Lab 7 role and gateway resolution
    - Evidence and archive status
    - Storage, memory, and CPU-load checks

  This script reports system state but does not change configuration or create
  evidence directories.
EOF
}


# ==============================================================================
# Status Tracking
# ==============================================================================

record_dashboard_status() {
    local status="${1:-2}"

    case "$status" in
        0)
            return 0
            ;;
        1)
            DASHBOARD_WARNED=1
            return 0
            ;;
        *)
            DASHBOARD_FAILED=1
            return 0
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

get_resolution_line() {
    local short_name="${1:-}"
    local fqdn="${2:-}"
    local resolved_line

    resolved_line="$(
        getent hosts "$short_name" 2>/dev/null |
            head -n 1
    )"

    if [[ -z "$resolved_line" ]]; then
        resolved_line="$(
            getent hosts "$fqdn" 2>/dev/null |
                head -n 1
        )"
    fi

    printf '%s\n' "$resolved_line"
}


# ==============================================================================
# Git Status
# ==============================================================================

show_git_status() {
    local branch_name
    local upstream_name
    local ahead_count
    local behind_count

    step "Git source-of-truth status"

    if ! command -v git >/dev/null 2>&1; then
        warn "git command not found"
        return 1
    fi

    if ! git -C "$BASE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        warn "Repository directory is not a Git working tree: ${BASE_DIR}"
        return 1
    fi

    branch_name="$(
        git -C "$BASE_DIR" branch --show-current 2>/dev/null
    )"

    if [[ -z "$branch_name" ]]; then
        branch_name="detached HEAD"
    fi

    info "Repository: ${BASE_DIR}"
    info "Branch: ${branch_name}"

    if git -C "$BASE_DIR" diff --quiet &&
        git -C "$BASE_DIR" diff --cached --quiet; then
        pass "Git working tree is clean"
    else
        warn "Git working tree has local changes"
        git -C "$BASE_DIR" status --short
    fi

    upstream_name="$(
        git -C "$BASE_DIR" rev-parse \
            --abbrev-ref \
            --symbolic-full-name \
            '@{upstream}' \
            2>/dev/null || true
    )"

    if [[ -z "$upstream_name" ]]; then
        warn "Current branch does not have an upstream branch configured"
        return 1
    fi

    info "Upstream branch: ${upstream_name}"

    ahead_count="$(
        git -C "$BASE_DIR" rev-list \
            --count \
            "${upstream_name}..HEAD" \
            2>/dev/null || printf '%s\n' "unknown"
    )"

    behind_count="$(
        git -C "$BASE_DIR" rev-list \
            --count \
            "HEAD..${upstream_name}" \
            2>/dev/null || printf '%s\n' "unknown"
    )"

    info "Local commits ahead of upstream: ${ahead_count}"
    info "Local commits behind upstream: ${behind_count}"

    if [[ "$ahead_count" == "0" && "$behind_count" == "0" ]]; then
        pass "Local branch matches the currently known upstream state"
        return 0
    fi

    warn "Local branch differs from the currently known upstream state"
    return 1
}


# ==============================================================================
# Headquarters Identity
# ==============================================================================

show_hq_identity() {
    local expected_awx_fqdn
    local expected_awx_ip
    local current_hostname

    expected_awx_fqdn="$(get_host_fqdn_for_role awx)"
    expected_awx_ip="$(get_host_ip_for_role awx)"

    current_hostname="$(
        hostnamectl --static 2>/dev/null ||
            hostname
    )"

    step "AWX headquarters identity"

    info "Expected AWX hostname: ${expected_awx_fqdn}"
    info "Expected AWX IP: ${expected_awx_ip}/${SUBNET_PREFIX}"
    info "Current hostname: ${current_hostname}"

    if [[ "$current_hostname" == "$expected_awx_fqdn" ]]; then
        pass "This node matches the expected Lab 7 AWX hostname"
    elif [[ "$current_hostname" == "$AWX_HOST" ]]; then
        warn "This node uses the AWX short hostname instead of the expected FQDN"
        return 1
    else
        fail "This node hostname does not match the expected AWX hostname"
        return 2
    fi

    info "Current user: $(whoami)"
    info "Current date: $(date '+%Y-%m-%d %H:%M:%S %Z')"

    return 0
}


# ==============================================================================
# Role Resolution Overview
# ==============================================================================

show_role_resolution_overview() {
    local role
    local role_ip
    local role_fqdn
    local resolved_line
    local failed=0

    step "Lab 7 role resolution overview"

    printf '%-10s %-16s %-32s %-10s\n' \
        "ROLE" \
        "EXPECTED-IP" \
        "FQDN" \
        "STATUS"

    printf '%-10s %-16s %-32s %-10s\n' \
        "----------" \
        "----------------" \
        "--------------------------------" \
        "----------"

    for role in "${LAB7_ROLES[@]}"; do
        role_ip="$(get_host_ip_for_role "$role")"
        role_fqdn="$(get_host_fqdn_for_role "$role")"

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

            failed=1
        fi
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

        failed=1
    fi

    echo

    for role in "${LAB7_ROLES[@]}"; do
        role_fqdn="$(get_host_fqdn_for_role "$role")"

        if resolve_host "$role" "$role_fqdn"; then
            resolved_line="$(get_resolution_line "$role" "$role_fqdn")"
            pass "Resolved ${role}: ${resolved_line}"
        else
            fail "Could not resolve ${role} or ${role_fqdn}"
        fi
    done

    if resolve_host "$GATEWAY_HOST" "$GATEWAY_FQDN"; then
        resolved_line="$(
            get_resolution_line \
                "$GATEWAY_HOST" \
                "$GATEWAY_FQDN"
        )"

        pass "Resolved ${GATEWAY_HOST}: ${resolved_line}"
    else
        fail "Could not resolve ${GATEWAY_HOST} or ${GATEWAY_FQDN}"
    fi

    if [[ "$failed" -eq 0 ]]; then
        return 0
    fi

    return 2
}


# ==============================================================================
# Evidence Status
# ==============================================================================

show_evidence_status() {
    local archive_count=0
    local evidence_size="not available"
    local archive_size="not available"

    step "Evidence and archive status"

    if [[ ! -d "$EVIDENCE_DIR" ]]; then
        warn "Evidence directory does not exist yet: ${EVIDENCE_DIR}"
        info "It will be created by an evidence-producing workflow when needed."
        return 1
    fi

    if [[ -d "$ARCHIVE_DIR" ]]; then
        archive_count="$(
            find "$ARCHIVE_DIR" \
                -maxdepth 1 \
                -type f \
                2>/dev/null |
                wc -l
        )"

        archive_size="$(
            du -sh "$ARCHIVE_DIR" 2>/dev/null |
                awk '{print $1}'
        )"
    else
        warn "Archive directory does not exist yet: ${ARCHIVE_DIR}"
    fi

    evidence_size="$(
        du -sh "$EVIDENCE_DIR" 2>/dev/null |
            awk '{print $1}'
    )"

    show_evidence_location "$PING_LOG" "$ARCHIVE_DIR"

    info "Evidence directory size: ${evidence_size:-unknown}"
    info "Archive directory size: ${archive_size:-unknown}"
    info "Archived evidence-file count: ${archive_count}"

    if [[ -f "$PING_LOG" ]]; then
        pass "Current ping.log exists"
        ls -lh "$PING_LOG"
    else
        warn "Current ping.log does not exist yet"
    fi

    if (( archive_count > 20 )); then
        warn "Archive contains more than 20 evidence files"
        info "Review old attempts before deleting any professor-facing evidence."
        return 1
    fi

    pass "Archive file count is reasonable"
    return 0
}


# ==============================================================================
# Storage and System Health
# ==============================================================================

show_storage_monitor() {
    local status
    local failed=0
    local warned=0

    step "Storage monitor"

    if command -v df >/dev/null 2>&1; then
        info "Root filesystem usage:"
        df -h /
    else
        fail "Unable to display root filesystem usage: df command not found"
        return 2
    fi

    check_disk "/" 80 90
    status=$?

    if [[ "$status" -eq 1 ]]; then
        warned=1
    elif [[ "$status" -ne 0 ]]; then
        failed=1
    fi

    check_disk_free_gb "/" 5 2
    status=$?

    if [[ "$status" -eq 1 ]]; then
        warned=1
    elif [[ "$status" -ne 0 ]]; then
        failed=1
    fi

    step "Evidence storage monitor"

    if [[ -d "$EVIDENCE_DIR" ]]; then
        du -sh "$EVIDENCE_DIR" 2>/dev/null ||
            warn "Unable to calculate evidence directory size"

        if [[ -d "$ARCHIVE_DIR" ]]; then
            du -sh "$ARCHIVE_DIR" 2>/dev/null ||
                warn "Unable to calculate archive directory size"
        fi

        pass "Evidence storage check completed"
    else
        warn "Evidence directory does not exist yet: ${EVIDENCE_DIR}"
        warned=1
    fi

    if [[ "$failed" -eq 1 ]]; then
        return 2
    fi

    if [[ "$warned" -eq 1 ]]; then
        return 1
    fi

    return 0
}

show_system_health() {
    local status
    local failed=0
    local warned=0

    step "Basic system health"

    check_memory 80 95
    status=$?

    if [[ "$status" -eq 1 ]]; then
        warned=1
    elif [[ "$status" -ne 0 ]]; then
        failed=1
    fi

    check_memory_total_gb 2 1
    status=$?

    if [[ "$status" -eq 1 ]]; then
        warned=1
    elif [[ "$status" -ne 0 ]]; then
        failed=1
    fi

    check_cpu_load 2.00 4.00
    status=$?

    if [[ "$status" -eq 1 ]]; then
        warned=1
    elif [[ "$status" -ne 0 ]]; then
        failed=1
    fi

    if [[ "$failed" -eq 1 ]]; then
        return 2
    fi

    if [[ "$warned" -eq 1 ]]; then
        return 1
    fi

    return 0
}


# ==============================================================================
# Main
# ==============================================================================

main() {
    local status

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ "$#" -gt 0 ]]; then
        fail "This script does not accept positional arguments"
        usage
        exit 2
    fi

    step "Lab 7 AWX headquarters status dashboard"

    info "HQ role: AWX automation node"
    info "Purpose: authorized lab automation and evidence coordination"

    show_git_status
    status=$?
    record_dashboard_status "$status"

    show_hq_identity
    status=$?
    record_dashboard_status "$status"

    show_network_state
    status=$?
    record_dashboard_status "$status"

    show_role_resolution_overview
    status=$?
    record_dashboard_status "$status"

    show_evidence_status
    status=$?
    record_dashboard_status "$status"

    show_storage_monitor
    status=$?
    record_dashboard_status "$status"

    show_system_health
    status=$?
    record_dashboard_status "$status"

    step "AWX headquarters status summary"

    if [[ "$DASHBOARD_FAILED" -eq 1 ]]; then
        fail "AWX headquarters dashboard completed with one or more failures"
        exit 1
    fi

    if [[ "$DASHBOARD_WARNED" -eq 1 ]]; then
        warn "AWX headquarters dashboard completed with warnings"
        exit 0
    fi

    pass "AWX headquarters dashboard completed with no warnings"
    exit 0
}

main "$@"
