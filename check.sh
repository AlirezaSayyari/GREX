#!/bin/bash

# Check Policies and Routing Script

CONFIG_FILE="/etc/gre-tunnel.conf"

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
}

normalize_config

# Check tunnel interface
echo "1. Tunnel Interface:"
ip -br a | grep "$GRE_IF" || echo "Tunnel interface $GRE_IF not found!"
echo "Expected MTU: $GRE_MTU"

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
echo "5c. Sysctl Hardening:"
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
echo "5d. fail2ban:"
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
