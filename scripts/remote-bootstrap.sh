#!/usr/bin/env bash
# ==============================================================================
# remote-bootstrap.sh
# ==============================================================================
#
# Remote bootstrap controller for NSSA320 Lab 7.
#
# Purpose:
#  - Run from the AWX control node
#  - Reach ansible1 or ansible2 through SSH
#  - Bootstrap the selected managed node without copying the repository
#  - Set the hostname
#  - Manage the Lab 7 /etc/hosts block
#  - Apply static NetworkManager settings
#  - Ensure the OpenSSH server is enabled and running
#  - Validate the resulting managed-node configuration
#
# Design:
#  - Configuration remains on the AWX control node.
#  - A temporary Bash payload is streamed through SSH.
#  - No repository, script, archive, or temporary bootstrap directory is copied
#    to the managed node.
#  - The remote payload runs from memory through sudo bash.
#  - The remote user may be prompted for the sudo password.
#
# Supported Roles:
#  - ansible1
#  - ansible2
#
# RICE Framework:
#  - Reproducibility: Uses role and network data from config/lab7.conf.
#  - Idempotency: Changes are applied only when the current state differs.
#  - Composability: Uses the existing local role mapping from lib/hosts.sh.
#  - Evolvability: Can later be replaced by an Ansible playbook or AWX template.
#
# Author:
#  - Jared Husson
#
# ==============================================================================
# Version History
# ==============================================================================
#
# Version: 1.0
# Date: 2026-07-28
#
# Changes:
#  - Added controller-driven bootstrap for Lab 7 managed Linux nodes.
#  - Added remote dry-run and apply modes.
#  - Added SSH streaming without scp or repository copying.
#  - Added remote hostname, hosts-file, network, and SSH configuration.
#  - Added post-bootstrap validation.
#
# Notes:
#  - Run this script from the AWX control node.
#  - Run --dry-run before --apply.
#  - Windows 11 is not supported by this Bash script.
#  - The awx role is intentionally rejected because this script is for managed
#    nodes only.
#
# ==============================================================================

set -u


# ==============================================================================
# Path Setup
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"


# ==============================================================================
# Load Local Configuration and Libraries
# ==============================================================================

source "${BASE_DIR}/config/lab7.conf"
source "${BASE_DIR}/lib/common.sh"
source "${BASE_DIR}/lib/hosts.sh"


# ==============================================================================
# Defaults
# ==============================================================================

REMOTE_USER="${LAB_USER:-student}"
MODE=""
TARGET_ROLE=""
TARGET_ADDRESS=""


# ==============================================================================
# Usage
# ==============================================================================

usage() {
    cat <<EOF
Usage:
  $0 <role> <mode> [options]

Roles:
  ansible1
  ansible2

Modes:
  --dry-run   Inspect the remote node and show the intended configuration
  --apply     Apply the remote bootstrap configuration

Options:
  --user USER       Remote SSH user. Default: ${REMOTE_USER}
  --address HOST    Override the SSH destination address
  -h, --help        Show this help message

Examples:
  $0 ansible1 --dry-run
  $0 ansible1 --apply
  $0 ansible2 --dry-run
  $0 ansible2 --apply
  $0 ansible1 --apply --user student
  $0 ansible1 --apply --address 192.168.1.102

Description:
  Runs from the AWX control node and bootstraps a managed Linux node through
  SSH without copying the repository or leaving bootstrap files behind.

Important:
  Run --dry-run first.
  The remote user must be able to use sudo.
EOF
}


# ==============================================================================
# Argument Validation
# ==============================================================================

validate_role_argument() {
    local role="$1"

    case "$role" in
        ansible1|ansible2)
            return 0
            ;;
        awx)
            die "The awx role cannot be targeted by remote-bootstrap.sh."
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


parse_arguments() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    TARGET_ROLE="${1:-}"
    MODE="${2:-}"

    if [[ -z "$TARGET_ROLE" || -z "$MODE" ]]; then
        usage
        exit 2
    fi

    validate_role_argument "$TARGET_ROLE"
    validate_mode_argument "$MODE"

    shift 2

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --user)
                REMOTE_USER="${2:-}"
                shift 2
                ;;
            --address)
                TARGET_ADDRESS="${2:-}"
                shift 2
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done

    if [[ -z "$REMOTE_USER" ]]; then
        die "Remote SSH user cannot be empty."
    fi

    if [[ -z "$TARGET_ADDRESS" ]]; then
        TARGET_ADDRESS="$(get_host_ip_for_role "$TARGET_ROLE")"
    fi
}


