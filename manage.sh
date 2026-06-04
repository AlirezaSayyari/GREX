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
    echo "Usage: $0 {help|version|check-upgrade|upgrade|backup|restore|configure|edit|diagnostics|monitor|bandwidth|mtu-advisor|activate|deactivate|enable|disable|start|stop|status|logs|health|check}"
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
    local latest_release
    local latest_tag
    local latest

    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi

    api_url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/releases/latest"
    response=$(curl -fsSL --connect-timeout 3 --max-time 8 "$api_url" 2>/dev/null || true)
    latest_release=$(printf "%s" "$response" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

    api_url="https://api.github.com/repos/$REPO_OWNER/$REPO_NAME/tags"
    response=$(curl -fsSL --connect-timeout 3 --max-time 8 "$api_url" 2>/dev/null || true)
    latest_tag=$(printf "%s" "$response" | sed -n 's/.*"name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n 1)

    latest=$latest_release
    if [ -z "$latest" ] || { [ -n "$latest_tag" ] && version_gt "$latest_tag" "$latest"; }; then
        latest=$latest_tag
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

latest_version_fresh() {
    local latest

    latest=$(fetch_latest_version || true)
    [ -n "$latest" ] || return 1
    printf "%s" "$latest" > "$UPDATE_CACHE_FILE" 2>/dev/null || true
    printf "%s" "$latest"
}

version_summary() {
    local mode=${1:-cached}
    local current
    local latest

    current=$(installed_version)
    if [ "$mode" = "fresh" ]; then
        latest=$(latest_version_fresh || true)
        if [ -z "$latest" ]; then
            latest=$(latest_version_cached || true)
        fi
    else
        latest=$(latest_version_cached || true)
    fi

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
    local installed_after_upgrade

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
    installed_after_upgrade=$(installed_version)
    if [ "$latest" != "$REPO_BRANCH" ] && [ "$installed_after_upgrade" != "$latest" ]; then
        echo "WARNING: Upgrade target was $latest but installed VERSION is $installed_after_upgrade."
        echo "The published tag/release may contain an outdated VERSION file."
        echo "Create a new release with VERSION set to the release tag, then run upgrade again."
        return 1
    fi
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
    validate_numeric_range "$CONNTRACK_WARN_PERCENT" "CONNTRACK_WARN_PERCENT" 1 100 || return 1
    validate_numeric_range "$CONNTRACK_CRIT_PERCENT" "CONNTRACK_CRIT_PERCENT" 1 100 || return 1
    if [ "$CONNTRACK_WARN_PERCENT" -ge "$CONNTRACK_CRIT_PERCENT" ]; then
        echo "CONNTRACK_WARN_PERCENT must be lower than CONNTRACK_CRIT_PERCENT." >&2
        return 1
    fi
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
    CONNTRACK_WARN_PERCENT=${CONNTRACK_WARN_PERCENT:-70}
    CONNTRACK_CRIT_PERCENT=${CONNTRACK_CRIT_PERCENT:-90}
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
CONNTRACK_WARN_PERCENT=$CONNTRACK_WARN_PERCENT
CONNTRACK_CRIT_PERCENT=$CONNTRACK_CRIT_PERCENT
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
        echo "30) Conntrack warning percent     [$CONNTRACK_WARN_PERCENT]"
        echo "31) Conntrack critical percent    [$CONNTRACK_CRIT_PERCENT]"
        echo "32) fail2ban enabled              [$ENABLE_FAIL2BAN]"
        echo "33) fail2ban sshd enabled         [$FAIL2BAN_SSHD_ENABLED]"
        echo "34) fail2ban sshd port            [$FAIL2BAN_SSHD_PORT]"
        echo "35) fail2ban maxretry             [$FAIL2BAN_SSHD_MAXRETRY]"
        echo "36) fail2ban findtime             [$FAIL2BAN_SSHD_FINDTIME]"
        echo "37) fail2ban bantime              [$FAIL2BAN_SSHD_BANTIME]"
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
            30) edit_config_value CONNTRACK_WARN_PERCENT "Conntrack usage warning percent" ;;
            31) edit_config_value CONNTRACK_CRIT_PERCENT "Conntrack usage critical percent" ;;
            32) edit_config_value ENABLE_FAIL2BAN "Enable fail2ban? (yes/no)" ;;
            33) edit_config_value FAIL2BAN_SSHD_ENABLED "fail2ban sshd enabled (true/false)" ;;
            34) edit_config_value FAIL2BAN_SSHD_PORT "fail2ban sshd port" ;;
            35) edit_config_value FAIL2BAN_SSHD_MAXRETRY "fail2ban maxretry" ;;
            36) edit_config_value FAIL2BAN_SSHD_FINDTIME "fail2ban findtime" ;;
            37) edit_config_value FAIL2BAN_SSHD_BANTIME "fail2ban bantime" ;;
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

