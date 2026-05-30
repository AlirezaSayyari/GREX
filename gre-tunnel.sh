#!/bin/bash

# GRE Tunnel Setup Script
# This script sets up one GRE tunnel, routing, NAT, and iptables rules

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
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-gre-forti1}}
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

delete_conflicting_gre_tunnel() {
    local tunnel_key=$1
    local line
    local tunnel_name

    while IFS= read -r line; do
        tunnel_name=${line%%:*}
        [ -n "$tunnel_name" ] || continue
        [ "$tunnel_name" != "gre0" ] || continue

        if [[ "$line" == *"remote $FORTI_PUBLIC_IP"* ]] &&
           [[ "$line" == *"local $VPS_PUBLIC_IP"* ]] &&
           [[ "$line" == *"key $tunnel_key"* ]]; then
            delete_tunnel_if_exists "$tunnel_name"
        fi
    done < <(ip tunnel show 2>/dev/null || true)
}

cleanup_existing_tunnel() {
    local link_path
    local link_name

    delete_tunnel_if_exists "$GRE_IF"

    for link_path in /sys/class/net/*; do
        link_name=${link_path##*/}
        case "$link_name" in
            gre-forti*|grex*|*_GRE_IF)
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
    require_config_value "INTERNAL_SUBNETS"
    require_config_value "ETH_INTERFACE"
    require_config_value "VPS_TUNNEL_IP"
    require_config_value "FORTI_TUNNEL_IP"
    require_config_value "GRE_IF"
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
normalize_config
validate_config

# Clean up existing tunnel
cleanup_existing_tunnel

# Create GRE tunnel
echo "Creating GRE tunnel: $GRE_IF"
delete_conflicting_gre_tunnel "1"
ip link add "$GRE_IF" type gre \
  local "$VPS_PUBLIC_IP" \
  remote "$FORTI_PUBLIC_IP" \
  ttl 255 \
  key "1"

ip addr add "$VPS_TUNNEL_IP" dev "$GRE_IF"
ip link set "$GRE_IF" mtu 1476
ip link set "$GRE_IF" up

# Add routes for internal subnets
echo "Adding routes for internal subnets..."
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    subnet=$(trim "$subnet")
    [ -n "$subnet" ] || continue

    ip route replace "$subnet" dev "$GRE_IF"
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
iptables -A "$GREX_CHAIN" -i "$GRE_IF" -o "$ETH_INTERFACE" -j ACCEPT
iptables -A "$GREX_CHAIN" -i "$ETH_INTERFACE" -o "$GRE_IF" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Allow GRE protocol
echo "Allowing GRE protocol..."
delete_rule_if_exists filter INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT
iptables -I INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT

# Persist iptables
echo "Saving iptables rules..."
save_iptables_rules

echo "GRE tunnel setup complete."
