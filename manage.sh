#!/bin/bash

# GRE Tunnel Management Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/gre-tunnel.conf"
BACKUP_DIR="/var/backups/grex"
REPO_OWNER="AlirezaSayyari"
REPO_NAME="GREX"
REPO_BRANCH="main"
VERSION_FILE="$SCRIPT_DIR/VERSION"
UPDATE_CACHE_FILE="/tmp/grex-latest-version"
UPDATE_CACHE_TTL=3600

run_as_root() {
    if [ "$EUID" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "This command must run as root or have sudo installed." >&2
            exit 1
        fi
        sudo "$@"
    else
        "$@"
    fi
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

dns_enabled() {
    [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]]
}

show_gre_tunnel_failure() {
    echo "gre-tunnel service failed to start."
    echo
    echo "=== gre-tunnel status ==="
    run_as_root systemctl status gre-tunnel --no-pager -l 2>/dev/null || true
    echo
    echo "=== gre-tunnel logs ==="
    if command -v journalctl >/dev/null 2>&1; then
        run_as_root journalctl -u gre-tunnel -n 100 --no-pager 2>/dev/null || true
    else
        echo "journalctl is not available"
    fi
}

start_dnsmasq_if_enabled() {
    dns_enabled || return 0

    if has_systemd; then
        if systemctl list-unit-files | grep -q '^dnsmasq'; then
            run_as_root systemctl enable --now dnsmasq
        fi
    elif command -v dnsmasq >/dev/null 2>&1; then
        if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -x dnsmasq >/dev/null 2>&1; then
            run_as_root dnsmasq --conf-file=/etc/dnsmasq.d/tunnel.conf --pid-file=/run/grex-dnsmasq.pid
        fi
    else
        echo "dnsmasq is enabled in config but the dnsmasq command was not found."
    fi
}

stop_dnsmasq_if_running() {
    if has_systemd; then
        run_as_root systemctl stop dnsmasq 2>/dev/null || true
    elif [ -f /run/grex-dnsmasq.pid ]; then
        run_as_root kill "$(cat /run/grex-dnsmasq.pid)" 2>/dev/null || true
        run_as_root rm -f /run/grex-dnsmasq.pid
    fi
}

usage() {
    echo "Usage: $0 {help|version|check-upgrade|upgrade|backup|restore|configure|edit|activate|deactivate|enable|disable|start|stop|status|logs|health|check}"
    exit "${1:-1}"
}

secure_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        run_as_root chown root:root "$CONFIG_FILE" 2>/dev/null || true
        run_as_root chmod 600 "$CONFIG_FILE"
    fi
}

backup_config() {
    local reason=${1:-manual}
    local timestamp
    local backup_file

    if [ ! -f "$CONFIG_FILE" ]; then
        echo "No $CONFIG_FILE found; nothing to back up."
        return 0
    fi

    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_file="$BACKUP_DIR/gre-tunnel.conf.$timestamp.$reason.bak"
    run_as_root mkdir -p "$BACKUP_DIR"
    run_as_root cp -p "$CONFIG_FILE" "$backup_file"
    run_as_root chmod 600 "$backup_file"
    echo "Backup created: $backup_file"
}

latest_config_backup() {
    ls -1t "$BACKUP_DIR"/gre-tunnel.conf.*.bak 2>/dev/null | head -n 1
}

restore_latest_config_backup() {
    local backup_file
    local answer

    backup_file=$(latest_config_backup)
    if [ -z "$backup_file" ]; then
        echo "No GREX config backup was found in $BACKUP_DIR."
        return 1
    fi

    echo "Latest backup: $backup_file"
    read -r -p "Restore this backup to $CONFIG_FILE? (yes/no) [no]: " answer
    if ! [[ "${answer:-no}" =~ ^(yes|y|Y)$ ]]; then
        echo "Restore cancelled."
        return 0
    fi

    backup_config "pre-restore"
    run_as_root cp "$backup_file" "$CONFIG_FILE"
    secure_config_file
    echo "Configuration restored from $backup_file."
    echo "Use 'sudo grex activate' or the menu apply option to apply it."
}

list_config_backups() {
    if ! ls "$BACKUP_DIR"/gre-tunnel.conf.*.bak >/dev/null 2>&1; then
        echo "No GREX config backups found in $BACKUP_DIR."
        return 0
    fi

    ls -1t "$BACKUP_DIR"/gre-tunnel.conf.*.bak
}

installed_version() {
    if [ -f "$VERSION_FILE" ]; then
        tr -d '[:space:]' < "$VERSION_FILE"
    else
        printf "unknown"
    fi
}