# ==============================================================================
# Local Preflight
# ==============================================================================

run_local_preflight() {
    step "Checking AWX controller requirements"

    require_command ssh
    require_command base64
    require_command ping

    if [[ ! -f "${BASE_DIR}/config/lab7.conf" ]]; then
        die "Missing configuration file: ${BASE_DIR}/config/lab7.conf"
    fi

    pass "Required controller commands and configuration are available"
}


check_target_reachability() {
    step "Checking managed-node reachability"

    info "Target role: ${TARGET_ROLE}"
    info "Target address: ${TARGET_ADDRESS}"
    info "Remote user: ${REMOTE_USER}"

    if ping -c 2 -W 2 "$TARGET_ADDRESS" >/dev/null 2>&1; then
        pass "Target responds to ping: ${TARGET_ADDRESS}"
    else
        warn "Target did not answer ping: ${TARGET_ADDRESS}"
        warn "SSH may still work if ICMP is blocked."
    fi

    if ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=5 \
        "${REMOTE_USER}@${TARGET_ADDRESS}" \
        "true" >/dev/null 2>&1; then

        pass "Passwordless SSH connection succeeded"
    else
        warn "Passwordless SSH test did not succeed."
        info "The interactive SSH connection may request a password."
    fi
}


# ==============================================================================
# Remote Payload
# ==============================================================================

build_remote_payload() {
    local expected_short
    local expected_fqdn
    local expected_ip

    expected_short="$(get_host_short_for_role "$TARGET_ROLE")"
    expected_fqdn="$(get_host_fqdn_for_role "$TARGET_ROLE")"
    expected_ip="$(get_host_ip_for_role "$TARGET_ROLE")"

    printf 'REMOTE_MODE=%q\n' "$MODE"
    printf 'REMOTE_ROLE=%q\n' "$TARGET_ROLE"
    printf 'EXPECTED_SHORT=%q\n' "$expected_short"
    printf 'EXPECTED_FQDN=%q\n' "$expected_fqdn"
    printf 'EXPECTED_IP=%q\n' "$expected_ip"
    printf 'SUBNET_PREFIX=%q\n' "$SUBNET_PREFIX"
    printf 'GATEWAY_IP=%q\n' "$GATEWAY_IP"
    printf 'DNS_SERVERS=%q\n' "$DNS_SERVERS"
    printf 'LAB7_HOSTS_BLOCK_START=%q\n' "$LAB7_HOSTS_BLOCK_START"
    printf 'LAB7_HOSTS_BLOCK_END=%q\n' "$LAB7_HOSTS_BLOCK_END"
    printf 'LAB7_HOSTS_CONTENT=%q\n' "$LAB7_HOSTS_CONTENT"

    cat <<'REMOTE_PAYLOAD'
#!/usr/bin/env bash

set -u


# ==============================================================================
# Remote Output Helpers
# ==============================================================================

remote_step() {
    printf '\n[STEP] %s\n' "$*"
}

remote_info() {
    printf '[INFO] %s\n' "$*"
}

remote_pass() {
    printf '[PASS] %s\n' "$*"
}

remote_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

remote_fail() {
    printf '[FAIL] %s\n' "$*" >&2
}

remote_die() {
    remote_fail "$*"
    exit 1
}


# ==============================================================================
# Remote Validation Helpers
# ==============================================================================

require_remote_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        remote_die "Remote bootstrap must run with root privileges."
    fi
}


require_remote_command() {
    local command_name="$1"

    if command -v "$command_name" >/dev/null 2>&1; then
        remote_pass "Required command found: ${command_name}"
    else
        remote_die "Required command not found: ${command_name}"
    fi
}


get_active_connection() {
    local connection

    connection="$(
        nmcli -t -f NAME,DEVICE connection show --active |
            awk -F: '$2 != "" {print $1; exit}'
    )"

    if [[ -z "$connection" ]]; then
        remote_die "No active NetworkManager connection was found."
    fi

    printf '%s\n' "$connection"
}


