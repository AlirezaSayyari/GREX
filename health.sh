#!/bin/bash

# Health Check Script

CONFIG_FILE="/etc/gre-tunnel.conf"
BACKUP_DIR="/var/backups/grex"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found."
    exit 1
fi

source "$CONFIG_FILE"

STATUS="OK"
ISSUES=()
NOTES=()
MISSING_TUNNELS=0

set_status() {
    local new_status=$1

    if [ "$new_status" = "CRITICAL" ]; then
        STATUS="CRITICAL"
    elif [ "$new_status" = "WARNING" ] && [ "$STATUS" != "CRITICAL" ]; then
        STATUS="WARNING"
    fi
}

get_config_value() {
    local var_name=$1
    printf "%s" "${!var_name}"
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

validate_ip_list_health() {
    local value=$1
    local label=$2
    local item

    IFS=',' read -ra ITEMS <<< "$value"
    for item in "${ITEMS[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || continue
        if ! is_ipv4_or_cidr "$item"; then
            set_status "CRITICAL"
            ISSUES+=("$label contains invalid IP/CIDR: $item")
        fi
    done
}

check_numeric_range_health() {
    local value=$1
    local label=$2
    local min=$3
    local max=$4

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        set_status "CRITICAL"
        ISSUES+=("$label must be a number between $min and $max")
    fi
}

iptables_backend() {
    local command_name=${1:-iptables}
    local version

    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf "missing"
        return 0
    fi

    version=$("$command_name" --version 2>/dev/null || true)
    case "$version" in
        *nf_tables*) printf "nft" ;;
        *legacy*) printf "legacy" ;;
        *) printf "unknown" ;;
    esac
}

iptables_rules_present() {
    local command_name=$1

    command -v "$command_name" >/dev/null 2>&1 || return 1
    "$command_name" -S 2>/dev/null | grep -q 'GREX-' && return 0
    "$command_name" -t nat -S 2>/dev/null | grep -q 'MASQUERADE' && return 0
    "$command_name" -t mangle -S 2>/dev/null | grep -q 'GREX-' && return 0
    return 1
}

normalize_config() {
    local legacy_public_var
    local legacy_tunnel_var
    local legacy_tunnel_1_var

    legacy_public_var="FO""RTI_PUBLIC_IP"
    legacy_tunnel_var="FO""RTI_TUNNEL_IP"
    legacy_tunnel_1_var="TUNNEL_1_FO""RTI_IP"

    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    REMOTE_PUBLIC_IP=${REMOTE_PUBLIC_IP:-${!legacy_public_var:-}}
    REMOTE_TUNNEL_IP=${REMOTE_TUNNEL_IP:-${!legacy_tunnel_var:-${!legacy_tunnel_1_var:-}}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-grex}}
    GRE_KEY=${GRE_KEY:-}
    GRE_MTU=${GRE_MTU:-1476}
    MSS_MODE=${MSS_MODE:-clamp}
    MSS_VALUE=${MSS_VALUE:-}
    ENABLE_HARDENING=${ENABLE_HARDENING:-no}
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    ENABLE_EGRESS_FILTERING=${ENABLE_EGRESS_FILTERING:-no}
    BLOCK_SMTP_OUT=${BLOCK_SMTP_OUT:-yes}
    BLOCK_PRIVATE_DESTINATIONS=${BLOCK_PRIVATE_DESTINATIONS:-yes}
    ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-no}
    ENABLE_SYSCTL_HARDENING=${ENABLE_SYSCTL_HARDENING:-yes}
    RP_FILTER=${RP_FILTER:-2}
    TCP_TIMESTAMPS=${TCP_TIMESTAMPS:-1}
    NF_CONNTRACK_MAX=${NF_CONNTRACK_MAX:-262144}
}

normalize_config