read_counter() {
    local iface=$1
    local counter=$2
    local path="/sys/class/net/$iface/statistics/$counter"

    if [ -r "$path" ]; then
        cat "$path"
    else
        printf "0"
    fi
}

sample_interface_rate() {
    local iface=$1
    local seconds=${2:-1}
    local rx1 tx1 rx2 tx2 rx_rate tx_rate

    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
        echo "$iface: not found"
        return 0
    fi

    rx1=$(read_counter "$iface" rx_bytes)
    tx1=$(read_counter "$iface" tx_bytes)
    sleep "$seconds"
    rx2=$(read_counter "$iface" rx_bytes)
    tx2=$(read_counter "$iface" tx_bytes)
    rx_rate=$(( (rx2 - rx1) * 8 / seconds ))
    tx_rate=$(( (tx2 - tx1) * 8 / seconds ))

    printf "%s: RX %.2f Mbit/s, TX %.2f Mbit/s, drops RX/TX %s/%s, errors RX/TX %s/%s\n" \
        "$iface" \
        "$(awk "BEGIN {print $rx_rate/1000000}")" \
        "$(awk "BEGIN {print $tx_rate/1000000}")" \
        "$(read_counter "$iface" rx_dropped)" \
        "$(read_counter "$iface" tx_dropped)" \
        "$(read_counter "$iface" rx_errors)" \
        "$(read_counter "$iface" tx_errors)"
}

print_interface_rate_line() {
    local iface=$1
    local seconds=$2
    local rx1=$3
    local tx1=$4
    local drop_rx1=$5
    local drop_tx1=$6
    local err_rx1=$7
    local err_tx1=$8
    local rx2 tx2 drop_rx2 drop_tx2 err_rx2 err_tx2 rx_rate tx_rate

    if [ -z "$iface" ] || [ ! -d "/sys/class/net/$iface" ]; then
        printf "%-10s not found\n" "$iface"
        return 0
    fi

    rx2=$(read_counter "$iface" rx_bytes)
    tx2=$(read_counter "$iface" tx_bytes)
    drop_rx2=$(read_counter "$iface" rx_dropped)
    drop_tx2=$(read_counter "$iface" tx_dropped)
    err_rx2=$(read_counter "$iface" rx_errors)
    err_tx2=$(read_counter "$iface" tx_errors)
    rx_rate=$(( (rx2 - rx1) * 8 / seconds ))
    tx_rate=$(( (tx2 - tx1) * 8 / seconds ))

    printf "%-10s RX %8.2f Mbit/s  TX %8.2f Mbit/s  drops +%s/+%s total %s/%s  errors +%s/+%s total %s/%s\n" \
        "$iface" \
        "$(awk "BEGIN {print $rx_rate/1000000}")" \
        "$(awk "BEGIN {print $tx_rate/1000000}")" \
        "$((drop_rx2 - drop_rx1))" "$((drop_tx2 - drop_tx1))" "$drop_rx2" "$drop_tx2" \
        "$((err_rx2 - err_rx1))" "$((err_tx2 - err_tx1))" "$err_rx2" "$err_tx2"
}

recommended_mss_for_mtu() {
    local mtu=$1

    if [[ "$mtu" =~ ^[0-9]+$ ]] && [ "$mtu" -gt 40 ]; then
        printf "%s" "$((mtu - 40))"
    fi
}

icmp_payload_for_mtu() {
    local mtu=$1

    if [[ "$mtu" =~ ^[0-9]+$ ]] && [ "$mtu" -gt 28 ]; then
        printf "%s" "$((mtu - 28))"
    fi
}

service_state() {
    local service=$1

    if has_systemd; then
        systemctl is-active "$service" 2>/dev/null || printf "unknown"
    else
        printf "systemd unavailable"
    fi
}

