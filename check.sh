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

# Check tunnel interface
echo "1. Tunnel Interfaces:"
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    eval gre_if=\$$gre_if_var
    ip -br a | grep "$gre_if" || echo "Tunnel interface $gre_if not found!"
done

# Check routes
echo
echo "2. Routes:"
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    eval gre_if=\$$gre_if_var
    ip route show | grep "$gre_if" || echo "No routes via $gre_if found!"
done

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

# Check DNS
echo
echo "6. DNS Configuration:"
if systemctl is-active --quiet dnsmasq; then
    echo "dnsmasq is running"
    cat /etc/dnsmasq.d/tunnel.conf 2>/dev/null || echo "DNS config not found"
else
    echo "dnsmasq is not running"
fi

# Check connectivity
echo
echo "7. Connectivity Check:"
for ((i=1; i<=NUM_TUNNELS; i++)); do
    forti_ip_var="TUNNEL_${i}_FORTI_IP"
    eval forti_ip=\$$forti_ip_var
    if ping -c 1 -W 2 "$forti_ip" &>/dev/null; then
        echo "Tunnel $i is reachable"
    else
        echo "Tunnel $i is not reachable"
    fi
done