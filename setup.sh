#!/bin/bash

# Controlled Egress GRE Tunnel Setup Wizard
# This script configures the GRE tunnel on the VPS side with a wizard interface

set -e

if [ "$EUID" -ne 0 ]; then
    echo "setup.sh must be run as root. Use: sudo bash setup.sh" >&2
    exit 1
fi

echo "🟣 Controlled Egress GRE Tunnel Setup Wizard"
echo "============================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/gre-tunnel.conf"
BACKUP_DIR="/var/backups/grex"
INPUT_DEVICE="/dev/stdin"
if [ ! -t 0 ] && [ -r /dev/tty ]; then
    INPUT_DEVICE="/dev/tty"
fi

# Function to prompt for input
prompt() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    local input
    read -r -p "$prompt_text [$default_value]: " input < "$INPUT_DEVICE"
    printf -v "$var_name" "%s" "${input:-$default_value}"
}

confirm() {
    local prompt_text=$1
    local default_value=${2:-no}
    local input

    read -r -p "$prompt_text [$default_value]: " input < "$INPUT_DEVICE"
    [[ "${input:-$default_value}" =~ ^(yes|y|Y)$ ]]
}

secure_config_file() {
    if [ -f "$CONFIG_FILE" ]; then
        chown root:root "$CONFIG_FILE" 2>/dev/null || true
        chmod 600 "$CONFIG_FILE"
    fi
}

backup_config() {
    local reason=${1:-setup}
    local timestamp
    local backup_file

    if [ ! -f "$CONFIG_FILE" ]; then
        return 0
    fi

    timestamp=$(date +%Y%m%d-%H%M%S)
    backup_file="$BACKUP_DIR/gre-tunnel.conf.$timestamp.$reason.bak"
    mkdir -p "$BACKUP_DIR"
    cp -p "$CONFIG_FILE" "$backup_file"
    chmod 600 "$backup_file"
    echo "Existing configuration backed up to $backup_file"
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

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
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

    if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]] && [ -n "$DNS_SERVERS" ]; then
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

    if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
        [ -n "$ADMIN_IPS" ] && [ "$ADMIN_IPS" != "x.x.x.x" ] || { echo "ADMIN_IPS must be configured when hardening is enabled." >&2; return 1; }
        validate_ip_list "$ADMIN_IPS" "ADMIN_IPS" || return 1
    fi

    if [[ "$ENABLE_DROP_LOGGING" =~ ^(yes|y|Y)$ ]]; then
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
    local detected_admin_ip=${1:-}

    if ! [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
        return 0
    fi

    if [ -z "$detected_admin_ip" ]; then
        echo "WARNING: Could not detect your current SSH source IP." >&2
        confirm "Continue with firewall hardening anyway? (yes/no)" "no"
        return $?
    fi

    if ! ip_in_list "$detected_admin_ip" "$ADMIN_IPS"; then
        echo "WARNING: Your current SSH source IP ($detected_admin_ip) is not in ADMIN_IPS: $ADMIN_IPS" >&2
        confirm "This can lock you out. Continue anyway? (yes/no)" "no"
        return $?
    fi
}

detect_public_ip() {
    local endpoint
    local ip
    local endpoints=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://checkip.amazonaws.com"
    )

    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi

    for endpoint in "${endpoints[@]}"; do
        ip=$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
        if is_ipv4 "$ip"; then
            printf "%s" "$ip"
            return 0
        fi
    done

    return 1
}