normalize_version() {
    local version=$1
    version=${version#v}
    version=${version#V}
    printf "%s" "$version"
}

version_gt() {
    local left
    local right

    left=$(normalize_version "$1")
    right=$(normalize_version "$2")

    if command -v sort >/dev/null 2>&1; then
        [ "$(printf '%s\n%s\n' "$right" "$left" | sort -V | tail -n 1)" = "$left" ] && [ "$left" != "$right" ]
    else
        [ "$1" != "$2" ]
    fi
}

fetch_latest_version() {
    local api_url
    local response
    local latest

    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi

    api_url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    response=$(curl -fsSL --connect-timeout 3 --max-time 8 "$api_url" 2>/dev/null || true)
    latest=$(printf "%s" "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

    if [ -z "$latest" ]; then
        api_url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/tags"
        response=$(curl -fsSL --connect-timeout 3 --max-time 8 "$api_url" 2>/dev/null || true)
        latest=$(printf "%s" "$response" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)
    fi

    [ -n "$latest" ] || return 1
    printf "%s" "$latest"
}

latest_version_cached() {
    local now
    local cache_mtime
    local latest

    now=$(date +%s)
    if [ -f "$UPDATE_CACHE_FILE" ]; then
        cache_mtime=$(stat -c %Y "$UPDATE_CACHE_FILE" 2>/dev/null || echo 0)
        if [ $((now - cache_mtime)) -lt "$UPDATE_CACHE_TTL" ]; then
            tr -d '[:space:]' < "$UPDATE_CACHE_FILE"
            return 0
        fi
    fi

    latest=$(fetch_latest_version || true)
    [ -n "$latest" ] || return 1
    printf "%s" "$latest" > "$UPDATE_CACHE_FILE" 2>/dev/null || true
    printf "%s" "$latest"
}

version_summary() {
    local current
    local latest

    current=$(installed_version)
    latest=$(latest_version_cached || true)

    echo "Installed version: $current"
    if [ -n "$latest" ]; then
        echo "Latest version:    $latest"
        if [ "$current" != "unknown" ] && version_gt "$latest" "$current"; then
            echo "Update status:     update available"
        else
            echo "Update status:     up to date"
        fi
    else
        echo "Latest version:    unavailable"
        echo "Update status:     could not check GitHub"
    fi
}

upgrade_grex() {
    local current
    local latest
    local source_url
    local tmp_dir
    local source_dir
    local answer

    if ! command -v curl >/dev/null 2>&1; then
        echo "curl is required for upgrade."
        return 1
    fi

    if ! command -v tar >/dev/null 2>&1; then
        echo "tar is required for upgrade."
        return 1
    fi

    current=$(installed_version)
    latest=$(fetch_latest_version || true)
    if [ -z "$latest" ]; then
        echo "Could not find a GitHub release/tag. Falling back to branch '$REPO_BRANCH'."
        latest="$REPO_BRANCH"
        source_url="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/heads/$REPO_BRANCH.tar.gz"
    else
        source_url="https://github.com/$REPO_OWNER/$REPO_NAME/archive/refs/tags/$latest.tar.gz"
    fi

    echo "Installed version: $current"
    echo "Target version:    $latest"

    if [ "$current" != "unknown" ] && [ "$latest" != "$REPO_BRANCH" ] && ! version_gt "$latest" "$current"; then
        read -r -p "No newer version detected. Reinstall target anyway? (yes/no) [no]: " answer
        if ! [[ "${answer:-no}" =~ ^(yes|y|Y)$ ]]; then
            echo "Upgrade cancelled."
            return 0
        fi
    else
        read -r -p "Upgrade GREX now? (yes/no) [yes]: " answer
        if ! [[ "${answer:-yes}" =~ ^(yes|y|Y)$ ]]; then
            echo "Upgrade cancelled."
            return 0
        fi
    fi

    backup_config "pre-upgrade"
    tmp_dir=$(mktemp -d)
    trap 'rm -rf "$tmp_dir"' RETURN

    echo "Downloading $source_url"
    curl -fsSL "$source_url" | tar -xz -C "$tmp_dir"
    source_dir=$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    if [ -z "$source_dir" ] || [ ! -f "$source_dir/install.sh" ]; then
        echo "Downloaded archive does not contain install.sh."
        return 1
    fi

    echo "Installing updated GREX files..."
    (cd "$source_dir" && run_as_root bash install.sh)
    rm -f "$UPDATE_CACHE_FILE" 2>/dev/null || true
    echo "Upgrade complete. /etc/gre-tunnel.conf was preserved."
    echo "Run 'sudo grex version' to verify the installed version."
}

run_configure() {
    if [ -x "$SCRIPT_DIR/setup.sh" ]; then
        run_as_root bash "$SCRIPT_DIR/setup.sh"
    else
        echo "setup.sh not found in $SCRIPT_DIR"
        exit 1
    fi
}

truthy() {
    [[ "${1:-}" =~ ^(yes|y|true|1|on|Y|TRUE)$ ]]
}

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

is_ipv4() {
    local ip=$1
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    local octets
    read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if ((10#$octet < 0 || 10#$octet > 255)); then
            return 1
        fi
    done

    return 0
}

is_ipv4_cidr() {
    local value=$1
    local ip
    local prefix

    [[ "$value" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    ip=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    is_ipv4 "$ip" || return 1
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

is_ipv4_or_cidr() {
    is_ipv4 "$1" || is_ipv4_cidr "$1"
}

validate_ip_list() {
    local value=$1
    local label=$2
    local item

    IFS=',' read -ra ITEMS <<< "$value"
    for item in "${ITEMS[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || continue
        if ! is_ipv4_or_cidr "$item"; then
            echo "$label contains invalid IP/CIDR: $item" >&2
            return 1
        fi
    done
}

validate_numeric_range() {
    local value=$1
    local label=$2
    local min=$3
    local max=$4

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "$label must be a number between $min and $max." >&2
        return 1
    fi
}

validate_limit_rate() {
    local value=$1
    local label=$2

    if ! [[ "$value" =~ ^[0-9]+/(sec|min|hour|day|second|minute)$ ]]; then
        echo "$label must look like 3/min, 10/sec, or 1/hour." >&2
        return 1
    fi
}

ipv4_to_int() {
    local ip=$1
    local a b c d
    IFS=. read -r a b c d <<< "$ip"
    printf "%u" $((a * 16777216 + b * 65536 + c * 256 + d))
}

ip_in_cidr() {
    local ip=$1
    local cidr=$2
    local network prefix mask ip_int network_int

    if is_ipv4 "$cidr"; then
        [ "$ip" = "$cidr" ]
        return $?
    fi

    is_ipv4_cidr "$cidr" || return 1
    network=${cidr%/*}
    prefix=${cidr#*/}
    ip_int=$(ipv4_to_int "$ip")
    network_int=$(ipv4_to_int "$network")
    if [ "$prefix" -eq 0 ]; then
        mask=0
    else
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi

    [ $((ip_int & mask)) -eq $((network_int & mask)) ]
}

ip_in_list() {
    local ip=$1
    local list=$2
    local item

    IFS=',' read -ra ITEMS <<< "$list"
    for item in "${ITEMS[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || continue
        if ip_in_cidr "$ip" "$item"; then
            return 0
        fi
    done

    return 1
}

detect_admin_ip() {
    local ip

    ip=${SSH_CLIENT%% *}
    if is_ipv4 "$ip"; then
        printf "%s" "$ip"
        return 0
    fi

    ip=${SSH_CONNECTION%% *}
    if is_ipv4 "$ip"; then
        printf "%s" "$ip"
        return 0
    fi

    return 1
}

validate_configuration() {
    [ -n "$VPS_PUBLIC_IP" ] || { echo "VPS_PUBLIC_IP is required." >&2; return 1; }
    [ -n "$REMOTE_PUBLIC_IP" ] || { echo "REMOTE_PUBLIC_IP is required." >&2; return 1; }
    [ -n "$INTERNAL_SUBNETS" ] || { echo "INTERNAL_SUBNETS is required." >&2; return 1; }
    [ -n "$ETH_INTERFACE" ] || { echo "ETH_INTERFACE is required." >&2; return 1; }
    [ -n "$VPS_TUNNEL_IP" ] || { echo "VPS_TUNNEL_IP is required." >&2; return 1; }
    [ -n "$REMOTE_TUNNEL_IP" ] || { echo "REMOTE_TUNNEL_IP is required." >&2; return 1; }
    [ -n "$GRE_IF" ] || { echo "GRE_IF is required." >&2; return 1; }

    is_ipv4 "$VPS_PUBLIC_IP" || { echo "VPS_PUBLIC_IP must be a valid IPv4 address." >&2; return 1; }
    is_ipv4 "$REMOTE_PUBLIC_IP" || { echo "REMOTE_PUBLIC_IP must be a valid IPv4 address." >&2; return 1; }
    is_ipv4_cidr "$VPS_TUNNEL_IP" || { echo "VPS_TUNNEL_IP must be IPv4 CIDR, for example 10.10.10.2/30." >&2; return 1; }
    is_ipv4 "$REMOTE_TUNNEL_IP" || { echo "REMOTE_TUNNEL_IP must be a valid IPv4 address." >&2; return 1; }
    validate_ip_list "$INTERNAL_SUBNETS" "INTERNAL_SUBNETS" || return 1

    if dns_enabled && [ -n "$DNS_SERVERS" ]; then
        validate_ip_list "$DNS_SERVERS" "DNS_SERVERS" || return 1
    fi

    if ! [[ "$GRE_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        echo "GRE_IF must be 1-15 characters using letters, numbers, dot, underscore, colon, or dash." >&2
        return 1
    fi

    validate_numeric_range "$GRE_MTU" "GRE_MTU" 576 9000 || return 1
    case "$MSS_MODE" in fixed|clamp|off) ;; *) echo "MSS_MODE must be fixed, clamp, or off." >&2; return 1 ;; esac
    if [ "$MSS_MODE" = "fixed" ]; then
        validate_numeric_range "$MSS_VALUE" "MSS_VALUE" 536 8960 || return 1
    fi

    if truthy "$ENABLE_HARDENING"; then
        [ -n "$ADMIN_IPS" ] && [ "$ADMIN_IPS" != "x.x.x.x" ] || { echo "ADMIN_IPS must be configured when hardening is enabled." >&2; return 1; }
        validate_ip_list "$ADMIN_IPS" "ADMIN_IPS" || return 1
    fi

    if truthy "$ENABLE_DROP_LOGGING"; then
        validate_limit_rate "$DROP_LOG_RATE" "DROP_LOG_RATE" || return 1
        validate_numeric_range "$DROP_LOG_BURST" "DROP_LOG_BURST" 1 1000 || return 1
    fi

    case "$SYSCTL_PROFILE" in safe|strict|custom|off) ;; *) echo "SYSCTL_PROFILE must be safe, strict, custom, or off." >&2; return 1 ;; esac
    validate_numeric_range "$RP_FILTER" "RP_FILTER" 0 2 || return 1
    validate_numeric_range "$TCP_TIMESTAMPS" "TCP_TIMESTAMPS" 0 1 || return 1
    validate_numeric_range "$NF_CONNTRACK_MAX" "NF_CONNTRACK_MAX" 1 999999999 || return 1
}

confirm_ssh_lockout_risk() {
    local detected_admin_ip
    local answer

    truthy "$ENABLE_HARDENING" || return 0
    detected_admin_ip=$(detect_admin_ip || true)

    if [ -z "$detected_admin_ip" ]; then
        echo "WARNING: Could not detect your current SSH source IP." >&2
        read -r -p "Continue with firewall hardening anyway? (yes/no) [no]: " answer
        [[ "${answer:-no}" =~ ^(yes|y|Y)$ ]]
        return $?
    fi

    if ! ip_in_list "$detected_admin_ip" "$ADMIN_IPS"; then
        echo "WARNING: Your current SSH source IP ($detected_admin_ip) is not in ADMIN_IPS: $ADMIN_IPS" >&2
        read -r -p "This can lock you out. Continue anyway? (yes/no) [no]: " answer
        [[ "${answer:-no}" =~ ^(yes|y|Y)$ ]]
        return $?
    fi
}

normalize_config() {
    local legacy_public_var
    local legacy_tunnel_var
    local legacy_tunnel_1_var

    legacy_public_var="FO""RTI_PUBLIC_IP"
    legacy_tunnel_var="FO""RTI_TUNNEL_IP"
    legacy_tunnel_1_var="TUNNEL_1_FO""RTI_IP"

    VPS_PUBLIC_IP=${VPS_PUBLIC_IP:-}
    REMOTE_PUBLIC_IP=${REMOTE_PUBLIC_IP:-${!legacy_public_var:-}}
    INTERNAL_SUBNETS=${INTERNAL_SUBNETS:-}
    ENABLE_DNSMASQ=${ENABLE_DNSMASQ:-yes}
    DNS_SERVERS=${DNS_SERVERS:-}
    ETH_INTERFACE=${ETH_INTERFACE:-eth0}
    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    REMOTE_TUNNEL_IP=${REMOTE_TUNNEL_IP:-${!legacy_tunnel_var:-${!legacy_tunnel_1_var:-}}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-grex}}
    GRE_KEY=${GRE_KEY:-}
    GRE_MTU=${GRE_MTU:-1400}
    MSS_MODE=${MSS_MODE:-fixed}
    MSS_VALUE=${MSS_VALUE:-1360}
    ENABLE_HARDENING=${ENABLE_HARDENING:-yes}
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    ALLOW_ICMP=${ALLOW_ICMP:-yes}
    ENABLE_EGRESS_FILTERING=${ENABLE_EGRESS_FILTERING:-no}
    BLOCK_SMTP_OUT=${BLOCK_SMTP_OUT:-yes}
    BLOCK_PRIVATE_DESTINATIONS=${BLOCK_PRIVATE_DESTINATIONS:-yes}
    ENABLE_DROP_LOGGING=${ENABLE_DROP_LOGGING:-no}
    DROP_LOG_RATE=${DROP_LOG_RATE:-3/min}
    DROP_LOG_BURST=${DROP_LOG_BURST:-10}
    ENABLE_SYSCTL_HARDENING=${ENABLE_SYSCTL_HARDENING:-yes}
    SYSCTL_PROFILE=${SYSCTL_PROFILE:-safe}
    RP_FILTER=${RP_FILTER:-2}
    TCP_TIMESTAMPS=${TCP_TIMESTAMPS:-1}
    LOG_MARTIANS=${LOG_MARTIANS:-yes}
    DISABLE_IPV6=${DISABLE_IPV6:-no}
    NF_CONNTRACK_MAX=${NF_CONNTRACK_MAX:-262144}
    ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-yes}
    FAIL2BAN_SSHD_ENABLED=${FAIL2BAN_SSHD_ENABLED:-true}
    FAIL2BAN_SSHD_PORT=${FAIL2BAN_SSHD_PORT:-22}
    FAIL2BAN_SSHD_MAXRETRY=${FAIL2BAN_SSHD_MAXRETRY:-3}
    FAIL2BAN_SSHD_FINDTIME=${FAIL2BAN_SSHD_FINDTIME:-10m}
    FAIL2BAN_SSHD_BANTIME=${FAIL2BAN_SSHD_BANTIME:-1h}
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Run 'sudo grex configure' first."
        return 1
    fi

    source "$CONFIG_FILE"
    normalize_config
}

write_config() {
    backup_config "pre-edit"
    run_as_root bash -c "cat > '$CONFIG_FILE'" << EOF
VPS_PUBLIC_IP=$VPS_PUBLIC_IP
REMOTE_PUBLIC_IP=$REMOTE_PUBLIC_IP
INTERNAL_SUBNETS=$INTERNAL_SUBNETS
ENABLE_DNSMASQ=$ENABLE_DNSMASQ
DNS_SERVERS=$DNS_SERVERS
ETH_INTERFACE=$ETH_INTERFACE
VPS_TUNNEL_IP=$VPS_TUNNEL_IP
REMOTE_TUNNEL_IP=$REMOTE_TUNNEL_IP
GRE_IF=$GRE_IF
GRE_KEY=$GRE_KEY
GRE_MTU=$GRE_MTU
MSS_MODE=$MSS_MODE
MSS_VALUE=$MSS_VALUE
ENABLE_HARDENING=$ENABLE_HARDENING
ADMIN_IPS=$ADMIN_IPS
ALLOW_ICMP=$ALLOW_ICMP
ENABLE_EGRESS_FILTERING=$ENABLE_EGRESS_FILTERING
BLOCK_SMTP_OUT=$BLOCK_SMTP_OUT
BLOCK_PRIVATE_DESTINATIONS=$BLOCK_PRIVATE_DESTINATIONS
ENABLE_DROP_LOGGING=$ENABLE_DROP_LOGGING
DROP_LOG_RATE=$DROP_LOG_RATE
DROP_LOG_BURST=$DROP_LOG_BURST
ENABLE_SYSCTL_HARDENING=$ENABLE_SYSCTL_HARDENING
SYSCTL_PROFILE=$SYSCTL_PROFILE
RP_FILTER=$RP_FILTER
TCP_TIMESTAMPS=$TCP_TIMESTAMPS
LOG_MARTIANS=$LOG_MARTIANS
DISABLE_IPV6=$DISABLE_IPV6
NF_CONNTRACK_MAX=$NF_CONNTRACK_MAX
ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN
FAIL2BAN_SSHD_ENABLED=$FAIL2BAN_SSHD_ENABLED
FAIL2BAN_SSHD_PORT=$FAIL2BAN_SSHD_PORT
FAIL2BAN_SSHD_MAXRETRY=$FAIL2BAN_SSHD_MAXRETRY
FAIL2BAN_SSHD_FINDTIME=$FAIL2BAN_SSHD_FINDTIME
FAIL2BAN_SSHD_BANTIME=$FAIL2BAN_SSHD_BANTIME
EOF
    secure_config_file
}

configure_dnsmasq_file() {
    if ! dns_enabled; then
        stop_dnsmasq_if_running
        if has_systemd; then
            run_as_root systemctl disable dnsmasq 2>/dev/null || true
        fi
        return 0
    fi

    if ! command -v dnsmasq >/dev/null 2>&1 && ! { has_systemd && systemctl list-unit-files | grep -q '^dnsmasq'; }; then
        echo "dnsmasq is enabled but dnsmasq was not found. Install it or disable DNS."
        return 0
    fi

    local listen_ip
    listen_ip=$(echo "$VPS_TUNNEL_IP" | cut -d'/' -f1)

    run_as_root mkdir -p /etc/dnsmasq.d
    run_as_root bash -c "cat > /etc/dnsmasq.d/tunnel.conf" << EOF
bind-dynamic
no-resolv
interface=$GRE_IF
listen-address=$listen_ip
EOF

    local dns
    for dns in ${DNS_SERVERS//,/ }; do
        dns=$(trim "$dns")
        [ -n "$dns" ] || continue
        run_as_root bash -c "printf '%s\n' 'server=$dns' >> /etc/dnsmasq.d/tunnel.conf"
    done
}

configure_fail2ban_from_config() {
    if ! truthy "$ENABLE_FAIL2BAN"; then
        run_as_root rm -f /etc/fail2ban/jail.d/grex-sshd.local
        if has_systemd && systemctl list-unit-files | grep -q '^fail2ban'; then
            run_as_root systemctl restart fail2ban 2>/dev/null || true
        fi
        return 0
    fi

    if ! command -v fail2ban-server >/dev/null 2>&1; then
        echo "fail2ban is enabled but fail2ban-server was not found."
        return 0
    fi

    local ignore_ips
    ignore_ips="127.0.0.1/8 ::1"
    if [ -n "${ADMIN_IPS:-}" ]; then
        ignore_ips="$ignore_ips ${ADMIN_IPS//,/ }"
    fi

    run_as_root mkdir -p /etc/fail2ban/jail.d
    run_as_root bash -c "cat > /etc/fail2ban/jail.d/grex-sshd.local" << EOF
[sshd]
enabled = $FAIL2BAN_SSHD_ENABLED
port = $FAIL2BAN_SSHD_PORT
maxretry = $FAIL2BAN_SSHD_MAXRETRY
findtime = $FAIL2BAN_SSHD_FINDTIME
bantime = $FAIL2BAN_SSHD_BANTIME
ignoreip = $ignore_ips
EOF

    if has_systemd; then
        run_as_root systemctl enable --now fail2ban
        run_as_root systemctl restart fail2ban
    elif command -v service >/dev/null 2>&1; then
        run_as_root service fail2ban restart 2>/dev/null || run_as_root service fail2ban start 2>/dev/null || true
    fi
}

apply_saved_config() {
    load_config || return 1
    validate_configuration || return 1
    confirm_ssh_lockout_risk || return 1
    configure_dnsmasq_file
    configure_fail2ban_from_config
    if [ -x "$SCRIPT_DIR/gre-sysctl.sh" ]; then
        run_as_root "$SCRIPT_DIR/gre-sysctl.sh"
    fi
    SKIP_LOCKOUT_CONFIRM=1 activate
}

edit_config_value() {
    local var_name=$1
    local label=$2
    local current_value
    local new_value
    local old_value

    current_value=${!var_name}
    echo
    echo "$label"
    echo "Current: ${current_value:-<blank>}"
    read -r -p "New value (leave blank to keep current, type <blank> to clear): " new_value
    old_value=$current_value
    if [ "$new_value" = "<blank>" ]; then
        printf -v "$var_name" "%s" ""
    elif [ -n "$new_value" ]; then
        printf -v "$var_name" "%s" "$new_value"
    else
        echo "No change."
        read -p "Press Enter to continue..." _
        return 0
    fi

    if ! validate_configuration; then
        printf -v "$var_name" "%s" "$old_value"
        echo "Invalid value. $var_name was not changed."
    else
        write_config
        if [ "$new_value" = "<blank>" ]; then
            echo "Cleared $var_name."
        else
            echo "Saved $var_name."
        fi
    fi
    read -p "Press Enter to continue..." _
}

edit_config_menu() {
    load_config || {
        read -p "Press Enter to continue..." _
        return 0
    }

    while true; do
        clear
        echo "========================================"
        echo "        GREX Configuration Editor        "
        echo "========================================"
        echo " 1) VPS public IP                 [$VPS_PUBLIC_IP]"
        echo " 2) Remote gateway public IP      [$REMOTE_PUBLIC_IP]"
        echo " 3) Internal subnets              [$INTERNAL_SUBNETS]"
        echo " 4) DNS enabled                   [$ENABLE_DNSMASQ]"
        echo " 5) Upstream DNS servers          [$DNS_SERVERS]"
        echo " 6) Ethernet egress interface     [$ETH_INTERFACE]"
        echo " 7) VPS tunnel IP                 [$VPS_TUNNEL_IP]"
        echo " 8) Remote gateway tunnel IP      [$REMOTE_TUNNEL_IP]"
        echo " 9) GRE interface                 [$GRE_IF]"
        echo "10) GRE key                       [${GRE_KEY:-<blank>}]"
        echo "11) GRE MTU                       [$GRE_MTU]"
        echo "12) TCP MSS mode                  [$MSS_MODE]"
        echo "13) TCP MSS value                 [$MSS_VALUE]"
        echo "14) Firewall hardening enabled    [$ENABLE_HARDENING]"
        echo "15) Admin SSH source IPs/CIDRs    [$ADMIN_IPS]"
        echo "16) Allow ICMP                    [$ALLOW_ICMP]"
        echo "17) Egress filtering enabled      [$ENABLE_EGRESS_FILTERING]"
        echo "18) Block outbound SMTP           [$BLOCK_SMTP_OUT]"
        echo "19) Block private destinations    [$BLOCK_PRIVATE_DESTINATIONS]"
        echo "20) Firewall drop logging         [$ENABLE_DROP_LOGGING]"
        echo "21) Drop log rate limit           [$DROP_LOG_RATE]"
        echo "22) Drop log burst                [$DROP_LOG_BURST]"
        echo "23) Sysctl hardening enabled      [$ENABLE_SYSCTL_HARDENING]"
        echo "24) Sysctl profile                [$SYSCTL_PROFILE]"
        echo "25) rp_filter                     [$RP_FILTER]"
        echo "26) TCP timestamps                [$TCP_TIMESTAMPS]"
        echo "27) Log martians                  [$LOG_MARTIANS]"
        echo "28) Disable IPv6                  [$DISABLE_IPV6]"
        echo "29) nf_conntrack_max              [$NF_CONNTRACK_MAX]"
        echo "30) fail2ban enabled              [$ENABLE_FAIL2BAN]"
        echo "31) fail2ban sshd enabled         [$FAIL2BAN_SSHD_ENABLED]"
        echo "32) fail2ban sshd port            [$FAIL2BAN_SSHD_PORT]"
        echo "33) fail2ban maxretry             [$FAIL2BAN_SSHD_MAXRETRY]"
        echo "34) fail2ban findtime             [$FAIL2BAN_SSHD_FINDTIME]"
        echo "35) fail2ban bantime              [$FAIL2BAN_SSHD_BANTIME]"
        echo "A) Apply saved configuration"
        echo "0) Back"
        echo
        read -r -p "Choose an option: " edit_choice
        case "$edit_choice" in
            1) edit_config_value VPS_PUBLIC_IP "VPS public IP" ;;
            2) edit_config_value REMOTE_PUBLIC_IP "Remote gateway public IP" ;;
            3) edit_config_value INTERNAL_SUBNETS "Internal subnets (comma-separated)" ;;
            4) edit_config_value ENABLE_DNSMASQ "Enable DNS with dnsmasq? (yes/no)" ;;
            5) edit_config_value DNS_SERVERS "Upstream DNS servers (comma-separated)" ;;
            6) edit_config_value ETH_INTERFACE "Ethernet egress interface" ;;
            7) edit_config_value VPS_TUNNEL_IP "VPS tunnel IP with mask" ;;
            8) edit_config_value REMOTE_TUNNEL_IP "Remote gateway tunnel IP" ;;
            9) edit_config_value GRE_IF "GRE interface" ;;
            10) edit_config_value GRE_KEY "GRE key (blank for no key)" ;;
            11) edit_config_value GRE_MTU "GRE MTU" ;;
            12) edit_config_value MSS_MODE "TCP MSS mode (fixed/clamp/off)" ;;
            13) edit_config_value MSS_VALUE "TCP MSS value" ;;
            14) edit_config_value ENABLE_HARDENING "Enable firewall hardening? (yes/no)" ;;
            15) edit_config_value ADMIN_IPS "Admin SSH source IPs/CIDRs (comma-separated)" ;;
            16) edit_config_value ALLOW_ICMP "Allow ICMP? (yes/no)" ;;
            17) edit_config_value ENABLE_EGRESS_FILTERING "Enable optional egress filtering? (yes/no)" ;;
            18) edit_config_value BLOCK_SMTP_OUT "Block outbound SMTP port 25? (yes/no)" ;;
            19) edit_config_value BLOCK_PRIVATE_DESTINATIONS "Block private/reserved destinations? (yes/no)" ;;
            20) edit_config_value ENABLE_DROP_LOGGING "Enable rate-limited firewall drop logging? (yes/no)" ;;
            21) edit_config_value DROP_LOG_RATE "Firewall drop log rate limit" ;;
            22) edit_config_value DROP_LOG_BURST "Firewall drop log burst" ;;
            23) edit_config_value ENABLE_SYSCTL_HARDENING "Enable sysctl hardening? (yes/no)" ;;
            24) edit_config_value SYSCTL_PROFILE "Sysctl profile (safe/strict/custom)" ;;
            25) edit_config_value RP_FILTER "rp_filter (2 loose, 1 strict, 0 off)" ;;
            26) edit_config_value TCP_TIMESTAMPS "TCP timestamps (1 on, 0 off)" ;;
            27) edit_config_value LOG_MARTIANS "Log martians? (yes/no)" ;;
            28) edit_config_value DISABLE_IPV6 "Disable IPv6? (yes/no)" ;;
            29) edit_config_value NF_CONNTRACK_MAX "nf_conntrack_max" ;;
            30) edit_config_value ENABLE_FAIL2BAN "Enable fail2ban? (yes/no)" ;;
            31) edit_config_value FAIL2BAN_SSHD_ENABLED "fail2ban sshd enabled (true/false)" ;;
            32) edit_config_value FAIL2BAN_SSHD_PORT "fail2ban sshd port" ;;
            33) edit_config_value FAIL2BAN_SSHD_MAXRETRY "fail2ban maxretry" ;;
            34) edit_config_value FAIL2BAN_SSHD_FINDTIME "fail2ban findtime" ;;
            35) edit_config_value FAIL2BAN_SSHD_BANTIME "fail2ban bantime" ;;
            A|a)
                apply_saved_config
                read -p "Press Enter to continue..." _
                ;;
            0)
                return 0
                ;;
            *)
                echo "Invalid selection."
                read -p "Press Enter to continue..." _
                ;;
        esac
        load_config >/dev/null 2>&1 || true
    done
}

