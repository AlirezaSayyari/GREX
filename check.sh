#!/bin/bash

# Check Policies and Routing Script

CONFIG_FILE="/etc/gre-tunnel.conf"
BACKUP_DIR="/var/backups/grex"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found."
    exit 1
fi

source "$CONFIG_FILE"

echo "🟣 Checking GRE Tunnel Configuration"
echo "===================================="

get_config_value() {
    local var_name=$1
    printf "%s" "${!var_name}"
}

normalize_config() {
    local legacy_tunnel_var
    local legacy_tunnel_1_var

    legacy_tunnel_var="FO""RTI_TUNNEL_IP"
    legacy_tunnel_1_var="TUNNEL_1_FO""RTI_IP"

    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    REMOTE_TUNNEL_IP=${REMOTE_TUNNEL_IP:-${!legacy_tunnel_var:-${!legacy_tunnel_1_var:-}}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-grex}}
    GRE_MTU=${GRE_MTU:-1476}
    MSS_MODE=${MSS_MODE:-clamp}
    MSS_VALUE=${MSS_VALUE:-}
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-no}
    ENABLE_SYSCTL_HARDENING=${ENABLE_SYSCTL_HARDENING:-yes}
    SYSCTL_PROFILE=${SYSCTL_PROFILE:-safe}
    RP_FILTER=${RP_FILTER:-2}
    TCP_TIMESTAMPS=${TCP_TIMESTAMPS:-1}
    DISABLE_IPV6=${DISABLE_IPV6:-no}
    NF_CONNTRACK_MAX=${NF_CONNTRACK_MAX:-262144}
    CONNTRACK_WARN_PERCENT=${CONNTRACK_WARN_PERCENT:-70}
    CONNTRACK_CRIT_PERCENT=${CONNTRACK_CRIT_PERCENT:-90}
}

normalize_config

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

echo "0. Config File:"
echo "Path: $CONFIG_FILE"
echo "Mode: $(stat -c %a "$CONFIG_FILE" 2>/dev/null || echo unknown)"
echo "Owner: $(stat -c %U:%G "$CONFIG_FILE" 2>/dev/null || echo unknown)"
echo "Latest backups:"
ls -1t "$BACKUP_DIR"/gre-tunnel.conf.*.bak 2>/dev/null | head -5 || echo "No backups found in $BACKUP_DIR"
echo

echo "0b. iptables Backend:"
echo "iptables:        $(iptables --version 2>/dev/null || echo missing) [$(iptables_backend iptables)]"
echo "iptables-legacy: $(iptables-legacy --version 2>/dev/null || echo missing) [$(iptables_backend iptables-legacy)]"
echo "iptables-nft:    $(iptables-nft --version 2>/dev/null || echo missing) [$(iptables_backend iptables-nft)]"
if iptables_rules_present iptables-legacy; then
    echo "legacy rules: present"
else
    echo "legacy rules: not detected"
fi
if iptables_rules_present iptables-nft; then
    echo "nft rules: present"
else
    echo "nft rules: not detected"
fi
echo

# Check tunnel interface
echo "1. Tunnel Interface:"
ip -br a | grep "$GRE_IF" || echo "Tunnel interface $GRE_IF not found!"
echo "Expected MTU: $GRE_MTU"
current_mtu=$(ip link show dev "$GRE_IF" 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "mtu") print $(i+1)}')
effective_mtu=${current_mtu:-$GRE_MTU}

# Check routes
echo
echo "2. Routes:"
ip route show | grep "$GRE_IF" || echo "No routes via $GRE_IF found!"

# Check NAT rules
echo
echo "3. NAT Rules:"
iptables -t nat -L POSTROUTING -n -v | grep MASQUERADE || echo "No NAT rules found!"

# Check forward rules
echo
echo "4. Forward Rules:"
iptables -L FORWARD -n -v | head -20
echo
echo "4b. GRE Anti-Spoofing Rules:"
iptables -L GREX-FORWARD -n -v 2>/dev/null || echo "GREX-FORWARD chain not found"
echo
echo "4c. GREX Egress Filtering Rules:"
iptables -L GREX-EGRESS -n -v 2>/dev/null || echo "GREX-EGRESS chain not found"
echo
echo "4d. GREX Drop Logging Rules:"
iptables -S GREX-FORWARD 2>/dev/null | grep -- "-j LOG" || true
iptables -S GREX-EGRESS 2>/dev/null | grep -- "-j LOG" || true
iptables -S GREX-INPUT 2>/dev/null | grep -- "-j LOG" || true
echo "Drop logging: ${ENABLE_DROP_LOGGING:-no}, rate: ${DROP_LOG_RATE:-3/min}, burst: ${DROP_LOG_BURST:-10}"

# Check GRE input rule
echo
echo "5. GRE Input Rule:"
iptables -L INPUT -n -v | grep "47" || echo "GRE protocol not allowed!"

