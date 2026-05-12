#!/bin/bash

# Controlled Egress GRE Tunnel Setup Wizard
# This script configures the GRE tunnel on the VPS side with a wizard interface

set -e

echo "🟣 Controlled Egress GRE Tunnel Setup Wizard"
echo "============================================"

# Function to prompt for input
prompt() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    read -p "$prompt_text [$default_value]: " input
    eval $var_name="${input:-$default_value}"
}

# Collect configuration
echo "Please provide the following configuration details:"
echo

prompt VPS_PUBLIC_IP "VPS Public IP" "130.x.x.x"
prompt FORTI_PUBLIC_IP "FortiGate Public IP" "93.x.x.x"
prompt NUM_TUNNELS "Number of parallel tunnels" "2"
prompt INTERNAL_SUBNETS "Internal subnets (comma-separated)" "192.168.0.0/16,172.16.0.0/12"
prompt ENABLE_DNSMASQ "Enable local DNS server with dnsmasq? (yes/no)" "yes"
prompt DNS_SERVERS "Upstream DNS servers (comma-separated)" "1.1.1.1,8.8.8.8"
prompt ETH_INTERFACE "Ethernet interface" "eth0"

# Create config file
cat > /etc/gre-tunnel.conf << EOF
VPS_PUBLIC_IP=$VPS_PUBLIC_IP
FORTI_PUBLIC_IP=$FORTI_PUBLIC_IP
NUM_TUNNELS=$NUM_TUNNELS
INTERNAL_SUBNETS=$INTERNAL_SUBNETS
DNS_SERVERS=$DNS_SERVERS
ETH_INTERFACE=$ETH_INTERFACE
EOF

for ((i=1; i<=NUM_TUNNELS; i++)); do
    base_ip=$((10 + i - 1))
    default_vps_ip="10.10.${base_ip}.2/30"
    default_forti_ip="10.10.${base_ip}.1"
    default_gre_if="gre-forti${i}"
    
    prompt TUNNEL_${i}_VPS_IP "Tunnel $i VPS IP with mask" "$default_vps_ip"
    prompt TUNNEL_${i}_FORTI_IP "Tunnel $i FortiGate IP" "$default_forti_ip"
    prompt TUNNEL_${i}_GRE_IF "Tunnel $i GRE interface" "$default_gre_if"
    
    cat >> /etc/gre-tunnel.conf << EOF
TUNNEL_${i}_VPS_IP=$TUNNEL_${i}_VPS_IP
TUNNEL_${i}_FORTI_IP=$TUNNEL_${i}_FORTI_IP
TUNNEL_${i}_GRE_IF=$TUNNEL_${i}_GRE_IF
EOF
done

echo "Configuration saved to /etc/gre-tunnel.conf"

# Install dependencies
echo "Installing dependencies..."
if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    dnf install -y dnsmasq iptables-services || yum install -y dnsmasq iptables-services
else
    dnf install -y iptables-services || yum install -y iptables-services
fi

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

# Create systemd service
echo "Creating systemd service..."
sudo cp gre-tunnel.service /etc/systemd/system/
sudo cp gre-tunnel.sh /usr/local/bin/
sudo cp gre-tunnel-stop.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/gre-tunnel.sh
sudo chmod +x /usr/local/bin/gre-tunnel-stop.sh

if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    # Configure dnsmasq
echo "Configuring DNS..."
    cat > /etc/dnsmasq.d/tunnel.conf << EOF
EOF

    for ((i=1; i<=NUM_TUNNELS; i++)); do
        gre_if_var="TUNNEL_${i}_GRE_IF"
        eval gre_if=\$$gre_if_var
        vps_ip_var="TUNNEL_${i}_VPS_IP"
        eval vps_ip=\$$vps_ip_var
        listen_ip=$(echo $vps_ip | cut -d'/' -f1)
        echo "interface=$gre_if" >> /etc/dnsmasq.d/tunnel.conf
        echo "listen-address=$listen_ip" >> /etc/dnsmasq.d/tunnel.conf
    done

    for dns in $(echo $DNS_SERVERS | tr ',' ' '); do
        echo "server=$dns" >> /etc/dnsmasq.d/tunnel.conf
done
fi

echo "Setup complete! Run the following commands to start:"
echo "sudo systemctl daemon-reload"
echo "sudo systemctl enable gre-tunnel"
echo "sudo systemctl start gre-tunnel"
if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    echo "sudo systemctl enable dnsmasq"
    echo "sudo systemctl start dnsmasq"
fi