activate() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Run 'sudo grex configure' first."
        exit 1
    fi
    source "$CONFIG_FILE"
    normalize_config
    validate_configuration || exit 1
    if [ "${SKIP_LOCKOUT_CONFIRM:-0}" != "1" ]; then
        confirm_ssh_lockout_risk || exit 1
    fi
    if has_systemd; then
        run_as_root systemctl daemon-reload
        run_as_root systemctl enable gre-tunnel
        if ! run_as_root systemctl restart gre-tunnel; then
            show_gre_tunnel_failure
            exit 1
        fi
    else
        run_as_root "$SCRIPT_DIR/gre-tunnel.sh"
    fi
    start_dnsmasq_if_enabled
    echo "GRE tunnel activated."
}

deactivate() {
    stop_dnsmasq_if_running
    if has_systemd; then
        run_as_root systemctl stop gre-tunnel 2>/dev/null || true
        run_as_root systemctl disable gre-tunnel 2>/dev/null || true
        run_as_root systemctl disable dnsmasq 2>/dev/null || true
    fi
    run_as_root "$SCRIPT_DIR/gre-tunnel-stop.sh" || true
    echo "GRE tunnel deactivated."
}

menu() {
    while true; do
        clear
        echo "========================================"
        echo "          GREX Egress Gateway           "
        echo "========================================"
        version_summary
        echo "----------------------------------------"
        echo "1) Help & Introduction"
        echo "2) Configure GREX System (Wizard)"
        echo "3) Edit GREX Configuration"
        echo "4) Activate GREX System"
        echo "5) Deactivate GREX System"
        echo "6) Health Check"
        echo "7) Logs"
        echo "8) Upgrade GREX"
        echo "9) Backup / Restore Config"
        echo "0) Exit"
        echo
        read -p "Choose an option [0-9]: " choice
        case "$choice" in
            1)
                echo
                echo "GREX is a GRE tunnel egress management toolkit."
                echo "Use configure to create /etc/gre-tunnel.conf, activate to bring the tunnel up,"
                echo "edit to change one setting at a time, health to verify config, and logs to inspect service output."
                read -p "Press Enter to continue..." _
                ;;
            2)
                run_configure
                read -p "Press Enter to continue..." _
                ;;
            3)
                edit_config_menu
                ;;
            4)
                activate
                read -p "Press Enter to continue..." _
                ;;
            5)
                deactivate
                read -p "Press Enter to continue..." _
                ;;
            6)
                run_as_root "$SCRIPT_DIR/health.sh"
                read -p "Press Enter to continue..." _
                ;;
            7)
                echo "=== gre-tunnel logs ==="
                if has_systemd && command -v journalctl >/dev/null 2>&1; then
                    run_as_root journalctl -u gre-tunnel -n 50 --no-pager
                else
                    echo "systemd journal is not available"
                fi
                echo "=== dnsmasq logs ==="
                if has_systemd && command -v journalctl >/dev/null 2>&1; then
                    run_as_root journalctl -u dnsmasq -n 50 --no-pager 2>/dev/null || echo "dnsmasq logs are not available"
                else
                    echo "dnsmasq logs are not available"
                fi
                read -p "Press Enter to continue..." _
                ;;
            8)
                upgrade_grex
                read -p "Press Enter to continue..." _
                ;;
            9)
                echo "=== GREX config backups ==="
                list_config_backups
                echo
                echo "1) Create backup now"
                echo "2) Restore latest backup"
                echo "0) Back"
                read -r -p "Choose an option [0-2]: " backup_choice
                case "$backup_choice" in
                    1) backup_config "manual" ;;
                    2) restore_latest_config_backup ;;
                    0) ;;
                    *) echo "Invalid selection." ;;
                esac
                read -p "Press Enter to continue..." _
                ;;
            0)
                exit 0
                ;;
            *)
                echo "Invalid selection."
                read -p "Press Enter to continue..." _
                ;;
        esac
    done
}