CONFIG_MODE=$(stat -c %a "$CONFIG_FILE" 2>/dev/null || true)
CONFIG_OWNER=$(stat -c %U:%G "$CONFIG_FILE" 2>/dev/null || true)
if [ "$CONFIG_MODE" != "600" ]; then
    set_status "WARNING"
    ISSUES+=("$CONFIG_FILE permissions are $CONFIG_MODE, expected 600")
fi

if [ -n "$CONFIG_OWNER" ] && [ "$CONFIG_OWNER" != "root:root" ]; then
    set_status "WARNING"
    ISSUES+=("$CONFIG_FILE owner is $CONFIG_OWNER, expected root:root")
fi

LATEST_BACKUP=$(ls -1t "$BACKUP_DIR"/gre-tunnel.conf.*.bak 2>/dev/null | head -n 1 || true)
if [ -n "$LATEST_BACKUP" ]; then
    NOTES+=("Latest config backup: $LATEST_BACKUP")
else
    NOTES+=("No config backup found in $BACKUP_DIR yet")
fi

ACTIVE_IPTABLES_BACKEND=$(iptables_backend iptables)
LEGACY_BACKEND=$(iptables_backend iptables-legacy)
NFT_BACKEND=$(iptables_backend iptables-nft)
NOTES+=("iptables backend: iptables=$ACTIVE_IPTABLES_BACKEND, iptables-legacy=$LEGACY_BACKEND, iptables-nft=$NFT_BACKEND")

LEGACY_RULES=0
NFT_RULES=0
iptables_rules_present iptables-legacy && LEGACY_RULES=1
iptables_rules_present iptables-nft && NFT_RULES=1

if [ "$LEGACY_RULES" -eq 1 ] && [ "$NFT_RULES" -eq 1 ]; then
    set_status "WARNING"
    ISSUES+=("Both iptables-legacy and iptables-nft appear to contain GREX/NAT rules; this mixed backend state can make health checks misleading")
elif [ "$ACTIVE_IPTABLES_BACKEND" = "nft" ] && [ "$LEGACY_RULES" -eq 1 ]; then
    set_status "WARNING"
    ISSUES+=("Active iptables command uses nft, but legacy rules are present; remove legacy rules or switch consistently")
elif [ "$ACTIVE_IPTABLES_BACKEND" = "legacy" ] && [ "$NFT_RULES" -eq 1 ]; then
    set_status "WARNING"
    ISSUES+=("Active iptables command uses legacy, but nft rules are present; remove nft rules or switch consistently")
fi

[ -n "${VPS_PUBLIC_IP:-}" ] || { set_status "CRITICAL"; ISSUES+=("VPS_PUBLIC_IP is required"); }
[ -n "${REMOTE_PUBLIC_IP:-}" ] || { set_status "CRITICAL"; ISSUES+=("REMOTE_PUBLIC_IP is required"); }
[ -n "${INTERNAL_SUBNETS:-}" ] || { set_status "CRITICAL"; ISSUES+=("INTERNAL_SUBNETS is required"); }
[ -n "${ETH_INTERFACE:-}" ] || { set_status "CRITICAL"; ISSUES+=("ETH_INTERFACE is required"); }
[ -n "${VPS_TUNNEL_IP:-}" ] || { set_status "CRITICAL"; ISSUES+=("VPS_TUNNEL_IP is required"); }
[ -n "${REMOTE_TUNNEL_IP:-}" ] || { set_status "CRITICAL"; ISSUES+=("REMOTE_TUNNEL_IP is required"); }
[ -n "${GRE_IF:-}" ] || { set_status "CRITICAL"; ISSUES+=("GRE_IF is required"); }
is_ipv4 "$VPS_PUBLIC_IP" || { set_status "CRITICAL"; ISSUES+=("VPS_PUBLIC_IP is not a valid IPv4 address"); }
is_ipv4 "$REMOTE_PUBLIC_IP" || { set_status "CRITICAL"; ISSUES+=("REMOTE_PUBLIC_IP is not a valid IPv4 address"); }
is_ipv4_cidr "$VPS_TUNNEL_IP" || { set_status "CRITICAL"; ISSUES+=("VPS_TUNNEL_IP must be IPv4 CIDR, for example 10.10.10.2/30"); }
is_ipv4 "$REMOTE_TUNNEL_IP" || { set_status "CRITICAL"; ISSUES+=("REMOTE_TUNNEL_IP is not a valid IPv4 address"); }
validate_ip_list_health "$INTERNAL_SUBNETS" "INTERNAL_SUBNETS"
if [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]] && [ -n "${DNS_SERVERS:-}" ]; then
    validate_ip_list_health "$DNS_SERVERS" "DNS_SERVERS"
