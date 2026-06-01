#!/bin/bash

# GRE Tunnel Stop Script

if [ "$EUID" -ne 0 ]; then
    echo "gre-tunnel-stop.sh must be run as root." >&2
    exit 1
fi

CONFIG_FILE="/etc/gre-tunnel.conf"
GREX_CHAIN="GREX-FORWARD"
GREX_MANGLE_CHAIN="GREX-MANGLE"

save_iptables_rules() {
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save || echo "Could not persist iptables rules with netfilter-persistent."
    elif command -v service >/dev/null 2>&1 && service iptables status >/dev/null 2>&1; then
        service iptables save || echo "Could not persist iptables rules with iptables service."
    elif [ -d /etc/sysconfig ]; then
        iptables-save > /etc/sysconfig/iptables
    elif [ -d /etc/iptables ]; then
        mkdir -p /etc/iptables
        iptables-save > /etc/iptables/rules.v4
    else
        echo "No persistent iptables rules directory found; rules will be reapplied when gre-tunnel starts."
    fi
}

delete_tunnel_if_exists() {
    local tunnel_name=$1

    if [ -n "$tunnel_name" ] && ip link show "$tunnel_name" >/dev/null 2>&1; then
        echo "Removing existing tunnel interface: $tunnel_name"
        ip link del "$tunnel_name" 2>/dev/null || true
    fi
}

get_config_value() {
    local var_name=$1
    printf "%s" "${!var_name}"
}

normalize_config() {
    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    FORTI_TUNNEL_IP=${FORTI_TUNNEL_IP:-${TUNNEL_1_FORTI_IP:-}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-gre-forti}}
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
    normalize_config
    
    # Clean up tunnel
    delete_tunnel_if_exists "$GRE_IF"
fi

for link_path in /sys/class/net/*; do
    link_name=${link_path##*/}
    case "$link_name" in
        gre-forti*|grex*|*_GRE_IF)
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

delete_rule_if_exists mangle FORWARD -j "$GREX_MANGLE_CHAIN"
iptables -t mangle -F "$GREX_MANGLE_CHAIN" 2>/dev/null || true
iptables -t mangle -X "$GREX_MANGLE_CHAIN" 2>/dev/null || true

if [ -n "${FORTI_PUBLIC_IP:-}" ]; then
    delete_rule_if_exists filter INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT
fi

# Save updated rules
save_iptables_rules

echo "GRE tunnel stopped."