print_conntrack_summary() {
    local count
    local max
    local percent

    count=$(sysctl -q -n net.netfilter.nf_conntrack_count 2>/dev/null || true)
    max=$(sysctl -q -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
    if [ -n "$count" ] && [ -n "$max" ] && [ "$max" -gt 0 ]; then
        percent=$((count * 100 / max))
        echo "Conntrack: $count/$max (${percent}%)"
    else
        echo "Conntrack: counters unavailable"
    fi
}

wait_for_quit_key() {
    local seconds=${1:-1}
    local key
    local elapsed=0

    while [ "$elapsed" -lt "$seconds" ]; do
        if read -rsn1 -t 1 key; then
            case "$key" in
                q|Q)
                    return 0
                    ;;
            esac
        fi
        elapsed=$((elapsed + 1))
    done

    return 1
}

conntrack_table_file() {
    if [ -r /proc/net/nf_conntrack ]; then
        printf "/proc/net/nf_conntrack"
    elif [ -r /proc/net/ip_conntrack ]; then
        printf "/proc/net/ip_conntrack"
    fi
}

live_server_monitor() {
    local loops=${1:-0}
    local iteration=0
    local sample_seconds=2
    local eth_rx eth_tx eth_drop_rx eth_drop_tx eth_err_rx eth_err_tx
    local gre_rx gre_tx gre_drop_rx gre_drop_tx gre_err_rx gre_err_tx
    local stop_requested=0

    load_config || {
        read -p "Press Enter to continue..." _
        return 1
    }

    tput clear 2>/dev/null || clear

    while true; do
        iteration=$((iteration + 1))
        eth_rx=$(read_counter "$ETH_INTERFACE" rx_bytes)
        eth_tx=$(read_counter "$ETH_INTERFACE" tx_bytes)
        eth_drop_rx=$(read_counter "$ETH_INTERFACE" rx_dropped)
        eth_drop_tx=$(read_counter "$ETH_INTERFACE" tx_dropped)
        eth_err_rx=$(read_counter "$ETH_INTERFACE" rx_errors)
        eth_err_tx=$(read_counter "$ETH_INTERFACE" tx_errors)
        gre_rx=$(read_counter "$GRE_IF" rx_bytes)
        gre_tx=$(read_counter "$GRE_IF" tx_bytes)
        gre_drop_rx=$(read_counter "$GRE_IF" rx_dropped)
        gre_drop_tx=$(read_counter "$GRE_IF" tx_dropped)
        gre_err_rx=$(read_counter "$GRE_IF" rx_errors)
        gre_err_tx=$(read_counter "$GRE_IF" tx_errors)
        if wait_for_quit_key "$sample_seconds"; then
            stop_requested=1
        fi

        tput cup 0 0 2>/dev/null || clear
        tput ed 2>/dev/null || true
        echo "========================================"
        echo "          GREX Live Monitor             "
        echo "========================================"
        date
        echo "Refresh: $iteration  Interval: ${sample_seconds}s  Press q to return"
        echo
        echo "Load: $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo unknown)"
        if command -v free >/dev/null 2>&1; then
            free -h | awk 'NR==1 || NR==2 || NR==3 {print}'
        fi
        if command -v df >/dev/null 2>&1; then
            df -h / | awk 'NR==1 || NR==2 {print}'
        fi
        echo
        echo "Services:"
        echo "gre-tunnel: $(service_state gre-tunnel)"
        echo "dnsmasq:    $(service_state dnsmasq)"
        echo "fail2ban:   $(service_state fail2ban)"
        echo
        print_conntrack_summary
        echo
        echo "Network rates:"
        print_interface_rate_line "$ETH_INTERFACE" "$sample_seconds" "$eth_rx" "$eth_tx" "$eth_drop_rx" "$eth_drop_tx" "$eth_err_rx" "$eth_err_tx"
        print_interface_rate_line "$GRE_IF" "$sample_seconds" "$gre_rx" "$gre_tx" "$gre_drop_rx" "$gre_drop_tx" "$gre_err_rx" "$gre_err_tx"
        echo
        echo "Tunnel reachability:"
        if ping -c 1 -W 1 "$REMOTE_TUNNEL_IP" >/dev/null 2>&1; then
            echo "$REMOTE_TUNNEL_IP reachable"
        else
            echo "$REMOTE_TUNNEL_IP not reachable"
        fi

        if [ "$stop_requested" -eq 1 ]; then
            break
        fi
        if [ "$loops" -gt 0 ] && [ "$iteration" -ge "$loops" ]; then
            break
        fi
    done
}

