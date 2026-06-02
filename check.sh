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
    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    FORTI_TUNNEL_IP=${FORTI_TUNNEL_IP:-${TUNNEL_1_FORTI_IP:-}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-gre-forti}}
    GRE_MTU=${GRE_MTU:-1476}
    MSS_MODE=${MSS_MODE:-clamp}
    MSS_VALUE=${MSS_VALUE:-}
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-no}
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
echo "5c. fail2ban:"
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
if ping -c 1 -W 2 "$FORTI_TUNNEL_IP" &>/dev/null; then
    echo "Tunnel is reachable"
else
    echo "Tunnel is not reachable"
fi
