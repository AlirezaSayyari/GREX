#!/bin/bash

# GRE Tunnel Setup Script
# This script sets up multiple GRE tunnels, routing, NAT, and iptables rules

set -e

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

cleanup_existing_tunnels() {
    local gre_if_var
    local gre_if
    local link_path
    local link_name

    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        eval gre_if=\$$gre_if_var
        delete_tunnel_if_exists "$gre_if"
    done

    for link_path in /sys/class/net/*; do
        link_name=${link_path##*/}
        case "$link_name" in
            gre-forti[0-9]*|*_GRE_IF)
                delete_tunnel_if_exists "$link_name"
                ;;
        esac
    done
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found. Run setup.sh first."
    exit 1
fi

source "$CONFIG_FILE"

# Clean up existing tunnels
cleanup_existing_tunnels

# Create GRE tunnels
echo "Creating GRE tunnels..."
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    eval gre_if=\$$gre_if_var
    vps_ip_var="TUNNEL_${i}_VPS_IP"
    eval vps_ip=\$$vps_ip_var
    
    echo "Creating tunnel $i: $gre_if"
    ip tunnel add name "$gre_if" mode gre \
      local "$VPS_PUBLIC_IP" \
      remote "$FORTI_PUBLIC_IP" \
      ttl 255 \
      key $i  # Use key to differentiate tunnels
    
    ip addr add "$vps_ip" dev "$gre_if"
    ip link set "$gre_if" up
    ip link set "$gre_if" mtu 1476
done

# Add routes for internal subnets with load balancing
echo "Adding routes for internal subnets with load balancing..."
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    route_cmd="ip route add $subnet"
    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        eval gre_if=\$$gre_if_var
        route_cmd="$route_cmd nexthop dev $gre_if"
    done
    $route_cmd || echo "Route for $subnet may already exist"
done

# NAT outbound traffic
echo "Setting up NAT..."
iptables -t nat -F POSTROUTING 2>/dev/null || true
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    iptables -t nat -A POSTROUTING -s "$subnet" -o "$ETH_INTERFACE" -j MASQUERADE
done

# Forward rules
echo "Setting up forward rules..."
iptables -F FORWARD 2>/dev/null || true
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    eval gre_if=\$$gre_if_var
    iptables -I FORWARD $((2*i-1)) -i "$gre_if" -o "$ETH_INTERFACE" -j ACCEPT
    iptables -I FORWARD $((2*i)) -i "$ETH_INTERFACE" -o "$gre_if" \
      -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
done

# Allow GRE protocol
echo "Allowing GRE protocol..."
iptables -I INPUT -p 47 -s "$FORTI_PUBLIC_IP" -j ACCEPT 2>/dev/null || true

# Persist iptables
echo "Saving iptables rules..."
save_iptables_rules

echo "GRE tunnels setup complete."
