#!/usr/bin/env bash
# ==============================================================================
# network.sh
# ==============================================================================
#
# Shared network configuration and validation helpers for NSSA320 Lab 7.
#
# Purpose:
#   - Map each Lab 7 Linux role to its static IP address
#   - Detect the active NetworkManager connection and device
#   - Apply static IPv4 settings
#   - Validate IP address, gateway, DNS, and gateway reachability
#   - Display current network state for troubleshooting
#
# Dependencies:
#   - config/lab7.conf
#   - lib/common.sh
#   - lib/hosts.sh
#
# Version:
#   2.1
#
# Changes:
#   - Prevented status output from contaminating command-substitution results.
#   - Moved nmcli command validation outside value-returning helper functions.
#   - Kept connection and device detection output clean and predictable.
#
# ==============================================================================


# ==============================================================================
# Source Guard
# ==============================================================================

if [[ -n "${LAB7_NETWORK_SH_LOADED:-}" ]]; then
    return 0
fi

LAB7_NETWORK_SH_LOADED="true"


# ==============================================================================
# Role Validation
# ==============================================================================

validate_network_role() {
    local role="$1"

    case "$role" in
        awx|ansible1|ansible2|ubuntu)
            return 0
            ;;
        *)
            die "Unknown network role '${role}'. Valid roles: awx, ansible1, ansible2, ubuntu"
            ;;
    esac
}


# ==============================================================================
# NetworkManager Detection Helpers
# ==============================================================================

detect_active_nm_connection() {
    local connection

    connection="$(
        nmcli -t -f NAME,DEVICE connection show --active |
            awk -F: '$2 != "" {print $1; exit}'
    )"

    if [[ -z "$connection" ]]; then
        die "No active NetworkManager connection found"
    fi

    printf '%s\n' "$connection"
}


detect_active_nm_device() {
    local device

    device="$(
        nmcli -t -f NAME,DEVICE connection show --active |
            awk -F: '$2 != "" {print $2; exit}'
    )"

    if [[ -z "$device" ]]; then
        die "No active NetworkManager device found"
    fi

    printf '%s\n' "$device"
}


# ==============================================================================
# Network State Display
# ==============================================================================

show_network_state() {
    step "Current network state"

    require_command hostname
    require_command ip
    require_command nmcli

    info "Hostname:"
    hostname

    info "IPv4 addresses:"
    ip -4 -brief address show ||
        warn "Unable to show IPv4 addresses"

    info "Routing table:"
    ip route ||
        warn "Unable to show routing table"

    info "Active NetworkManager connections:"
    nmcli connection show --active ||
        warn "Unable to show active NetworkManager connections"

    info "DNS configuration from NetworkManager:"
    nmcli device show |
        grep -E 'IP4.DNS|GENERAL.DEVICE' ||
        warn "Unable to show DNS configuration"
}


# ==============================================================================
# Static Network Configuration
# ==============================================================================

configure_network_for_role() {
    local role="$1"
    local expected_ip
    local connection
    local device

    validate_network_role "$role"

    require_command nmcli

    expected_ip="$(get_host_ip_for_role "$role")"
    connection="$(detect_active_nm_connection)"
    device="$(detect_active_nm_device)"

    step "Configuring static network settings"

    info "Role: ${role}"
    info "Connection: ${connection}"
    info "Device: ${device}"
    info "Expected IP: ${expected_ip}/${SUBNET_PREFIX}"
    info "Gateway: ${GATEWAY_IP}"
    info "DNS servers: ${DNS_SERVERS}"

    nmcli connection modify "$connection" \
        ipv4.addresses "${expected_ip}/${SUBNET_PREFIX}" ||
        die "Failed to set IPv4 address on ${connection}"

    nmcli connection modify "$connection" \
        ipv4.gateway "$GATEWAY_IP" ||
        die "Failed to set IPv4 gateway on ${connection}"

    nmcli connection modify "$connection" \
        ipv4.dns "$DNS_SERVERS" ||
        die "Failed to set IPv4 DNS servers on ${connection}"

    nmcli connection modify "$connection" \
        ipv4.method manual ||
        die "Failed to set IPv4 method to manual on ${connection}"

    nmcli connection modify "$connection" \
        connection.autoconnect yes ||
        die "Failed to enable autoconnect on ${connection}"

    pass "Static IPv4 settings applied to ${connection}"

    warn "Restarting the active connection may temporarily interrupt SSH access"
    info "Restarting NetworkManager connection: ${connection}"

    nmcli connection down "$connection" >/dev/null 2>&1 ||
        warn "Connection ${connection} was not cleanly brought down"

    nmcli connection up "$connection" ||
        die "Failed to bring connection ${connection} back up"

    pass "Network connection restarted successfully"
}


# ==============================================================================
# Network Validation
# ==============================================================================

validate_ip_for_role() {
    local role="$1"
    local expected_ip

    validate_network_role "$role"

    require_command ip

    expected_ip="$(get_host_ip_for_role "$role")"

    step "Validating IPv4 address"

    info "Expected IP: ${expected_ip}/${SUBNET_PREFIX}"

    if ip -4 address show |
        grep -Fq "${expected_ip}/${SUBNET_PREFIX}"; then

        pass "Expected IP address is configured: ${expected_ip}/${SUBNET_PREFIX}"
        return 0
    fi

    fail "Expected IP address not found: ${expected_ip}/${SUBNET_PREFIX}"
    info "Current IPv4 addresses:"
    ip -4 -brief address show
    return 1
}


validate_default_gateway() {
    require_command ip

    step "Validating default gateway"

    info "Expected default gateway: ${GATEWAY_IP}"

    if ip route |
        grep -Fq "default via ${GATEWAY_IP}"; then

        pass "Default gateway is configured: ${GATEWAY_IP}"
        return 0
    fi

    fail "Default gateway is not configured as expected"
    info "Current routing table:"
    ip route
    return 1
}


validate_gateway_ping() {
    local output_file="/tmp/lab7_gateway_ping.out"

    require_command ping

    step "Validating gateway reachability"

    info "Pinging gateway: ${GATEWAY_IP}"

    if ping -c 3 "$GATEWAY_IP" >"$output_file" 2>&1; then
        cat "$output_file"
        pass "Gateway is reachable: ${GATEWAY_IP}"
        return 0
    fi

    cat "$output_file"
    fail "Gateway is not reachable: ${GATEWAY_IP}"
    return 1
}


validate_dns_resolution() {
    local dns_test_host="${1:-github.com}"
    local output_file="/tmp/lab7_dns_test.out"

    require_command getent

    step "Validating external DNS resolution"

    info "Test hostname: ${dns_test_host}"

    if getent hosts "$dns_test_host" >"$output_file" 2>&1; then
        cat "$output_file"
        pass "External DNS resolution works for ${dns_test_host}"
        return 0
    fi

    cat "$output_file"
    fail "External DNS resolution failed for ${dns_test_host}"
    return 1
}


validate_network_for_role() {
    local role="$1"
    local failed=0

    validate_network_role "$role"

    step "Running full network validation for role: ${role}"

    validate_ip_for_role "$role" || failed=1
    validate_default_gateway || failed=1
    validate_gateway_ping || failed=1
    validate_dns_resolution "github.com" || failed=1

    if (( failed == 0 )); then
        pass "Network validation passed for role: ${role}"
        return 0
    fi

    fail "Network validation failed for role: ${role}"
    return 1
}
