#!/usr/bin/env bash
# ==============================================================================
# hosts.sh
# ==============================================================================
#
# Shared hostname and /etc/hosts helpers for NSSA320 Lab 7.
#
# Purpose:
#  - Map each Lab 7 Linux system role to its hostname, FQDN, and IP address.
#  - Set the local system hostname idempotently.
#  - Manage the Lab 7 /etc/hosts block idempotently.
#  - Validate local hostname and short-name resolution.
#
# Design:
#  - This file does not automatically run actions when sourced.
#  - Functions are called by scripts such as bootstrap-node.sh.
#  - Host data and managed block content come from config/lab7.conf.
#  - Output and safety helpers come from lib/common.sh.
#  - Windows is included in /etc/hosts but is not bootstrapped here.
#
# RICE Framework:
#  - Reproducibility: Host values come from one shared configuration file.
#  - Idempotency: /etc/hosts changes only when its managed block differs.
#  - Composability: Setup and verification scripts reuse these functions.
#  - Evolvability: Host definitions can be updated through lab7.conf.
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
# Version: 2.1
# Date: 2026-07-28
#
# Changes:
#  - Removed Ubuntu from the official Lab 7 role mappings and validation.
#  - Reused LAB7_HOSTS_CONTENT and managed-block markers from lab7.conf.
#  - Added comparison logic to avoid unnecessary /etc/hosts rewrites.
#  - Changed backup behavior so backups are created only before real changes.
#  - Preserved migration cleanup for earlier Lab 4 and Lab 7 blocks.
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
        *)
            die "Unknown role '${role}'. Valid roles: awx, ansible1, ansible2"
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
        *)
            die "Unknown role '${role}'. Valid roles: awx, ansible1, ansible2"
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
# /etc/hosts Block Inspection
# ==============================================================================

get_current_lab_hosts_block() {
    awk \
        -v start_marker="$LAB7_HOSTS_BLOCK_START" \
        -v end_marker="$LAB7_HOSTS_BLOCK_END" \
        '
        $0 == start_marker {
            inside_block = 1
        }

        inside_block {
            print
        }

        $0 == end_marker {
            inside_block = 0
            exit
        }
        ' /etc/hosts
}

lab_hosts_block_is_current() {
    local current_content

    current_content="$(get_current_lab_hosts_block)"

    [[ "$current_content" == "$LAB7_HOSTS_CONTENT" ]]
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

remove_hosts_block_from_file() {
    local file_path="$1"
    local start_marker="$2"
    local end_marker="$3"
    local temporary_file

    temporary_file="$(mktemp)" \
        || die "Failed to create a temporary hosts file"

    awk \
        -v start_marker="$start_marker" \
        -v end_marker="$end_marker" \
        '
        $0 == start_marker {
            inside_block = 1
            next
        }

        $0 == end_marker {
            inside_block = 0
            next
        }

        !inside_block {
            print
        }
        ' "$file_path" > "$temporary_file" \
        || {
            rm -f "$temporary_file"
            die "Failed to remove managed block from ${file_path}"
        }

    cat "$temporary_file" > "$file_path" \
        || {
            rm -f "$temporary_file"
            die "Failed to update ${file_path}"
        }

    rm -f "$temporary_file"
}

remove_managed_hosts_blocks() {
    info "Removing existing Lab 7 managed block if present"

    remove_hosts_block_from_file \
        "/etc/hosts" \
        "$LAB7_HOSTS_BLOCK_START" \
        "$LAB7_HOSTS_BLOCK_END"

    info "Removing earlier Lab 7 managed block if present"

    remove_hosts_block_from_file \
        "/etc/hosts" \
        "# BEGIN NSSA320 LAB7 HOSTS" \
        "# END NSSA320 LAB7 HOSTS"

    info "Removing old Lab 4 managed block if present"

    remove_hosts_block_from_file \
        "/etc/hosts" \
        "# BEGIN NSSA320 LAB4 HOSTS" \
        "# END NSSA320 LAB4 HOSTS"
}

write_lab_hosts_block() {
    step "Managing Lab 7 /etc/hosts block"

    if lab_hosts_block_is_current; then
        pass "Lab 7 /etc/hosts block is already current"
        return 0
    fi

    info "The Lab 7 managed block is missing or outdated"

    backup_hosts_file
    remove_managed_hosts_blocks

    info "Appending the current Lab 7 managed block"

    {
        printf '\n'
        printf '%s\n' "$LAB7_HOSTS_CONTENT"
    } >> /etc/hosts \
        || die "Failed to append the Lab 7 hosts block"

    pass "Lab 7 /etc/hosts block updated successfully"
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

    if grep -Fqx "$LAB7_HOSTS_BLOCK_START" /etc/hosts; then
        get_current_lab_hosts_block
        return 0
    fi

    warn "Lab 7 managed hosts block was not found in /etc/hosts"
    return 1
}
