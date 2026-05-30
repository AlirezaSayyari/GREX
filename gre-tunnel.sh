#!/bin/bash

# GRE Tunnel Setup Script
# This script sets up multiple GRE tunnels, routing, NAT, and iptables rules

set -e

if [ "$EUID" -ne 0 ]; then
    echo "gre-tunnel.sh must be run as root." >&2
    exit 1
fi

CONFIG_FILE="/etc/gre-tunnel.conf"
GREX_CHAIN="GREX-FORWARD"

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

require_config_value() {
    local var_name=$1
    local value
    value=$(get_config_value "$var_name")

    if [ -z "$value" ]; then
        echo "Missing required configuration value: $var_name" >&2
        exit 1
    fi
}

cleanup_existing_tunnels() {
    local gre_if_var
    local gre_if
    local link_path
    local link_name

    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        gre_if=$(get_config_value "$gre_if_var")
        delete_tunnel_if_exists "$gre_if"
    done

    for link_path in /sys/class/net/*; do
        link_name=${link_path##*/}
        case "$link_name" in
            gre-forti[0-9]*|grex[0-9]*|*_GRE_IF)
                delete_tunnel_if_exists "$link_name"
                ;;
        esac
    done
}

validate_config() {
    command -v ip >/dev/null 2>&1 || {
        echo "Missing required command: ip. Install iproute2/iproute." >&2
        exit 1
    }
    command -v iptables >/dev/null 2>&1 || {
        echo "Missing required command: iptables." >&2
        exit 1
    }

    require_config_value "VPS_PUBLIC_IP"
    require_config_value "FORTI_PUBLIC_IP"
    require_config_value "NUM_TUNNELS"
    require_config_value "INTERNAL_SUBNETS"
    require_config_value "ETH_INTERFACE"

    if ! [[ "$NUM_TUNNELS" =~ ^[1-9][0-9]*$ ]]; then
        echo "NUM_TUNNELS must be a positive integer." >&2
        exit 1
    fi

    for ((i=1; i<=NUM_TUNNELS; i++)); do
        require_config_value "TUNNEL_${i}_GRE_IF"
        require_config_value "TUNNEL_${i}_VPS_IP"
        require_config_value "TUNNEL_${i}_FORTI_IP"
    done
}

delete_rule_if_exists() {
    local table=$1
    local chain=$2
    shift 2

    while iptables -t "$table" -C "$chain" "$@" 2>/dev/null; do
        iptables -t "$table" -D "$chain" "$@" 2>/dev/null || break
    done
}

setup_forward_chain() {
    iptables -N "$GREX_CHAIN" 2>/dev/null || true
    iptables -F "$GREX_CHAIN"

    delete_rule_if_exists filter FORWARD -j "$GREX_CHAIN"
    iptables -I FORWARD 1 -j "$GREX_CHAIN"
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found. Run setup.sh first."
    exit 1
fi

source "$CONFIG_FILE"
validate_config

# Clean up existing tunnels
cleanup_existing_tunnels

# Create GRE tunnels
echo "Creating GRE tunnels..."
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    gre_if=$(get_config_value "$gre_if_var")
    vps_ip_var="TUNNEL_${i}_VPS_IP"
    vps_ip=$(get_config_value "$vps_ip_var")
    
    echo "Creating tunnel $i: $gre_if"
    ip link add "$gre_if" type gre \
      local "$VPS_PUBLIC_IP" \
      remote "$FORTI_PUBLIC_IP" \
      ttl 255 \
      key "$i"
    
    ip addr add "$vps_ip" dev "$gre_if"
    ip link set "$gre_if" mtu 1476
    ip link set "$gre_if" up
done

# Add routes for internal subnets with load balancing
echo "Adding routes for internal subnets with load balancing..."
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    subnet=$(trim "$subnet")
    [ -n "$subnet" ] || continue

    route_cmd=(ip route replace "$subnet")
    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        gre_if=$(get_config_value "$gre_if_var")
        route_cmd+=(nexthop dev "$gre_if" weight 1)
    done
    "${route_cmd[@]}"
done

# NAT outbound traffic
echo "Setting up NAT..."
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    subnet=$(trim "$subnet")
    [ -n "$subnet" ] || continue
    delete_rule_if_exists nat POSTROUTING -s "$subnet" -o "$ETH_INTERFACE" -j MASQUERADE
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$ETH_INTERFACE" -j MASQUERADE
done

# Forward rules
echo "Setting up forward rules..."
setup_forward_chain
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    gre_if=$(get_config_value "$gre_if_var")
    iptables -A "$GREX_CHAIN" -i "$gre_if" -o "$ETH_INTERFACE" -j ACCEPT
    iptables -A "$GREX_CHAIN" -i "$ETH_INTERFACE" -o "$gre_if" \
      -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

# Allow GRE protocol
echo "Allowing GRE protocol..."
delete_rule_if_exists filter INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT
iptables -I INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT

# Persist iptables
echo "Saving iptables rules..."
save_iptables_rules

echo "GRE tunnels setup complete."
