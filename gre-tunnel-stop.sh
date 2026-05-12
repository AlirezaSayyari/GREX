#!/bin/bash

# GRE Tunnel Stop Script

CONFIG_FILE="/etc/gre-tunnel.conf"

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    
    # Clean up tunnels
    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        eval gre_if=\$$gre_if_var
        ip link del "$gre_if" 2>/dev/null || true
    done
fi

# Remove iptables rules
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
iptables -D INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT 2>/dev/null || true

# Save empty rules
iptables-save > /etc/sysconfig/iptables

echo "GRE tunnels stopped."