firewall_counters() {
    load_config || return 1

    echo "=== GREX firewall counters ==="
    echo
    echo "FORWARD:"
    run_as_root iptables -L FORWARD -n -v 2>/dev/null | head -30 || true
    echo
    echo "GREX-FORWARD:"
    run_as_root iptables -L GREX-FORWARD -n -v 2>/dev/null || echo "GREX-FORWARD chain not found"
    echo
    echo "GREX-EGRESS:"
    run_as_root iptables -L GREX-EGRESS -n -v 2>/dev/null || echo "GREX-EGRESS chain not found"
    echo
    echo "GREX-INPUT:"
    run_as_root iptables -L GREX-INPUT -n -v 2>/dev/null || echo "GREX-INPUT chain not found"
    echo
    echo "NAT POSTROUTING:"
    run_as_root iptables -t nat -L POSTROUTING -n -v 2>/dev/null | grep -E 'MASQUERADE|Chain' || true
}

conntrack_monitor() {
    local table_file

    load_config || return 1

    print_conntrack_summary
    if command -v conntrack >/dev/null 2>&1; then
        echo
        run_as_root conntrack -S 2>/dev/null || true
    else
        table_file=$(conntrack_table_file)
        if [ -n "$table_file" ]; then
            echo
            echo "conntrack command not installed; showing basic counters from $table_file"
            awk '
                {
                    proto[$3] += 1
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^(ESTABLISHED|SYN_SENT|SYN_RECV|TIME_WAIT|CLOSE|CLOSE_WAIT|LAST_ACK|FIN_WAIT)$/) {
                            state[$i] += 1
                        }
                    }
                }
                END {
                    print "Protocols:"
                    for (p in proto) printf "  %s %d\n", p, proto[p]
                    print "States:"
                    for (s in state) printf "  %s %d\n", s, state[s]
                }
            ' "$table_file"
        else
            echo "conntrack command not installed and proc conntrack table is unavailable."
            echo "Install conntrack-tools for protocol counters."
        fi
    fi
}

