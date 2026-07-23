#!/usr/bin/env bash
# ==============================================================================
# hosts.sh
# ==============================================================================
#
# Shared hostname and /etc/hosts helpers for NSSA320 Lab 7.
#
# Purpose:
#  - Map a Lab 7 Linux role to the correct hostname, FQDN, and IP address
#  - Set the system hostname idempotently
#  - Manage the Lab 7 /etc/hosts block idempotently
#  - Validate local hostname and short-name resolution
#
# Design:
#  - This file does not automatically run actions when sourced.
#  - Functions are called by scripts such as bootstrap-node.sh.
#  - Host data is read from config/lab7.conf.
#  - Output is handled through lib/common.sh.
#  - Windows is included in /etc/hosts, but is not bootstrapped by this library.
#
# RICE Framework:
#  - Reproducibility: Hostname and /etc/hosts values come from one config file.
#  - Idempotency: Existing managed /etc/hosts blocks are replaced, not duplicated.
#  - Composability: Bootstrap and verification scripts can reuse these functions.
#  - Evolvability: New hosts can be added by updating the configuration and mapping.
#
# Dependencies:
#  - config/lab7.conf must be sourced before this file is used.
#  - lib/common.sh must be sourced before this file is used.
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
#  - Refactored the library for the Lab 7 AWX environment.
#  - Replaced the control role and variables with the awx role and AWX variables.
#  - Updated the source guard and managed /etc/hosts block markers for Lab 7.
#  - Added the Windows 11 host to the managed hosts block and validation.
#  - Added removal of the old Lab 4 block during migration.
#
# Version: 1.0
# Date: 2026-06-09
#
# Changes:
#  - Added role-to-hostname mapping helpers.
#  - Added idempotent hostname setter.
#  - Added idempotent /etc/hosts managed block writer.
#  - Added hostname and /etc/hosts validation helpers.
#
# ==============================================================================


# ==============================================================================
# Source Guard
# ==============================================================================

if [[ -n "${LAB7_HOSTS_SH_LOADED:-}" ]]; then
    return 0
fi

LAB7_HOSTS_SH_LOADED="true"


# ==============================================================================
# Role Mapping Helpers
# ==============================================================================

get_host_short_for_role() {
    local role="$1"

    case "$role" in
        awx)
            printf '%s\n' "$AWX_HOST"
            ;;
        ansible1)
            printf '%s\n' "$ANSIBLE1_HOST"
            ;;
        ansible2)
            printf '%s\n' "$ANSIBLE2_HOST"
            ;;
        ubuntu)
            printf '%s\n' "$UBUNTU_HOST"
            ;;
        *)
            die "Unknown role '${role}'. Valid roles: awx, ansible1, ansible2, ubuntu"
            ;;
    esac
}

get_host_ip_for_role() {
    local role="$1"

    case "$role" in
        awx)
            printf '%s\n' "$AWX_IP"
            ;;
        ansible1)
            printf '%s\n' "$ANSIBLE1_IP"
            ;;
        ansible2)
            printf '%s\n' "$ANSIBLE2_IP"
            ;;
        ubuntu)
            printf '%s\n' "$UBUNTU_IP"
            ;;
        *)
            die "Unknown role '${role}'. Valid roles: awx, ansible1, ansible2, ubuntu"
            ;;
    esac
}

get_host_fqdn_for_role() {
    local role="$1"
    local short_name

    short_name="$(get_host_short_for_role "$role")"
    printf '%s.%s\n' "$short_name" "$DOMAIN"
}


# ==============================================================================
# Hostname Management
# ==============================================================================

set_hostname_for_role() {
    local role="$1"
    local expected_fqdn
    local current_hostname

    expected_fqdn="$(get_host_fqdn_for_role "$role")"
    current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"

    step "Configuring system hostname"

    info "Role: ${role}"
    info "Expected hostname: ${expected_fqdn}"
    info "Current hostname: ${current_hostname}"

    if [[ "$current_hostname" == "$expected_fqdn" ]]; then
        pass "Hostname already set correctly: ${expected_fqdn}"
        return 0
    fi

    info "Setting hostname to ${expected_fqdn}"

    hostnamectl set-hostname "$expected_fqdn" \
        || die "Failed to set hostname to ${expected_fqdn}"

    current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"

    if [[ "$current_hostname" == "$expected_fqdn" ]]; then
        pass "Hostname successfully set to ${expected_fqdn}"
        return 0
    fi

    die "Hostname validation failed. Expected ${expected_fqdn}, found ${current_hostname}"
}

