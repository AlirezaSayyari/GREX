#!/bin/bash

# Controlled Egress GRE Tunnel Setup Wizard
# This script configures the GRE tunnel on the VPS side with a wizard interface

set -e

if [ "$EUID" -ne 0 ]; then
    echo "setup.sh must be run as root. Use: sudo bash setup.sh" >&2
    exit 1
fi

echo "🟣 Controlled Egress GRE Tunnel Setup Wizard"
echo "============================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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

detect_default_interface() {
    local iface

    if command -v ip >/dev/null 2>&1; then
        iface=$(ip route show default 2>/dev/null | awk '{print $5; exit}')
        if [ -n "$iface" ]; then
            printf "%s" "$iface"
            return 0
        fi
    fi

    printf "eth0"
}

detect_admin_ip() {
    local ip

    ip=${SSH_CLIENT%% *}
    if is_ipv4 "$ip"; then
        printf "%s" "$ip"
        return 0
    fi

    ip=${SSH_CONNECTION%% *}
    if is_ipv4 "$ip"; then
        printf "%s" "$ip"
        return 0
    fi

    return 1
}

install_dependencies() {
    local packages

    if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
        packages=(curl iproute2 iptables dnsmasq)
    else
        packages=(curl iproute2 iptables)
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
            dnf install -y curl iproute iptables dnsmasq
        else
            dnf install -y curl iproute iptables
        fi
        dnf install -y iptables-services 2>/dev/null || true
    elif command -v yum >/dev/null 2>&1; then
        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            yum install -y curl iproute iptables iptables-services dnsmasq
        else
            yum install -y curl iproute iptables iptables-services
        fi
    elif command -v zypper >/dev/null 2>&1; then
        zypper --non-interactive install curl iproute2 iptables "${packages[@]:3}"
    elif command -v pacman >/dev/null 2>&1; then
        pacman -Sy --noconfirm --needed "${packages[@]}"
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash "${packages[@]}"
    else
        echo "Unsupported Linux distribution: no known package manager was found."
        echo "Install curl, iproute2/iproute, iptables, and optionally dnsmasq manually, then run 'sudo grex configure' again."
        exit 1
    fi
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

apply_configuration() {
    echo "Applying GREX configuration..."

    if has_systemd && [ -f /etc/systemd/system/gre-tunnel.service ]; then
        systemctl daemon-reload
        systemctl enable gre-tunnel
        systemctl restart gre-tunnel

        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
            systemctl enable --now dnsmasq
        else
            systemctl stop dnsmasq 2>/dev/null || true
            systemctl disable dnsmasq 2>/dev/null || true
        fi
    elif [ -x "$SCRIPT_DIR/gre-tunnel.sh" ]; then
        "$SCRIPT_DIR/gre-tunnel.sh"

        if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]] && command -v dnsmasq >/dev/null 2>&1; then
            if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -x dnsmasq >/dev/null 2>&1; then
                dnsmasq --conf-file=/etc/dnsmasq.d/tunnel.conf --pid-file=/run/grex-dnsmasq.pid
            fi
        fi
    else
        echo "Could not apply automatically because gre-tunnel.sh was not found."
        echo "Run 'sudo grex activate' after installation."
        return 0
    fi
}

# Collect configuration
echo "Please provide the following configuration details:"
echo

DETECTED_VPS_PUBLIC_IP=$(detect_public_ip || true)
DETECTED_ETH_INTERFACE=$(detect_default_interface)
DETECTED_ADMIN_IP=$(detect_admin_ip || true)
prompt VPS_PUBLIC_IP "VPS Public IP" "${DETECTED_VPS_PUBLIC_IP:-130.x.x.x}"
prompt FORTI_PUBLIC_IP "FortiGate Public IP" "93.x.x.x"
prompt INTERNAL_SUBNETS "Internal subnets (comma-separated)" "192.168.0.0/16,172.16.0.0/12"
prompt ENABLE_DNSMASQ "Enable local DNS server with dnsmasq? (yes/no)" "yes"
if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    prompt DNS_SERVERS "Upstream DNS servers (comma-separated)" "1.1.1.1,8.8.8.8"
else
    DNS_SERVERS=""
fi
prompt ETH_INTERFACE "Ethernet interface" "$DETECTED_ETH_INTERFACE"
prompt VPS_TUNNEL_IP "VPS tunnel IP with mask" "10.10.10.2/30"
prompt FORTI_TUNNEL_IP "FortiGate tunnel IP" "10.10.10.1"
prompt GRE_IF "GRE interface" "gre-forti"
prompt GRE_KEY "GRE key (blank for no key)" ""
prompt GRE_MTU "GRE interface MTU" "1400"
prompt MSS_MODE "TCP MSS mode (fixed/clamp/off)" "fixed"
if [ "$MSS_MODE" = "fixed" ]; then
    prompt MSS_VALUE "TCP MSS value" "1360"
else
    MSS_VALUE=""
fi
prompt ENABLE_HARDENING "Enable VPS firewall hardening? (yes/no)" "yes"
if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    prompt ADMIN_IP "Admin SSH source IP or CIDR" "${DETECTED_ADMIN_IP:-x.x.x.x}"
    prompt ALLOW_ICMP "Allow ICMP/ping to VPS? (yes/no)" "yes"
else
    ADMIN_IP=""
    ALLOW_ICMP="yes"
fi

# Create config file
cat > /etc/gre-tunnel.conf << EOF
VPS_PUBLIC_IP=$VPS_PUBLIC_IP
FORTI_PUBLIC_IP=$FORTI_PUBLIC_IP
INTERNAL_SUBNETS=$INTERNAL_SUBNETS
ENABLE_DNSMASQ=$ENABLE_DNSMASQ
DNS_SERVERS=$DNS_SERVERS
ETH_INTERFACE=$ETH_INTERFACE
VPS_TUNNEL_IP=$VPS_TUNNEL_IP
FORTI_TUNNEL_IP=$FORTI_TUNNEL_IP
GRE_IF=$GRE_IF
GRE_KEY=$GRE_KEY
GRE_MTU=$GRE_MTU
MSS_MODE=$MSS_MODE
MSS_VALUE=$MSS_VALUE
ENABLE_HARDENING=$ENABLE_HARDENING
ADMIN_IP=$ADMIN_IP
ALLOW_ICMP=$ALLOW_ICMP
EOF

echo "Configuration saved to /etc/gre-tunnel.conf"

# Install dependencies
echo "Installing dependencies..."
install_dependencies

# Enable IP forwarding
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1
if grep -q '^net.ipv4.ip_forward=' /etc/sysctl.conf 2>/dev/null; then
    sed -i 's/^net.ipv4.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
else
    echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi

if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

if [[ "$ENABLE_DNSMASQ" =~ ^(yes|y|Y)$ ]]; then
    # Configure dnsmasq
    echo "Configuring DNS..."
    systemctl stop dnsmasq 2>/dev/null || true
    mkdir -p /etc/dnsmasq.d
    cat > /etc/dnsmasq.d/tunnel.conf << EOF
bind-dynamic
no-resolv
EOF

    listen_ip=$(echo "$VPS_TUNNEL_IP" | cut -d'/' -f1)
    echo "interface=$GRE_IF" >> /etc/dnsmasq.d/tunnel.conf
    echo "listen-address=$listen_ip" >> /etc/dnsmasq.d/tunnel.conf

    for dns in $(echo $DNS_SERVERS | tr ',' ' '); do
        echo "server=$dns" >> /etc/dnsmasq.d/tunnel.conf
    done
fi

apply_configuration

echo "Setup complete. GREX configuration has been applied."