detect_default_interface() {
    local iface

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
        if [ -n "$iface" ]; then
            printf "%s" "$iface"
            return 0
        fi
    fi

    printf "eth0"
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

install_dependencies() {
    local packages

    if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
        packages=(curl iproute2 iptables conntrack dnsmasq)
    else
        packages=(curl iproute2 iptables conntrack)
    fi

    if [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
        packages+=(fail2ban)
    fi

    if command -v apt-get >/dev/null 2>&1; then
        local policy_file="/usr/sbin/policy-rc.d"
        local created_policy=0
        local status=0

        if [ ! -e "$policy_file" ]; then
            printf '#!/bin/sh\nexit 101\n' > "$policy_file"
            chmod +x "$policy_file"
            created_policy=1
        fi

        set +e
        apt-get update
        status=$?
        if [ "$status" -eq 0 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            status=$?
        fi
        set -e

        if [ "$created_policy" -eq 1 ]; then
            rm -f "$policy_file"
        fi

        return "$status"
    elif command -v dnf >/dev/null 2>&1; then
        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            dnf install -y curl iproute iptables conntrack-tools dnsmasq
        else
            dnf install -y curl iproute iptables conntrack-tools
        fi
        dnf install -y iptables-services 2>/dev/null || true
        if [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
            dnf install -y epel-release 2>/dev/null || true
            dnf install -y fail2ban
        fi
    elif command -v yum >/dev/null 2>&1; then
        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            yum install -y curl iproute iptables iptables-services conntrack-tools dnsmasq
        else
            yum install -y curl iproute iptables iptables-services conntrack-tools
        fi
        if [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
            yum install -y epel-release 2>/dev/null || true
            yum install -y fail2ban
        fi
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install curl iproute2 iptables conntrack-tools "${packages[@]:4}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed curl iproute2 iptables conntrack-tools "${packages[@]:4}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash curl iproute2 iptables conntrack-tools "${packages[@]:4}"
    else
        echo "Unsupported Linux distribution: no known package manager was found."
        echo "Install curl, iproute2/iproute, iptables, conntrack-tools, and optionally dnsmasq manually, then run 'sudo grex configure' again."
        exit 1
    fi
}

configure_fail2ban() {
    if ! [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
        rm -f /etc/fail2ban/jail.d/grex-sshd.local
        if has_systemd && systemctl list-unit-files | grep -q '^fail2ban'; then
            systemctl restart fail2ban 2>/dev/null || true
        fi
        return 0
    fi

    if ! command -v fail2ban-server >/dev/null 2>&1; then
        echo "fail2ban is enabled but fail2ban-server was not found after dependency installation."
        return 1
    fi

    mkdir -p /etc/fail2ban/jail.d

    local ignore_ips
    ignore_ips="127.0.0.1/8 ::1"
    if [ -n "${ADMIN_IPS:-}" ]; then
        ignore_ips="$ignore_ips ${ADMIN_IPS//,/ }"
    fi

    cat > /etc/fail2ban/jail.d/grex-sshd.local << EOF
[sshd]
enabled = $FAIL2BAN_SSHD_ENABLED
port = $FAIL2BAN_SSHD_PORT
maxretry = $FAIL2BAN_SSHD_MAXRETRY
findtime = $FAIL2BAN_SSHD_FINDTIME
bantime = $FAIL2BAN_SSHD_BANTIME
ignoreip = $ignore_ips
EOF

    if has_systemd; then
        systemctl enable --now fail2ban
        systemctl restart fail2ban
    elif command -v service >/dev/null 2>&1; then
        service fail2ban restart 2>/dev/null || service fail2ban start 2>/dev/null || true
    fi
}

configure_sysctl_hardening() {
    if [ -x "$SCRIPT_DIR/gre-sysctl.sh" ]; then
        "$SCRIPT_DIR/gre-sysctl.sh"
    elif [ -x /srv/GREX/gre-sysctl.sh ]; then
        /srv/GREX/gre-sysctl.sh
    else
        echo "gre-sysctl.sh was not found; skipping sysctl hardening."
        echo "Run 'sudo grex configure' again after installing the latest GREX files."
    fi
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

apply_configuration() {
    echo "Applying GREX configuration..."
    configure_sysctl_hardening

    if has_systemd && [ -f /etc/systemd/system/gre-tunnel.service ]; then
        systemctl daemon-reload
        systemctl enable gre-tunnel
        systemctl restart gre-tunnel

        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            systemctl enable --now dnsmasq
        else
            systemctl stop dnsmasq 2>/dev/null || true
            systemctl disable dnsmasq 2>/dev/null || true
        fi
        configure_fail2ban
    elif [ -x "$SCRIPT_DIR/gre-tunnel.sh" ]; then
        "$SCRIPT_DIR/gre-tunnel.sh"

        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]] && command -v dnsmasq >/dev/null 2>&1; then
            if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -x dnsmasq >/dev/null 2>&1; then
                dnsmasq --conf-file=/etc/dnsmasq.d/tunnel.conf --pid-file=/run/grex-dnsmasq.pid
            fi
        fi
        configure_fail2ban
    else
        echo "Could not apply automatically because gre-tunnel.sh was not found."
        echo "Run 'sudo grex activate' after installation."
        return 0
    fi
}

# Collect configuration
echo "Please provide the following configuration details:"
echo

DETECTED_VPS_PUBLIC_IP=$(detect_public_ip || true)
DETECTED_ETH_INTERFACE=$(detect_default_interface)
DETECTED_ADMIN_IP=$(detect_admin_ip || true)
prompt VPS_PUBLIC_IP "VPS Public IP" "${DETECTED_VPS_PUBLIC_IP:-130.x.x.x}"
prompt REMOTE_PUBLIC_IP "Remote gateway public IP" "x.x.x.x"
prompt INTERNAL_SUBNETS "Internal subnets (comma-separated)" "192.168.0.0/16,172.16.0.0/12"
prompt ENABLE_DNSMASQ "Enable local DNS server with dnsmasq? (yes/no)" "yes"
if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    prompt DNS_SERVERS "Upstream DNS servers (comma-separated)" "1.1.1.1,8.8.8.8"
else
    DNS_SERVERS=""
fi
prompt ETH_INTERFACE "Ethernet interface" "$DETECTED_ETH_INTERFACE"
prompt VPS_TUNNEL_IP "VPS tunnel IP with mask" "10.10.10.2/30"
prompt REMOTE_TUNNEL_IP "Remote gateway tunnel IP" "10.10.10.1"
prompt GRE_IF "GRE interface" "grex"
prompt GRE_KEY "GRE key (blank for no key)" ""
prompt GRE_MTU "GRE interface MTU" "1400"
prompt MSS_MODE "TCP MSS mode (fixed/clamp/off)" "fixed"
if [ "$MSS_MODE" = "fixed" ]; then
    prompt MSS_VALUE "TCP MSS value" "1360"
else
    MSS_VALUE=""
fi
prompt ENABLE_HARDENING "Enable VPS firewall hardening? (yes/no)" "yes"
if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    prompt ADMIN_IPS "Admin SSH source IPs/CIDRs (comma-separated)" "${DETECTED_ADMIN_IP:-x.x.x.x}"
    prompt ALLOW_ICMP "Allow ICMP/ping to VPS? (yes/no)" "yes"
else
    ADMIN_IPS=""
    ALLOW_ICMP="yes"
fi
prompt ENABLE_EGRESS_FILTERING "Enable optional egress filtering? (yes/no)" "no"
if [[ "$ENABLE_EGRESS_FILTERING" =~ ^(yes|y|Y)$ ]]; then
    prompt BLOCK_SMTP_OUT "Block outbound SMTP port 25? (yes/no)" "yes"
    prompt BLOCK_PRIVATE_DESTINATIONS "Block private/reserved destination ranges? (yes/no)" "yes"
else
    BLOCK_SMTP_OUT=yes
    BLOCK_PRIVATE_DESTINATIONS=yes
fi
prompt ENABLE_DROP_LOGGING "Enable rate-limited firewall drop logging? (yes/no)" "no"
if [[ "$ENABLE_DROP_LOGGING" =~ ^(yes|y|Y)$ ]]; then
    prompt DROP_LOG_RATE "Firewall drop log rate limit" "3/min"
    prompt DROP_LOG_BURST "Firewall drop log burst" "10"
else
    DROP_LOG_RATE=3/min
    DROP_LOG_BURST=10
fi
prompt ENABLE_SYSCTL_HARDENING "Enable kernel/network sysctl hardening? (yes/no)" "yes"
if [[ "$ENABLE_SYSCTL_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    prompt SYSCTL_PROFILE "Sysctl profile (safe/strict/custom)" "safe"
    case "$SYSCTL_PROFILE" in
        strict)
            RP_FILTER=1
            TCP_TIMESTAMPS=1
            LOG_MARTIANS=yes
            ;;
        custom)
            prompt RP_FILTER "rp_filter value (2 loose, 1 strict, 0 off)" "2"
            prompt TCP_TIMESTAMPS "TCP timestamps (1 on, 0 off)" "1"
            prompt LOG_MARTIANS "Log martian packets? (yes/no)" "yes"
            ;;
        *)
            SYSCTL_PROFILE=safe
            RP_FILTER=2
            TCP_TIMESTAMPS=1
            LOG_MARTIANS=yes
            ;;
    esac
    prompt DISABLE_IPV6 "Disable IPv6? (yes/no)" "no"
    prompt NF_CONNTRACK_MAX "nf_conntrack_max" "262144"
    prompt CONNTRACK_WARN_PERCENT "Conntrack usage warning percent" "70"
    prompt CONNTRACK_CRIT_PERCENT "Conntrack usage critical percent" "90"
else
    SYSCTL_PROFILE=off
    RP_FILTER=2
    TCP_TIMESTAMPS=1
    LOG_MARTIANS=no
    DISABLE_IPV6=no
    NF_CONNTRACK_MAX=262144
    CONNTRACK_WARN_PERCENT=70
    CONNTRACK_CRIT_PERCENT=90
fi
prompt ENABLE_FAIL2BAN "Enable fail2ban for SSH? (yes/no)" "yes"
if [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
    prompt FAIL2BAN_SSHD_ENABLED "fail2ban sshd enabled" "true"
    prompt FAIL2BAN_SSHD_PORT "fail2ban sshd port" "22"
    prompt FAIL2BAN_SSHD_MAXRETRY "fail2ban sshd maxretry" "3"
    prompt FAIL2BAN_SSHD_FINDTIME "fail2ban sshd findtime" "10m"
    prompt FAIL2BAN_SSHD_BANTIME "fail2ban sshd bantime" "1h"
else
    FAIL2BAN_SSHD_ENABLED=false
    FAIL2BAN_SSHD_PORT=22
    FAIL2BAN_SSHD_MAXRETRY=3
    FAIL2BAN_SSHD_FINDTIME=10m
    FAIL2BAN_SSHD_BANTIME=1h
fi

validate_configuration
confirm_ssh_lockout_risk "$DETECTED_ADMIN_IP"

# Create config file
backup_config "pre-setup"
cat > "$CONFIG_FILE" << EOF
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

echo "Configuration saved to $CONFIG_FILE"

# Install dependencies
echo "Installing dependencies..."
install_dependencies

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    # Configure dnsmasq
    echo "Configuring DNS..."
    systemctl stop dnsmasq 2>/dev/null || true
    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/tunnel.conf << EOF
bind-dynamic
no-resolv
EOF

    listen_ip=$(echo "$VPS_TUNNEL_IP" | cut -d'/' -f1)
    echo "interface=$GRE_IF" >> /etc/dnsmasq.d/tunnel.conf
    echo "listen-address=$listen_ip" >> /etc/dnsmasq.d/tunnel.conf

    for dns in $(echo $DNS_SERVERS | tr ',' ' '); do
        echo "server=$dns" >> /etc/dnsmasq.d/tunnel.conf
    done
fi

apply_configuration

echo "Setup complete. GREX configuration has been applied."
