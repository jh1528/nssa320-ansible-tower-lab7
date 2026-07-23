#!/usr/bin/env bash
# ==============================================================================
# bootstrap-node.sh
# ==============================================================================
#
# Lab 7 bootstrap script for NSSA320.
#
# Purpose:
#  - Configure a Lab 7 Linux VM to match its assigned role
#  - Set the correct system hostname
#  - Write the Lab 7 managed /etc/hosts block
#  - Apply static network settings from config/lab7.conf
#  - Install, enable, and start the OpenSSH server when needed
#  - Run validation after configuration
#
# Design:
#  - This is an apply/configuration script.
#  - It supports --dry-run and --apply modes.
#  - It sources reusable configuration and library files.
#  - Package changes are intentionally minimal.
#  - Full operating-system updates are not performed.
#
# Supported Roles:
#  - awx
#  - ansible1
#  - ansible2
#  - ubuntu
#
# RICE Framework:
#  - Reproducibility: Role configuration comes from config/lab7.conf.
#  - Idempotency: Re-running should converge on the same hostname, hosts file,
#    network settings, and SSH service state.
#  - Composability: Uses common, hosts, network, and SSH helper libraries.
#  - Evolvability: Additional Lab 7 automation can be added without rewriting
#    the node bootstrap workflow.
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
#  - Converted the Lab 4 bootstrap workflow for Lab 7.
#  - Replaced the control role with the awx role.
#  - Updated the configuration source to config/lab7.conf.
#  - Updated messages and documentation for the Lab 7 environment.
#  - Preserved dry-run, apply, hostname, network, SSH, and validation workflows.
#
# Notes:
#  - This script intentionally does not run full operating-system updates.
#  - This script intentionally does not configure Ansible users, SSH keys,
#    privilege escalation, or AWX itself.
#  - Windows 11 is configured separately and is not supported by this script.
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
source "${BASE_DIR}/lib/hosts.sh"
source "${BASE_DIR}/lib/network.sh"
source "${BASE_DIR}/lib/ssh.sh"


# ==============================================================================
# Usage and Argument Handling
# ==============================================================================

usage() {
    cat <<EOF
Usage:
  $0 <role> <mode>

Roles:
  awx
  ansible1
  ansible2
  ubuntu

Modes:
  --dry-run   Show what would be configured without changing the system
  --apply     Apply hostname, /etc/hosts, network, and SSH configuration

Examples:
  sudo $0 awx --dry-run
  sudo $0 awx --apply
  sudo $0 ansible1 --apply
  sudo $0 ansible2 --apply
  sudo $0 ubuntu --apply

Description:
  Bootstraps a Lab 7 Linux VM for its assigned role.

  This script configures the node identity, local host records, static network
  settings, and SSH service readiness for the selected role.

Important:
  Run --dry-run first.
  Use --apply only when the selected role matches the VM being configured.
  Windows 11 is not supported by this Bash script.
EOF
}


validate_role_argument() {
    local role="$1"

    case "$role" in
        awx|ansible1|ansible2|ubuntu)
            return 0
            ;;
        *)
            fail "Invalid role: ${role}"
            usage
            exit 2
            ;;
    esac
}


validate_mode_argument() {
    local mode="$1"

    case "$mode" in
        --dry-run|--apply)
            return 0
            ;;
        *)
            fail "Invalid mode: ${mode}"
            usage
            exit 2
            ;;
    esac
}


# ==============================================================================
# Dry Run
# ==============================================================================

dry_run_bootstrap() {
    local role="$1"
    local expected_fqdn
    local expected_ip

    expected_fqdn="$(get_host_fqdn_for_role "$role")"
    expected_ip="$(get_host_ip_for_role "$role")"

    step "Dry run: Lab 7 node bootstrap plan"

    info "No changes will be made in dry-run mode."
    info "Selected role: ${role}"
    info "Expected hostname: ${expected_fqdn}"
    info "Expected IP address: ${expected_ip}/${SUBNET_PREFIX}"
    info "Expected gateway: ${GATEWAY_IP}"
    info "Expected DNS servers: ${DNS_SERVERS}"

    step "Actions that would be performed"

    info "Would set the system hostname to: ${expected_fqdn}"
    info "Would write the Lab 7 managed /etc/hosts block"
    info "Would configure static IPv4 settings through NetworkManager"
    info "Would install the OpenSSH server if it is missing"
    info "Would enable and start the SSH service"
    info "Would validate hostname, host resolution, IP, gateway, DNS, and SSH"

    step "Current state preview"

    info "Current hostname:"
    hostname

    info "Current IPv4 addresses:"
    ip -4 -brief addr show || warn "Unable to show IPv4 addresses"

    info "Current default route:"
    ip route | grep '^default' || warn "No default route found"

    if command -v nmcli >/dev/null 2>&1; then
        info "Active NetworkManager connections:"
        nmcli con show --active
    else
        warn "nmcli is not available"
    fi

    pass "Dry run completed for role: ${role}"
}


# ==============================================================================
# Apply Workflow
# ==============================================================================

apply_bootstrap() {
    local role="$1"
    local failed=0

    step "Starting Lab 7 node bootstrap"

    info "Selected role: ${role}"
    info "Expected hostname: $(get_host_fqdn_for_role "$role")"
    info "Expected IP: $(get_host_ip_for_role "$role")/${SUBNET_PREFIX}"
    info "Expected gateway: ${GATEWAY_IP}"

    require_root

    step "Checking required commands"

    require_command hostname
    require_command hostnamectl
    require_command getent
    require_command ip
    require_command ping
    require_command systemctl
    require_command nmcli

    step "Applying host identity"

    set_hostname_for_role "$role" || failed=1
    write_lab_hosts_block || failed=1
    show_lab_hosts_block || failed=1
    validate_hostname_for_role "$role" || failed=1
    validate_hosts_resolution || failed=1

    step "Applying network configuration"

    configure_network_for_role "$role" || failed=1
    validate_network_for_role "$role" || failed=1

    step "Applying SSH service readiness"

    configure_ssh_for_activity1 || failed=1
    validate_ssh_service || failed=1

    step "Final Lab 7 bootstrap summary"

    if [[ "$failed" -eq 0 ]]; then
        pass "Lab 7 bootstrap completed successfully for role: ${role}"
        return 0
    else
        fail "Lab 7 bootstrap completed with failures for role: ${role}"
        return 1
    fi
}


# ==============================================================================
# Main
# ==============================================================================

main() {
    local role="${1:-}"
    local mode="${2:-}"

    if [[ -z "$role" || -z "$mode" ]]; then
        usage
        exit 2
    fi

    validate_role_argument "$role"
    validate_mode_argument "$mode"

    case "$mode" in
        --dry-run)
            dry_run_bootstrap "$role"
            ;;
        --apply)
            apply_bootstrap "$role"
            ;;
    esac
}

main "$@"