echo
echo "5b. GREX Hardening:"
echo "INPUT policy: $(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/ {print $3}')"
echo "FORWARD policy: $(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/ {print $3}')"
echo "Admin SSH sources: ${ADMIN_IPS:-not configured}"
iptables -L GREX-INPUT -n -v 2>/dev/null || echo "GREX-INPUT chain not found"
iptables -t mangle -L GREX-MANGLE -n -v 2>/dev/null || echo "GREX-MANGLE chain not found"
echo "MSS mode: $MSS_MODE ${MSS_VALUE:-}"

echo
echo "5c. MTU/MSS Diagnostics:"
echo "Configured GRE MTU: $GRE_MTU"
echo "Current GRE MTU: ${current_mtu:-unknown}"
recommended_mss=$(recommended_mss_for_mtu "$effective_mtu")
df_ping_payload=$(icmp_payload_for_mtu "$effective_mtu")
if [ -n "$recommended_mss" ]; then
    echo "Recommended fixed MSS for MTU $effective_mtu: $recommended_mss"
fi
if [ "$MSS_MODE" = "fixed" ] && [ -n "$recommended_mss" ] && [[ "$MSS_VALUE" =~ ^[0-9]+$ ]] && [ "$MSS_VALUE" -gt "$recommended_mss" ]; then
    echo "WARNING: MSS_VALUE $MSS_VALUE is higher than recommended $recommended_mss"
fi
if [ -n "$df_ping_payload" ]; then
    echo "Tunnel DF probe: ping $REMOTE_TUNNEL_IP -M do -s $df_ping_payload -c 4"
fi

echo
echo "5d. Conntrack Capacity:"
conntrack_count=$(sysctl -q -n net.netfilter.nf_conntrack_count 2>/dev/null || true)
conntrack_max=$(sysctl -q -n net.netfilter.nf_conntrack_max 2>/dev/null || true)
if [ -n "$conntrack_count" ] && [ -n "$conntrack_max" ] && [ "$conntrack_max" -gt 0 ]; then
    conntrack_percent=$((conntrack_count * 100 / conntrack_max))
    echo "Usage: $conntrack_count/$conntrack_max (${conntrack_percent}%)"
    echo "Thresholds: warning ${CONNTRACK_WARN_PERCENT}%, critical ${CONNTRACK_CRIT_PERCENT}%"
else
    echo "Conntrack counters are not available on this kernel"
fi
if command -v conntrack >/dev/null 2>&1; then
    conntrack -S 2>/dev/null || true
else
    echo "conntrack command not installed; install conntrack-tools for protocol counters"
fi

echo
echo "5e. Sysctl Hardening:"
if [[ "$ENABLE_SYSCTL_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    echo "Sysctl hardening is enabled in GREX config"
    echo "Profile: $SYSCTL_PROFILE"
    echo "Expected rp_filter: $RP_FILTER"
    echo "Expected tcp_timestamps: $TCP_TIMESTAMPS"
    echo "Disable IPv6: $DISABLE_IPV6"
    echo "Expected nf_conntrack_max: $NF_CONNTRACK_MAX"
    cat /etc/sysctl.d/99-grex-hardening.conf 2>/dev/null || echo "GREX sysctl file not found"
    echo "Current values:"
    for key in \
        net.ipv4.ip_forward \
        net.ipv4.conf.all.rp_filter \
        net.ipv4.conf.default.rp_filter \
        net.ipv4.tcp_timestamps \
        net.netfilter.nf_conntrack_max \
        net.ipv6.conf.all.disable_ipv6; do
        value=$(sysctl -q -n "$key" 2>/dev/null || true)
        if [ -n "$value" ]; then
            echo "$key = $value"
        fi
    done
else
    echo "Sysctl hardening is disabled in GREX config"
fi

echo
echo "5f. fail2ban:"
if [[ "$ENABLE_FAIL2BAN" =~ ^(yes|y|Y)$ ]]; then
    echo "fail2ban is enabled in GREX config"
    cat /etc/fail2ban/jail.d/grex-sshd.local 2>/dev/null || echo "GREX fail2ban jail not found"
    if command -v fail2ban-client >/dev/null 2>&1; then
        fail2ban-client status sshd 2>/dev/null || true
    fi
else
    echo "fail2ban is disabled in GREX config"
fi

# Check DNS
echo
echo "6. DNS Configuration:"
if [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]]; then
    if { command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ] && systemctl is-active --quiet dnsmasq; } || { command -v pgrep >/dev/null 2>&1 && pgrep -x dnsmasq >/dev/null 2>&1; }; then
        echo "dnsmasq is running"
        cat /etc/dnsmasq.d/tunnel.conf 2>/dev/null || echo "DNS config not found"
    else
        echo "dnsmasq is not running"
    fi
else
    echo "dnsmasq is disabled in GREX config"
fi

# Check connectivity
echo
echo "7. Connectivity Check:"
if ping -c 1 -W 2 "$REMOTE_TUNNEL_IP" &>/dev/null; then
    echo "Tunnel is reachable"
else
    echo "Tunnel is not reachable"
fi