get_active_device() {
    local device

    device="$(
        nmcli -t -f DEVICE,STATE device status |
            awk -F: '$2 == "connected" {print $1; exit}'
    )"

    if [[ -z "$device" ]]; then
        remote_die "No connected NetworkManager device was found."
    fi

    printf '%s\n' "$device"
}


# ==============================================================================
# Remote Dry Run
# ==============================================================================

run_remote_dry_run() {
    remote_step "Remote Lab 7 bootstrap dry run"

    remote_info "Selected role: ${REMOTE_ROLE}"
    remote_info "Expected short hostname: ${EXPECTED_SHORT}"
    remote_info "Expected FQDN: ${EXPECTED_FQDN}"
    remote_info "Expected IP: ${EXPECTED_IP}/${SUBNET_PREFIX}"
    remote_info "Expected gateway: ${GATEWAY_IP}"
    remote_info "Expected DNS servers: ${DNS_SERVERS}"

    remote_step "Actions that would be performed"

    remote_info "Would set the hostname to ${EXPECTED_FQDN}"
    remote_info "Would update the managed Lab 7 /etc/hosts block"
    remote_info "Would configure static IPv4 settings through NetworkManager"
    remote_info "Would ensure the OpenSSH server is installed and running"
    remote_info "Would validate hostname, IP address, route, resolution, and SSH"

    remote_step "Current remote state"

    remote_info "Current hostname:"
    hostname

    remote_info "Current IPv4 addresses:"
    ip -4 -brief address show || true

    remote_info "Current default route:"
    ip route | grep '^default' || remote_warn "No default route found"

    if command -v nmcli >/dev/null 2>&1; then
        remote_info "Active NetworkManager connections:"
        nmcli connection show --active
    else
        remote_warn "nmcli is not currently available"
    fi

    remote_info "Current /etc/hosts:"
    cat /etc/hosts

    remote_pass "Remote dry run completed for role: ${REMOTE_ROLE}"
}


# ==============================================================================
# Hostname Configuration
# ==============================================================================

configure_remote_hostname() {
    local current_hostname

    remote_step "Configuring remote hostname"

    current_hostname="$(hostnamectl --static 2>/dev/null || hostname)"

    if [[ "$current_hostname" == "$EXPECTED_FQDN" ]]; then
        remote_pass "Hostname is already correct: ${EXPECTED_FQDN}"
        return 0
    fi

    remote_info "Changing hostname from ${current_hostname} to ${EXPECTED_FQDN}"

    hostnamectl set-hostname "$EXPECTED_FQDN" \
        || remote_die "Failed to set the remote hostname"

    remote_pass "Hostname configured: ${EXPECTED_FQDN}"
}


# ==============================================================================
# /etc/hosts Configuration
# ==============================================================================

remove_managed_block() {
    local input_file="$1"
    local output_file="$2"
    local start_marker="$3"
    local end_marker="$4"

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
        ' "$input_file" > "$output_file"
}


current_hosts_block() {
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
            exit
        }
        ' /etc/hosts
}


configure_remote_hosts_file() {
    local current_block
    local clean_file
    local updated_file

    remote_step "Managing remote /etc/hosts"

    current_block="$(current_hosts_block)"

    if [[ "$current_block" == "$LAB7_HOSTS_CONTENT" ]]; then
        remote_pass "Lab 7 /etc/hosts block is already current"
        return 0
    fi

    clean_file="$(mktemp)" \
        || remote_die "Failed to create temporary hosts file"

    updated_file="$(mktemp)" \
        || {
            rm -f "$clean_file"
            remote_die "Failed to create updated hosts file"
        }

    cp /etc/hosts "/etc/hosts.lab7.bak.$(date +%Y%m%d-%H%M%S)" \
        || remote_warn "Unable to create an /etc/hosts backup"

    remove_managed_block \
        /etc/hosts \
        "$clean_file" \
        "$LAB7_HOSTS_BLOCK_START" \
        "$LAB7_HOSTS_BLOCK_END"

    remove_managed_block \
        "$clean_file" \
        "$updated_file" \
        "# BEGIN NSSA320 LAB7 HOSTS" \
        "# END NSSA320 LAB7 HOSTS"

    remove_managed_block \
        "$updated_file" \
        "$clean_file" \
        "# BEGIN NSSA320 LAB4 HOSTS" \
        "# END NSSA320 LAB4 HOSTS"

    {
        cat "$clean_file"
        printf '\n%s\n' "$LAB7_HOSTS_CONTENT"
    } > "$updated_file" \
        || {
            rm -f "$clean_file" "$updated_file"
            remote_die "Failed to create updated /etc/hosts content"
        }

    cat "$updated_file" > /etc/hosts \
        || {
            rm -f "$clean_file" "$updated_file"
            remote_die "Failed to update /etc/hosts"
        }

    rm -f "$clean_file" "$updated_file"

    remote_pass "Lab 7 /etc/hosts block updated"
}


