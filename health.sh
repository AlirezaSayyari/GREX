#!/bin/bash

# Health Check Script

CONFIG_FILE="/etc/gre-tunnel.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found."
    exit 1
fi

source "$CONFIG_FILE"

STATUS="OK"
ISSUES=()

# Check if tunnel interfaces exist
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    eval gre_if=\$$gre_if_var
    if ! ip link show "$gre_if" &>/dev/null; then
        STATUS="CRITICAL"
        ISSUES+=("Tunnel interface $gre_if does not exist")
    fi
done

# Check if tunnels are up
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    eval gre_if=\$$gre_if_var
    if ! ip -br a | grep -q "$gre_if.*UP"; then
        STATUS="CRITICAL"
        ISSUES+=("Tunnel interface $gre_if is not UP")
    fi
done

# Check routes
ROUTE_COUNT=$(ip route show | grep -c "$GRE_IF")
if [ "$ROUTE_COUNT" -eq 0 ]; then
    STATUS="WARNING"
    ISSUES+=("No routes configured via tunnel")
fi

# Check NAT rules
NAT_COUNT=$(iptables -t nat -L POSTROUTING -n | grep -c MASQUERADE)
if [ "$NAT_COUNT" -eq 0 ]; then
    STATUS="WARNING"
    ISSUES+=("No NAT rules configured")
fi

# Check connectivity
for ((i=1; i<=NUM_TUNNELS; i++)); do
    forti_ip_var="TUNNEL_${i}_FORTI_IP"
    eval forti_ip=\$$forti_ip_var
    if ! ping -c 1 -W 2 "$forti_ip" &>/dev/null; then
        STATUS="CRITICAL"
        ISSUES+=("Cannot ping FortiGate tunnel IP for tunnel $i")
    fi
done

# Check dnsmasq
if ! systemctl is-active --quiet dnsmasq; then
    STATUS="WARNING"
    ISSUES+=("dnsmasq service is not running")
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

exit 0