validate_hostname_for_role() {
    local role="$1"
    local expected_fqdn
    local current_hostname

    expected_fqdn="$(get_host_fqdn_for_role "$role")"
    current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"

    step "Validating system hostname"

    info "Expected hostname: ${expected_fqdn}"
    info "Current hostname: ${current_hostname}"

    if [[ "$current_hostname" == "$expected_fqdn" ]]; then
        pass "Hostname validation passed"
        return 0
    fi

    fail "Hostname validation failed"
    return 1
}


# ==============================================================================
# /etc/hosts Management
# ==============================================================================

backup_hosts_file() {
    local backup_file

    backup_file="/etc/hosts.bak.$(date +%Y%m%d-%H%M%S)"

    info "Backing up /etc/hosts to ${backup_file}"

    cp /etc/hosts "$backup_file" \
        || die "Failed to back up /etc/hosts"

    pass "Backup created: ${backup_file}"
}

remove_managed_hosts_blocks() {
    info "Removing existing Lab 7 managed block if present"

    sed -i \
        '/# BEGIN NSSA320 LAB7 HOSTS/,/# END NSSA320 LAB7 HOSTS/d' \
        /etc/hosts \
        || die "Failed to remove the existing Lab 7 hosts block"

    info "Removing old Lab 4 managed block if present"

    sed -i \
        '/# BEGIN NSSA320 LAB4 HOSTS/,/# END NSSA320 LAB4 HOSTS/d' \
        /etc/hosts \
        || die "Failed to remove the old Lab 4 hosts block"
}

write_lab_hosts_block() {
    step "Writing Lab 7 managed block to /etc/hosts"

    backup_hosts_file
    remove_managed_hosts_blocks

    info "Appending refreshed Lab 7 hosts block"

    cat >> /etc/hosts <<EOF

# BEGIN NSSA320 LAB7 HOSTS
# Managed by the Lab 7 bootstrap scripts.
# Do not manually edit inside this block unless config/lab7.conf is also updated.
${AWX_IP}      ${AWX_FQDN}       ${AWX_HOST}
${ANSIBLE1_IP} ${ANSIBLE1_FQDN}  ${ANSIBLE1_HOST}
${ANSIBLE2_IP} ${ANSIBLE2_FQDN}  ${ANSIBLE2_HOST}
${UBUNTU_IP}   ${UBUNTU_FQDN}    ${UBUNTU_HOST}
${WIN11_IP}    ${WIN11_FQDN}     ${WIN11_HOST}
${GATEWAY_IP}  ${GATEWAY_FQDN}   ${GATEWAY_HOST}
# END NSSA320 LAB7 HOSTS
EOF

    pass "Lab 7 /etc/hosts block written"
}


# ==============================================================================
# Host Resolution Validation
# ==============================================================================

validate_hosts_resolution() {
    local failed=0
    local host
    local hosts_to_check=(
        "$AWX_HOST"
        "$ANSIBLE1_HOST"
        "$ANSIBLE2_HOST"
        "$UBUNTU_HOST"
        "$WIN11_HOST"
        "$GATEWAY_HOST"
    )

    step "Validating local host resolution"

    for host in "${hosts_to_check[@]}"; do
        info "Resolving ${host}"

        if getent hosts "$host" >/dev/null 2>&1; then
            pass "Resolved ${host}: $(getent hosts "$host" | head -n 1)"
        else
            fail "Could not resolve ${host}"
            failed=1
        fi
    done

    if (( failed == 0 )); then
        pass "All Lab 7 short hostnames resolved successfully"
        return 0
    fi

    fail "One or more Lab 7 hostnames failed to resolve"
    return 1
}


# ==============================================================================
# Managed Block Display
# ==============================================================================

show_lab_hosts_block() {
    step "Displaying Lab 7 /etc/hosts managed block"

    if grep -q '# BEGIN NSSA320 LAB7 HOSTS' /etc/hosts; then
        sed -n \
            '/# BEGIN NSSA320 LAB7 HOSTS/,/# END NSSA320 LAB7 HOSTS/p' \
            /etc/hosts

        return 0
    fi

    warn "Lab 7 managed hosts block was not found in /etc/hosts"
    return 1
}