mtu_mss_advisor() {
    local current_mtu
    local effective_mtu
    local recommended_mss
    local df_payload

    load_config || return 1

    current_mtu=$(ip link show dev "$GRE_IF" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") print $(i+1)}')
    effective_mtu=${current_mtu:-$GRE_MTU}
    recommended_mss=$(recommended_mss_for_mtu "$effective_mtu")
    df_payload=$(icmp_payload_for_mtu "$effective_mtu")

    echo "=== MTU/MSS Advisor ==="
    echo "GRE interface:       $GRE_IF"
    echo "Configured GRE MTU:  $GRE_MTU"
    echo "Current GRE MTU:     ${current_mtu:-unknown}"
    echo "MSS mode:            $MSS_MODE"
    echo "MSS value:           ${MSS_VALUE:-<blank>}"
    echo "Recommended MSS:     ${recommended_mss:-unknown}"
    echo "DF ping probe:       ping $REMOTE_TUNNEL_IP -M do -s ${df_payload:-unknown} -c 4"
    echo

    if [ "$MSS_MODE" = "fixed" ] && [[ "$MSS_VALUE" =~ ^[0-9]+$ ]] && [ -n "$recommended_mss" ] && [ "$MSS_VALUE" -gt "$recommended_mss" ]; then
        echo "Verdict: possible MSS/MTU mismatch"
        echo "Suggested: set MSS_VALUE to $recommended_mss or lower, then apply configuration."
    elif [ "$MSS_MODE" = "off" ]; then
        echo "Verdict: MSS handling is disabled"
        echo "Suggested: use MSS_MODE=fixed with MSS_VALUE=${recommended_mss:-1360}, or MSS_MODE=clamp."
    else
        echo "Verdict: current MTU/MSS settings look consistent."
    fi
    echo
    echo "Run the DF ping probe during low-risk hours. If it fails, lower GRE_MTU and MSS_VALUE together."
}

bandwidth_by_source() {
    local seconds
    local loops
    local iteration=0
    local tcpdump_filter

    load_config || return 1

    read -r -p "Sample duration in seconds [5]: " seconds
    seconds=${seconds:-5}
    if ! [[ "$seconds" =~ ^[0-9]+$ ]] || [ "$seconds" -lt 1 ] || [ "$seconds" -gt 60 ]; then
        echo "Duration must be between 1 and 60 seconds."
        return 1
    fi

    read -r -p "Refresh count (0 for until Ctrl+C) [10]: " loops
    loops=${loops:-10}
    if ! [[ "$loops" =~ ^[0-9]+$ ]] || [ "$loops" -gt 1000 ]; then
        echo "Refresh count must be a number between 0 and 1000."
        return 1
    fi

    tcpdump_filter=$(internal_source_filter)
    if [ -z "$tcpdump_filter" ]; then
        echo "Could not build tcpdump filter from INTERNAL_SUBNETS."
        return 1
    fi

    tput clear 2>/dev/null || clear

    while true; do
        iteration=$((iteration + 1))
        bandwidth_by_source_sample "$seconds" "$tcpdump_filter" "$iteration" || {
            if [ "$?" -eq 130 ]; then
                break
            fi
            return 1
        }
        if [ "$loops" -gt 0 ] && [ "$iteration" -ge "$loops" ]; then
            break
        fi
    done
}

internal_source_filter() {
    local subnet
    local filter=""

    IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
    for subnet in "${SUBNETS[@]}"; do
        subnet=$(trim "$subnet")
        [ -n "$subnet" ] || continue
        if [ -n "$filter" ]; then
            filter="$filter or "
        fi
        filter="${filter}src net $subnet"
    done

    printf "%s" "$filter"
}

bandwidth_bar() {
    local value=$1
    local max=$2
    local width=${3:-24}
    local filled=0
    local i

    if [ "$max" -gt 0 ]; then
        filled=$((value * width / max))
    fi
    [ "$filled" -gt "$width" ] && filled=$width
    for ((i = 0; i < width; i++)); do
        if [ "$i" -lt "$filled" ]; then
            printf "#"
        else
            printf "."
        fi
    done
}

bandwidth_by_source_sample() {
    local seconds=$1
    local tcpdump_filter=$2
    local iteration=$3
    local tmp_file
    local data_file
    local max_bytes
    local max_bps
    local tcpdump_pid
    local elapsed=0
    local key
    local stopped=0

    if ! command -v tcpdump >/dev/null 2>&1; then
        echo "tcpdump is required for bandwidth-by-source sampling."
        echo "Install tcpdump, then retry."
        return 1
    fi

    tmp_file=$(mktemp)
    set +e
    run_as_root tcpdump -l -ni "$GRE_IF" -q "ip and ($tcpdump_filter)" > "$tmp_file" 2>/dev/null &
    tcpdump_pid=$!
    while [ "$elapsed" -lt "$seconds" ]; do
        if read -rsn1 -t 1 key; then
            case "$key" in
                q|Q)
                    stopped=1
                    break
                    ;;
            esac
        fi
        if ! kill -0 "$tcpdump_pid" 2>/dev/null; then
            break
        fi
        elapsed=$((elapsed + 1))
    done
    kill "$tcpdump_pid" 2>/dev/null || true
    wait "$tcpdump_pid" 2>/dev/null || true
    set -e

    tput cup 0 0 2>/dev/null || clear
    tput ed 2>/dev/null || true
    echo "========================================"
    echo "       GREX Bandwidth by Source         "
    echo "========================================"
    date
    echo "Interface: $GRE_IF  Interval: ${seconds}s  Refresh: $iteration  Press q to return"
    echo "Filter: internal sources only"
    echo

    if [ "$stopped" -eq 1 ]; then
        rm -f "$tmp_file"
        return 130
    fi

    if [ ! -s "$tmp_file" ]; then
        echo "No IP packets observed during the sample window."
        rm -f "$tmp_file"
        return 0
    fi

    data_file=$(mktemp)
    awk '
        / IP / {
            for (i = 1; i <= NF; i++) {
                if ($i == "IP") {
                    src = $(i + 1)
                    dst = $(i + 3)
                    sub(/\.[0-9]+$/, "", src)
                    sub(/:$/, "", dst)
                    sub(/\.[0-9]+$/, "", dst)
                }
                if ($i == "length") {
                    bytes[src] += $(i + 1)
                    packets[src] += 1
                    sessions[src SUBSEP dst] = 1
                }
            }
        }
        END {
            for (key in sessions) {
                split(key, parts, SUBSEP)
                session_count[parts[1]] += 1
            }
            for (src in packets) {
                printf "%s %d %d %d\n", src, bytes[src], session_count[src], packets[src]
            }
        }
    ' "$tmp_file" | sort -k2,2nr | head -20 > "$data_file"

    max_bytes=$(awk 'NR == 1 {print $2}' "$data_file")
    max_bytes=${max_bytes:-0}
    max_bps=$((max_bytes * 8 / seconds))

    printf "%-18s %14s  %-24s %10s  %-12s %14s  %-24s\n" "Source" "Bytes" "Bytes bar" "Sessions" "Packets" "Bandwidth" "Bandwidth bar"
    printf "%-18s %14s  %-24s %10s  %-12s %14s  %-24s\n" "------" "-----" "---------" "--------" "-------" "---------" "-------------"
    while read -r src bytes sessions packets; do
        bps=$((bytes * 8 / seconds))
        mbps=$(awk "BEGIN {printf \"%.2f\", $bps/1000000}")
        mib=$(awk "BEGIN {printf \"%.2f MB\", $bytes/1048576}")
        bytes_bar=$(bandwidth_bar "$bytes" "$max_bytes" 24)
        bps_bar=$(bandwidth_bar "$bps" "$max_bps" 24)
        printf "%-18s %14s  %-24s %10s  %-12s %11s Mbps  %-24s\n" "$src" "$mib" "$bytes_bar" "$sessions" "$packets" "$mbps" "$bps_bar"
    done < "$data_file"
    rm -f "$tmp_file" "$data_file"
}