if [ $# -eq 0 ]; then
    menu
    exit 0
fi

COMMAND=$1
case $COMMAND in
    help)
        usage 0
        ;;
    version)
        version_summary
        ;;
    check-upgrade)
        version_summary
        ;;
    upgrade)
        upgrade_grex
        ;;
    backup)
        backup_config "manual"
        ;;
    restore)
        restore_latest_config_backup
        ;;
    configure)
        run_configure
        ;;
    edit)
        edit_config_menu
        ;;
    activate)
        activate
        ;;
    deactivate)
        deactivate
        ;;
    enable)
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        fi
        if has_systemd; then
            run_as_root systemctl enable gre-tunnel
            if dns_enabled && systemctl list-unit-files | grep -q '^dnsmasq'; then
                run_as_root systemctl enable dnsmasq
            fi
            echo "GRE tunnel service enabled"
        else
            echo "enable requires systemd; use 'sudo grex activate' to start GREX directly on this system."
        fi
        ;;
    disable)
        if has_systemd; then
            run_as_root systemctl disable gre-tunnel
            run_as_root systemctl disable dnsmasq 2>/dev/null || true
            echo "GRE tunnel service disabled"
        else
            echo "disable requires systemd; no persistent service was disabled."
        fi
        ;;
    start)
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
            normalize_config
            validate_configuration || exit 1
            confirm_ssh_lockout_risk || exit 1
        fi
        if has_systemd; then
            run_as_root systemctl start gre-tunnel
        else
            run_as_root "$SCRIPT_DIR/gre-tunnel.sh"
        fi
        start_dnsmasq_if_enabled
        echo "GRE tunnel started"
        ;;
    stop)
        stop_dnsmasq_if_running
        if has_systemd; then
            run_as_root systemctl stop gre-tunnel
        else
            run_as_root "$SCRIPT_DIR/gre-tunnel-stop.sh"
        fi
        echo "GRE tunnel stopped"
        ;;
    status)
        echo "GRE Tunnel Status:"
        if has_systemd; then
            run_as_root systemctl status gre-tunnel --no-pager -l
        else
            run_as_root "$SCRIPT_DIR/health.sh"
        fi
        echo
        echo "DNS Service Status:"
        if has_systemd; then
            run_as_root systemctl status dnsmasq --no-pager -l 2>/dev/null || echo "dnsmasq is not installed or not available"
        elif command -v pgrep >/dev/null 2>&1 && pgrep -x dnsmasq >/dev/null 2>&1; then
            echo "dnsmasq is running"
        else
            echo "dnsmasq is not running"
        fi
        ;;
    logs)
        echo "GRE Tunnel Logs:"
        if has_systemd && command -v journalctl >/dev/null 2>&1; then
            run_as_root journalctl -u gre-tunnel -n 50 --no-pager
        else
            echo "systemd journal is not available"
        fi
        echo
        echo "DNS Logs:"
        if has_systemd && command -v journalctl >/dev/null 2>&1; then
            run_as_root journalctl -u dnsmasq -n 50 --no-pager 2>/dev/null || echo "dnsmasq logs are not available"
        else
            echo "dnsmasq logs are not available"
        fi
        ;;
    health)
        run_as_root "$SCRIPT_DIR/health.sh"
        ;;
    check)
        run_as_root "$SCRIPT_DIR/check.sh"
        ;;
    *)
        usage
        ;;
esac