fi
if ! [[ "$GRE_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
    set_status "CRITICAL"
    ISSUES+=("GRE_IF has invalid characters or is longer than 15 characters")
fi
check_numeric_range_health "$GRE_MTU" "GRE_MTU" 576 9000
case "$MSS_MODE" in fixed|clamp|off) ;; *) set_status "CRITICAL"; ISSUES+=("MSS_MODE must be fixed, clamp, or off") ;; esac
if [ "$MSS_MODE" = "fixed" ]; then
    check_numeric_range_health "$MSS_VALUE" "MSS_VALUE" 536 8960
fi
if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    validate_ip_list_health "$ADMIN_IPS" "ADMIN_IPS"
fi
check_numeric_range_health "$RP_FILTER" "RP_FILTER" 0 2
check_numeric_range_health "$TCP_TIMESTAMPS" "TCP_TIMESTAMPS" 0 1
check_numeric_range_health "$NF_CONNTRACK_MAX" "NF_CONNTRACK_MAX" 1 999999999

sysctl_value() {
    sysctl -q -n "$1" 2>/dev/null || true
}

check_sysctl_value() {
    local key=$1
    local expected=$2
    local actual

    actual=$(sysctl_value "$key")
    if [ -z "$actual" ]; then
        NOTES+=("Sysctl $key is not available on this kernel")
        return 0
    fi

    if [ "$actual" != "$expected" ]; then
        set_status "WARNING"
        ISSUES+=("Sysctl $key is $actual, expected $expected")
    fi
}

# Check if tunnel interface exists and is administratively up
if [ -z "$GRE_IF" ]; then
    set_status "CRITICAL"
    ISSUES+=("GRE interface is not configured")
elif ! ip link show "$GRE_IF" &>/dev/null; then
    set_status "CRITICAL"
    ISSUES+=("Tunnel interface $GRE_IF does not exist")
    MISSING_TUNNELS=1
elif ! ip link show dev "$GRE_IF" 2>/dev/null | grep -q "<[^>]*UP"; then
    set_status "CRITICAL"
    ISSUES+=("Tunnel interface $GRE_IF is not UP")
fi