diagnostics_menu() {
    while true; do
        clear
        echo "========================================"
        echo "       GREX Diagnostics & Tuning        "
        echo "========================================"
        echo "1) Live Server Monitor"
        echo "2) Bandwidth by Source"
        echo "3) MTU/MSS Advisor"
        echo "4) Conntrack Monitor"
        echo "5) Firewall Counters"
        echo "0) Back"
        echo
        read -r -p "Choose an option [0-5]: " diag_choice
        case "$diag_choice" in
            1) run_live_monitor_prompt ;;
            2) bandwidth_by_source; read -p "Press Enter to continue..." _ ;;
            3) mtu_mss_advisor; read -p "Press Enter to continue..." _ ;;
            4) conntrack_monitor; read -p "Press Enter to continue..." _ ;;
            5) firewall_counters; read -p "Press Enter to continue..." _ ;;
            0) return 0 ;;
            *) echo "Invalid selection."; read -p "Press Enter to continue..." _ ;;
        esac
    done
}

run_live_monitor_prompt() {
    local loops

    read -r -p "Refresh count (0 for until Ctrl+C) [10]: " loops
    loops=${loops:-10}
    if ! [[ "$loops" =~ ^[0-9]+$ ]] || [ "$loops" -gt 1000 ]; then
        echo "Refresh count must be a number between 0 and 1000."
        read -p "Press Enter to continue..." _
        return 1
    fi
    live_server_monitor "$loops"
    read -p "Press Enter to continue..." _
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
    local first_render=1

    while true; do
        clear
        echo "========================================"
        echo "          GREX Egress Gateway           "
        echo "========================================"
        if [ "$first_render" -eq 1 ]; then
            version_summary fresh
            first_render=0
        else
            version_summary
        fi
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
        echo "10) Diagnostics & Tuning"
        echo "0) Exit"
        echo
        read -p "Choose an option [0-10]: " choice
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
            10)
                diagnostics_menu
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
        version_summary fresh
        ;;
    check-upgrade)
        version_summary fresh
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
    diagnostics)
        diagnostics_menu
        ;;
    monitor)
        live_server_monitor
        ;;
    bandwidth)
        bandwidth_by_source
        ;;
    mtu-advisor)
        mtu_mss_advisor
        ;;
    conntrack)
        conntrack_monitor
        ;;
    firewall-counters)
        firewall_counters
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
