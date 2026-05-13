#!/bin/bash

# Controlled Egress GRE Tunnel Setup Wizard
# This script configures the GRE tunnel on the VPS side with a wizard interface

set -e

echo "🟣 Controlled Egress GRE Tunnel Setup Wizard"
echo "============================================"

INPUT_DEVICE="/dev/stdin"
if [ ! -t 0 ] && [ -r /dev/tty ]; then
    INPUT_DEVICE="/dev/tty"
fi

# Function to prompt for input
prompt() {
    local var_name=$1
    local prompt_text=$2
    local default_value=$3
    local input
    read -r -p "$prompt_text [$default_value]: " input < "$INPUT_DEVICE"
    printf -v "$var_name" "%s" "${input:-$default_value}"
}

is_ipv4() {
    local ip=$1
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

    local IFS=.
    local octets
    read -r -a octets <<< "$ip"
    for octet in "${octets[@]}"; do
        if ((10#$octet < 0 || 10#$octet > 255)); then
            return 1
        fi
    done

    return 0
}

detect_public_ip() {
    local endpoint
    local ip
    local endpoints=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://checkip.amazonaws.com"
    )

    if ! command -v curl >/dev/null 2>&1; then
        return 1
    fi

    for endpoint in "${endpoints[@]}"; do
        ip=$(curl -4 -fsS --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
        if is_ipv4 "$ip"; then
            printf "%s" "$ip"
            return 0
        fi
    done

    return 1
}

install_dependencies() {
    local packages

    if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
        packages=(dnsmasq iptables)
    else
        packages=(iptables)
    fi

    if command -v apt-get >/dev/null 2>&1; then
        local policy_file="/usr/sbin/policy-rc.d"
        local created_policy=0
        local status=0

        if [ ! -e "$policy_file" ]; then
            printf '#!/bin/sh\nexit 101\n' > "$policy_file"
            chmod +x "$policy_file"
            created_policy=1
        fi

        set +e
        apt-get update
        status=$?
        if [ "$status" -eq 0 ]; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
            status=$?
        fi
        set -e

        if [ "$created_policy" -eq 1 ]; then
            rm -f "$policy_file"
        fi

        return "$status"
    elif command -v dnf >/dev/null 2>&1; then
        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            dnf install -y dnsmasq iptables-services
        else
            dnf install -y iptables-services
        fi
    elif command -v yum >/dev/null 2>&1; then
        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            yum install -y dnsmasq iptables-services
        else
            yum install -y iptables-services
        fi
    else
        echo "Unsupported Linux distribution: apt-get, dnf, or yum was not found."
        echo "Install dnsmasq and iptables manually, then run 'sudo grex configure' again."
        exit 1
    fi
}

# Collect configuration
echo "Please provide the following configuration details:"
echo

DETECTED_VPS_PUBLIC_IP=$(detect_public_ip || true)
prompt VPS_PUBLIC_IP "VPS Public IP" "${DETECTED_VPS_PUBLIC_IP:-130.x.x.x}"
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
    vps_ip_var="TUNNEL_${i}_VPS_IP"
    forti_ip_var="TUNNEL_${i}_FORTI_IP"
    gre_if_var="TUNNEL_${i}_GRE_IF"
    
    prompt "$vps_ip_var" "Tunnel $i VPS IP with mask" "$default_vps_ip"
    prompt "$forti_ip_var" "Tunnel $i FortiGate IP" "$default_forti_ip"
    prompt "$gre_if_var" "Tunnel $i GRE interface" "$default_gre_if"
    
    cat >> /etc/gre-tunnel.conf << EOF
$vps_ip_var=${!vps_ip_var}
$forti_ip_var=${!forti_ip_var}
$gre_if_var=${!gre_if_var}
EOF
done

echo "Configuration saved to /etc/gre-tunnel.conf"

# Install dependencies
echo "Installing dependencies..."
install_dependencies

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

systemctl daemon-reload

if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    # Configure dnsmasq
    echo "Configuring DNS..."
    systemctl stop dnsmasq 2>/dev/null || true
    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/tunnel.conf << EOF
bind-dynamic
no-resolv
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