CURRENT_MTU=$(ip link show dev "$GRE_IF" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") print $(i+1)}')
if [ -n "$CURRENT_MTU" ] && [ "$CURRENT_MTU" != "$GRE_MTU" ]; then
    set_status "WARNING"
    ISSUES+=("Tunnel interface $GRE_IF MTU is $CURRENT_MTU, expected $GRE_MTU")
fi

# Check routes
ROUTE_COUNT=$(ip route show | grep -c "$GRE_IF" || true)

if [ "$ROUTE_COUNT" -eq 0 ]; then
    set_status "WARNING"
    ISSUES+=("No routes configured via tunnel")
fi

# Check NAT rules
NAT_MISSING=0
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    subnet="${subnet#"${subnet%%[![:space:]]*}"}"
    subnet="${subnet%"${subnet##*[![:space:]]}"}"
    [ -n "$subnet" ] || continue
    if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$ETH_INTERFACE" -j MASQUERADE 2>/dev/null; then
        NAT_MISSING=1
        ISSUES+=("Missing NAT rule for $subnet via $ETH_INTERFACE")
    fi
done

if [ "$NAT_MISSING" -eq 1 ]; then
    set_status "WARNING"
fi

# Check GRE anti-spoofing forward rules
FORWARD_ALLOW_MISSING=0
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    subnet=$(trim "$subnet")
    [ -n "$subnet" ] || continue
    if ! iptables -C GREX-FORWARD -i "$GRE_IF" -o "$ETH_INTERFACE" -s "$subnet" -j GREX-EGRESS 2>/dev/null; then
        FORWARD_ALLOW_MISSING=1
        ISSUES+=("Missing anti-spoofing egress rule for $subnet from $GRE_IF to $ETH_INTERFACE")
    fi
done

if [ "$FORWARD_ALLOW_MISSING" -eq 1 ]; then
    set_status "WARNING"
fi

if ! iptables -C GREX-FORWARD -i "$GRE_IF" -o "$ETH_INTERFACE" -j DROP 2>/dev/null; then
    set_status "WARNING"
    ISSUES+=("Missing anti-spoofing drop rule for unexpected sources from $GRE_IF to $ETH_INTERFACE")
fi

if [[ "$ENABLE_EGRESS_FILTERING" =~ ^(yes|y|Y)$ ]]; then
    if ! iptables -L GREX-EGRESS -n >/dev/null 2>&1; then
        set_status "WARNING"
        ISSUES+=("Egress filtering is enabled but GREX-EGRESS chain was not found")
    fi

    if [[ "$BLOCK_SMTP_OUT" =~ ^(yes|y|Y)$ ]] &&
       ! iptables -C GREX-EGRESS -p tcp --dport 25 -j DROP 2>/dev/null; then
        set_status "WARNING"
        ISSUES+=("Egress filtering is enabled but outbound SMTP port 25 is not blocked")
    fi

    if [[ "$BLOCK_PRIVATE_DESTINATIONS" =~ ^(yes|y|Y)$ ]]; then
        for dst in \
            0.0.0.0/8 \
            10.0.0.0/8 \
            100.64.0.0/10 \
            127.0.0.0/8 \
            169.254.0.0/16 \
            172.16.0.0/12 \
            192.168.0.0/16 \
            198.18.0.0/15 \
            224.0.0.0/4 \
            240.0.0.0/4; do
            if ! iptables -C GREX-EGRESS -d "$dst" -j DROP 2>/dev/null; then
                set_status "WARNING"
                ISSUES+=("Egress filtering is enabled but private destination $dst is not blocked")
            fi
        done
    fi
fi

# Check firewall hardening state
if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    if [ -z "$ADMIN_IPS" ] || [ "$ADMIN_IPS" = "x.x.x.x" ]; then
        set_status "CRITICAL"
        ISSUES+=("Hardening is enabled but ADMIN_IPS is not configured")
    fi
    if ! iptables -C INPUT -j GREX-INPUT 2>/dev/null; then
        set_status "WARNING"
        ISSUES+=("Hardening is enabled but GREX-INPUT is not attached to INPUT")
    fi
    if [ "$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/ {print $3}')" != "DROP" ]; then
        set_status "WARNING"
        ISSUES+=("Hardening is enabled but INPUT policy is not DROP")
    fi
    if [ "$(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/ {print $3}')" != "DROP" ]; then
        set_status "WARNING"
        ISSUES+=("Hardening is enabled but FORWARD policy is not DROP")
    fi
fi

if [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
    if [ ! -f /etc/fail2ban/jail.d/grex-sshd.local ]; then
        set_status "WARNING"
        ISSUES+=("fail2ban is enabled but /etc/fail2ban/jail.d/grex-sshd.local was not found")
    fi

    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if ! systemctl is-active --quiet fail2ban; then
            set_status "WARNING"
            ISSUES+=("fail2ban is enabled but service is not running")
        fi
    fi
fi

if [[ "$ENABLE_SYSCTL_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    if [ ! -f /etc/sysctl.d/99-grex-hardening.conf ]; then
        set_status "WARNING"
        ISSUES+=("Sysctl hardening is enabled but /etc/sysctl.d/99-grex-hardening.conf was not found")
    fi

    check_sysctl_value net.ipv4.ip_forward 1
    check_sysctl_value net.ipv4.conf.all.rp_filter "$RP_FILTER"
    check_sysctl_value net.ipv4.conf.default.rp_filter "$RP_FILTER"
    check_sysctl_value net.ipv4.tcp_timestamps "$TCP_TIMESTAMPS"

    current_conntrack_max=$(sysctl_value net.netfilter.nf_conntrack_max)
    if [ -n "$current_conntrack_max" ] && [ -n "$NF_CONNTRACK_MAX" ] && [ "$current_conntrack_max" -lt "$NF_CONNTRACK_MAX" ]; then
        set_status "WARNING"
        ISSUES+=("Sysctl net.netfilter.nf_conntrack_max is $current_conntrack_max, expected at least $NF_CONNTRACK_MAX")
    fi
fi

if [ "$MSS_MODE" = "fixed" ]; then
    if ! iptables -t mangle -S GREX-MANGLE 2>/dev/null | grep -q -- "--set-mss $MSS_VALUE"; then
        set_status "WARNING"
        ISSUES+=("MSS_MODE=fixed but GREX-MANGLE does not set MSS to $MSS_VALUE")
    fi
elif [ "$MSS_MODE" = "clamp" ]; then
    if ! iptables -t mangle -S GREX-MANGLE 2>/dev/null | grep -q -- "--clamp-mss-to-pmtu"; then
        set_status "WARNING"
        ISSUES+=("MSS_MODE=clamp but GREX-MANGLE does not clamp MSS to PMTU")
    fi
fi

# Check remote public endpoint reachability separately from tunnel reachability.
if [ -n "${REMOTE_PUBLIC_IP:-}" ]; then
    if ping -c 1 -W 2 "$REMOTE_PUBLIC_IP" &>/dev/null; then
        NOTES+=("Remote gateway public IP $REMOTE_PUBLIC_IP responds to ICMP; this does not prove the GRE tunnel is up")
    else
        NOTES+=("Remote gateway public IP $REMOTE_PUBLIC_IP did not respond to ICMP; GRE may still work if ICMP is blocked")
    fi
fi

if [ -n "$GRE_KEY" ]; then
    NOTES+=("GRE key is set to $GRE_KEY; the remote GRE endpoint must use the same key")
else
    NOTES+=("GRE key is disabled; the remote GRE endpoint should not require a key")
fi

# Check connectivity
if [ -z "$REMOTE_TUNNEL_IP" ]; then
    set_status "CRITICAL"
    ISSUES+=("Remote gateway tunnel IP is not configured")
elif ! ping -c 1 -W 2 "$REMOTE_TUNNEL_IP" &>/dev/null; then
    set_status "CRITICAL"
    ISSUES+=("Cannot ping remote gateway tunnel IP $REMOTE_TUNNEL_IP")
fi

if [ "$MISSING_TUNNELS" -gt 0 ]; then
    NOTES+=("Run 'sudo grex activate', then check 'sudo journalctl -u gre-tunnel -n 100 --no-pager' if the tunnel interface is still missing")
fi

# Check dnsmasq
if [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        dnsmasq_running() {
            systemctl is-active --quiet dnsmasq
        }
    else
        dnsmasq_running() {
            command -v pgrep >/dev/null 2>&1 && pgrep -x dnsmasq >/dev/null 2>&1
        }
    fi

    if ! dnsmasq_running; then
        set_status "WARNING"
        ISSUES+=("dnsmasq service is not running")
    fi
fi

# Output
echo "Status: $STATUS"
if [ ${#ISSUES[@]} -gt 0 ]; then
    echo "Issues:"
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue"
    done
else
    echo "All checks passed"
fi

if [ ${#NOTES[@]} -gt 0 ]; then
    echo "Notes:"
    for note in "${NOTES[@]}"; do
        echo "  - $note"
    done
fi

exit 0
