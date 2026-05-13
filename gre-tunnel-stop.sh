#!/bin/bash

# GRE Tunnel Stop Script

CONFIG_FILE="/etc/gre-tunnel.conf"

save_iptables_rules() {
    if [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables
    elif [ -d /etc/iptables ]; then
        iptables-save > /etc/iptables/rules.v4
    else
        echo "No persistent iptables rules directory found; rules will be reapplied when gre-tunnel starts."
    fi
}

delete_tunnel_if_exists() {
    local tunnel_name=$1

    if [ -n "$tunnel_name" ] && ip link show "$tunnel_name" >/dev/null 2>&1; then
        ip link del "$tunnel_name" 2>/dev/null || true
    fi
}

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    
    # Clean up tunnels
    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        eval gre_if=\$$gre_if_var
        delete_tunnel_if_exists "$gre_if"
    done
fi

for link_path in /sys/class/net/*; do
    link_name=${link_path##*/}
    case "$link_name" in
        gre-forti[0-9]*|*_GRE_IF)
            delete_tunnel_if_exists "$link_name"
            ;;
    esac
done

# Remove iptables rules
iptables -t nat -F POSTROUTING 2>/dev/null || true
iptables -F FORWARD 2>/dev/null || true
iptables -D INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT 2>/dev/null || true

# Save empty rules
save_iptables_rules

echo "GRE tunnels stopped."
