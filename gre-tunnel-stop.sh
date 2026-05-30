#!/bin/bash

# GRE Tunnel Stop Script

CONFIG_FILE="/etc/gre-tunnel.conf"
GREX_CHAIN="GREX-FORWARD"

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

get_config_value() {
    local var_name=$1
    printf "%s" "${!var_name}"
}

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

delete_rule_if_exists() {
    local table=$1
    local chain=$2
    shift 2

    while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || break
    done
}

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    
    # Clean up tunnels
    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        gre_if=$(get_config_value "$gre_if_var")
        delete_tunnel_if_exists "$gre_if"
    done
fi

for link_path in /sys/class/net/*; do
    link_name=${link_path##*/}
    case "$link_name" in
        gre-forti[0-9]*|grex[0-9]*|*_GRE_IF)
            delete_tunnel_if_exists "$link_name"
            ;;
    esac
done

# Remove iptables rules
if [ -n "${INTERNAL_SUBNETS:-}" ] && [ -n "${ETH_INTERFACE:-}" ]; then
    IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
    for subnet in "${SUBNETS[@]}"; do
        subnet=$(trim "$subnet")
        [ -n "$subnet" ] || continue
        delete_rule_if_exists nat POSTROUTING -s "$subnet" -o "$ETH_INTERFACE" -j MASQUERADE
    done
fi

delete_rule_if_exists filter FORWARD -j "$GREX_CHAIN"
iptables -F "$GREX_CHAIN" 2>/dev/null || true
iptables -X "$GREX_CHAIN" 2>/dev/null || true

if [ -n "${FORTI_PUBLIC_IP:-}" ]; then
    delete_rule_if_exists filter INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT
fi

# Save updated rules
save_iptables_rules

echo "GRE tunnels stopped."