# ==============================================================================
# Network Configuration
# ==============================================================================

configure_remote_network() {
    local connection
    local device
    local expected_address
    local current_method
    local current_address
    local current_gateway
    local current_dns
    local normalized_current_dns
    local normalized_expected_dns
    local changed=0

    remote_step "Configuring remote network"

    connection="$(get_active_connection)"
    device="$(get_active_device)"
    expected_address="${EXPECTED_IP}/${SUBNET_PREFIX}"

    remote_info "NetworkManager connection: ${connection}"
    remote_info "Network device: ${device}"

    current_method="$(
        nmcli -g ipv4.method connection show "$connection" 2>/dev/null
    )"

    current_address="$(
        nmcli -g ipv4.addresses connection show "$connection" 2>/dev/null |
            cut -d, -f1
    )"

    current_gateway="$(
        nmcli -g ipv4.gateway connection show "$connection" 2>/dev/null
    )"

    current_dns="$(
        nmcli -g ipv4.dns connection show "$connection" 2>/dev/null |
            tr ',' ' '
    )"

    normalized_current_dns="$(xargs <<< "$current_dns")"
    normalized_expected_dns="$(xargs <<< "$DNS_SERVERS")"

    if [[ "$current_method" != "manual" ]]; then
        remote_info "IPv4 method requires change: ${current_method} -> manual"
        changed=1
    fi

    if [[ "$current_address" != "$expected_address" ]]; then
        remote_info "IPv4 address requires change: ${current_address:-unset} -> ${expected_address}"
        changed=1
    fi

    if [[ "$current_gateway" != "$GATEWAY_IP" ]]; then
        remote_info "Gateway requires change: ${current_gateway:-unset} -> ${GATEWAY_IP}"
        changed=1
    fi

    if [[ "$normalized_current_dns" != "$normalized_expected_dns" ]]; then
        remote_info "DNS requires change: ${normalized_current_dns:-unset} -> ${normalized_expected_dns}"
        changed=1
    fi

    if [[ "$changed" -eq 0 ]]; then
        remote_pass "Static network configuration is already current"
        return 0
    fi

    remote_warn "The active SSH connection may briefly disconnect while NetworkManager applies changes."

    nmcli connection modify "$connection" \
        ipv4.method manual \
        ipv4.addresses "$expected_address" \
        ipv4.gateway "$GATEWAY_IP" \
        ipv4.dns "$DNS_SERVERS" \
        ipv4.ignore-auto-dns yes \
        connection.autoconnect yes \
        || remote_die "Failed to modify NetworkManager connection"

    nmcli connection up "$connection" \
        || remote_die "Failed to activate NetworkManager connection"

    remote_pass "Static network configuration applied"
}


# ==============================================================================
# SSH Service Configuration
# ==============================================================================

configure_remote_ssh() {
    remote_step "Ensuring OpenSSH service readiness"

    if ! rpm -q openssh-server >/dev/null 2>&1; then
        remote_info "Installing openssh-server"

        if command -v dnf >/dev/null 2>&1; then
            dnf install -y openssh-server \
                || remote_die "Failed to install openssh-server"
        elif command -v yum >/dev/null 2>&1; then
            yum install -y openssh-server \
                || remote_die "Failed to install openssh-server"
        else
            remote_die "No supported package manager found"
        fi
    else
        remote_pass "openssh-server is already installed"
    fi

    systemctl enable --now sshd \
        || remote_die "Failed to enable and start sshd"

    if systemctl is-active --quiet sshd; then
        remote_pass "sshd is active"
    else
        remote_die "sshd is not active"
    fi
}


# ==============================================================================
# Final Validation
# ==============================================================================

validate_remote_bootstrap() {
    local failed=0
    local actual_hostname

    remote_step "Validating remote Lab 7 bootstrap"

    actual_hostname="$(hostnamectl --static 2>/dev/null || hostname)"

    if [[ "$actual_hostname" == "$EXPECTED_FQDN" ]]; then
        remote_pass "Hostname validation passed: ${actual_hostname}"
    else
        remote_fail "Hostname validation failed: ${actual_hostname}"
        failed=1
    fi

    if ip -4 address show | grep -q "${EXPECTED_IP}/${SUBNET_PREFIX}"; then
        remote_pass "IPv4 validation passed: ${EXPECTED_IP}/${SUBNET_PREFIX}"
    else
        remote_fail "Expected IPv4 address was not found"
        failed=1
    fi

    if ip route | grep -qE "^default .*via ${GATEWAY_IP}([[:space:]]|$)"; then
        remote_pass "Default gateway validation passed: ${GATEWAY_IP}"
    else
        remote_fail "Expected default gateway was not found"
        failed=1
    fi

    if getent hosts "$EXPECTED_SHORT" >/dev/null 2>&1; then
        remote_pass "Short hostname resolves: ${EXPECTED_SHORT}"
    else
        remote_fail "Short hostname does not resolve: ${EXPECTED_SHORT}"
        failed=1
    fi

    if getent hosts "$EXPECTED_FQDN" >/dev/null 2>&1; then
        remote_pass "FQDN resolves: ${EXPECTED_FQDN}"
    else
        remote_fail "FQDN does not resolve: ${EXPECTED_FQDN}"
        failed=1
    fi

    if systemctl is-active --quiet sshd; then
        remote_pass "SSH service validation passed"
    else
        remote_fail "SSH service validation failed"
        failed=1
    fi

    if [[ "$failed" -eq 0 ]]; then
        remote_pass "Remote bootstrap completed successfully for role: ${REMOTE_ROLE}"
        return 0
    fi

    remote_fail "Remote bootstrap completed with validation failures"
    return 1
}


# ==============================================================================
# Remote Main
# ==============================================================================

remote_main() {
    case "$REMOTE_MODE" in
        --dry-run)
            run_remote_dry_run
            ;;
        --apply)
            require_remote_root

            remote_step "Checking remote requirements"

            require_remote_command hostname
            require_remote_command hostnamectl
            require_remote_command getent
            require_remote_command ip
            require_remote_command awk
            require_remote_command grep
            require_remote_command systemctl
            require_remote_command nmcli
            require_remote_command mktemp

            configure_remote_hostname
            configure_remote_hosts_file
            configure_remote_network
            configure_remote_ssh
            validate_remote_bootstrap
            ;;
        *)
            remote_die "Unsupported remote mode: ${REMOTE_MODE}"
            ;;
    esac
}

remote_main
REMOTE_PAYLOAD
}


# ==============================================================================
# Remote Execution
# ==============================================================================

run_remote_payload() {
    local payload
    local encoded_payload
    local ssh_target

    step "Preparing remote bootstrap payload"

    payload="$(build_remote_payload)" \
        || die "Failed to build remote bootstrap payload"

    encoded_payload="$(
        printf '%s' "$payload" | base64 | tr -d '\n'
    )" || die "Failed to encode remote bootstrap payload"

    ssh_target="${REMOTE_USER}@${TARGET_ADDRESS}"

    info "SSH destination: ${ssh_target}"
    info "Mode: ${MODE}"
    info "No repository or bootstrap file will be copied."

    step "Executing bootstrap through SSH"

    ssh -tt "$ssh_target" \
        "printf '%s' '${encoded_payload}' | base64 -d | sudo bash -s"

    local ssh_status=$?

    if [[ "$ssh_status" -ne 0 ]]; then
        fail "Remote bootstrap command failed with status ${ssh_status}"
        return "$ssh_status"
    fi

    pass "Remote bootstrap command completed for ${TARGET_ROLE}"
}


# ==============================================================================
# Main
# ==============================================================================

main() {
    parse_arguments "$@"

    step "Lab 7 controller-driven remote bootstrap"

    info "Controller repository: ${BASE_DIR}"
    info "Managed-node role: ${TARGET_ROLE}"
    info "Managed-node address: ${TARGET_ADDRESS}"
    info "Remote user: ${REMOTE_USER}"
    info "Execution mode: ${MODE}"

    run_local_preflight
    check_target_reachability
    run_remote_payload
}

main "$@"
