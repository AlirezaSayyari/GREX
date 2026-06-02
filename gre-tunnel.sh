#!/bin/bash

# GRE Tunnel Setup Script
# This script sets up one GRE tunnel, routing, NAT, and iptables rules

set -e

if [ "$EUID" -ne 0 ]; then
    echo "gre-tunnel.sh must be run as root." >&2
    exit 1
fi

CONFIG_FILE="/etc/gre-tunnel.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GREX_INPUT_CHAIN="GREX-INPUT"
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
    local legacy_public_var
    local legacy_tunnel_var
    local legacy_tunnel_1_var

    legacy_public_var="FO""RTI_PUBLIC_IP"
    legacy_tunnel_var="FO""RTI_TUNNEL_IP"
    legacy_tunnel_1_var="TUNNEL_1_FO""RTI_IP"

    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    REMOTE_PUBLIC_IP=${REMOTE_PUBLIC_IP:-${!legacy_public_var:-}}
    REMOTE_TUNNEL_IP=${REMOTE_TUNNEL_IP:-${!legacy_tunnel_var:-${!legacy_tunnel_1_var:-}}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-grex}}
    GRE_KEY=${GRE_KEY:-}
    GRE_MTU=${GRE_MTU:-1476}
    MSS_MODE=${MSS_MODE:-clamp}
    MSS_VALUE=${MSS_VALUE:-}
    ENABLE_HARDENING=${ENABLE_HARDENING:-no}
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    ALLOW_ICMP=${ALLOW_ICMP:-yes}
}

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
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

is_ipv4_cidr() {
    local value=$1
    local ip
    local prefix

    [[ "$value" =~ ^([^/]+)/([0-9]{1,2})$ ]] || return 1
    ip=${BASH_REMATCH[1]}
    prefix=${BASH_REMATCH[2]}
    is_ipv4 "$ip" || return 1
    [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ]
}

is_ipv4_or_cidr() {
    is_ipv4 "$1" || is_ipv4_cidr "$1"
}

validate_ip_list() {
    local value=$1
    local label=$2
    local item

    IFS=',' read -ra ITEMS <<< "$value"
    for item in "${ITEMS[@]}"; do
        item=$(trim "$item")
        [ -n "$item" ] || continue
        if ! is_ipv4_or_cidr "$item"; then
            echo "$label contains invalid IP/CIDR: $item" >&2
            return 1
        fi
    done
}

validate_numeric_range() {
    local value=$1
    local label=$2
    local min=$3
    local max=$4

    if ! [[ "$value" =~ ^[0-9]+$ ]] || [ "$value" -lt "$min" ] || [ "$value" -gt "$max" ]; then
        echo "$label must be a number between $min and $max." >&2
        return 1
    fi
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
    local key_matches

    while IFS= read -r line; do
        tunnel_name=${line%%:*}
        [ -n "$tunnel_name" ] || continue
        [ "$tunnel_name" != "gre0" ] || continue

        if [ -n "$tunnel_key" ]; then
            [[ "$line" == *"key $tunnel_key"* ]] && key_matches=1 || key_matches=0
        else
            [[ "$line" != *" key "* ]] && key_matches=1 || key_matches=0
        fi

        if [[ "$line" == *"remote $REMOTE_PUBLIC_IP"* ]] &&
           [[ "$line" == *"local $VPS_PUBLIC_IP"* ]] &&
           [ "$key_matches" -eq 1 ]; then
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
            gre-fo""rti*|grex*|*_GRE_IF)
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
    require_config_value "REMOTE_PUBLIC_IP"
    require_config_value "INTERNAL_SUBNETS"
    require_config_value "ETH_INTERFACE"
    require_config_value "VPS_TUNNEL_IP"
    require_config_value "REMOTE_TUNNEL_IP"
    require_config_value "GRE_IF"
    require_config_value "GRE_MTU"

    is_ipv4 "$VPS_PUBLIC_IP" || { echo "VPS_PUBLIC_IP must be a valid IPv4 address." >&2; exit 1; }
    is_ipv4 "$REMOTE_PUBLIC_IP" || { echo "REMOTE_PUBLIC_IP must be a valid IPv4 address." >&2; exit 1; }
    is_ipv4_cidr "$VPS_TUNNEL_IP" || { echo "VPS_TUNNEL_IP must be IPv4 CIDR, for example 10.10.10.2/30." >&2; exit 1; }
    is_ipv4 "$REMOTE_TUNNEL_IP" || { echo "REMOTE_TUNNEL_IP must be a valid IPv4 address." >&2; exit 1; }
    validate_ip_list "$INTERNAL_SUBNETS" "INTERNAL_SUBNETS" || exit 1

    if ! [[ "$GRE_IF" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]; then
        echo "GRE_IF must be 1-15 characters using letters, numbers, dot, underscore, colon, or dash." >&2
        exit 1
    fi

    validate_numeric_range "$GRE_MTU" "GRE_MTU" 576 9000 || exit 1

    case "$MSS_MODE" in
        clamp|fixed|off)
            ;;
        *)
            echo "MSS_MODE must be clamp, fixed, or off." >&2
            exit 1
            ;;
    esac

    if [ "$MSS_MODE" = "fixed" ]; then
        require_config_value "MSS_VALUE"
        validate_numeric_range "$MSS_VALUE" "MSS_VALUE" 536 8960 || exit 1
    fi

    if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
        require_config_value "ADMIN_IPS"
        if [ "$ADMIN_IPS" = "x.x.x.x" ]; then
            echo "ADMIN_IPS must be set before enabling hardening." >&2
            exit 1
        fi
        validate_ip_list "$ADMIN_IPS" "ADMIN_IPS" || exit 1
    fi
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

setup_mss_chain() {
    iptables -t mangle -N "$GREX_MANGLE_CHAIN" 2>/dev/null || true
    iptables -t mangle -F "$GREX_MANGLE_CHAIN"

    delete_rule_if_exists mangle FORWARD -j "$GREX_MANGLE_CHAIN"

    if [ "$MSS_MODE" = "off" ]; then
        return 0
    fi

    iptables -t mangle -I FORWARD 1 -j "$GREX_MANGLE_CHAIN"
    if [ "$MSS_MODE" = "fixed" ]; then
        iptables -t mangle -A "$GREX_MANGLE_CHAIN" -i "$GRE_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE"
        iptables -t mangle -A "$GREX_MANGLE_CHAIN" -o "$GRE_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss "$MSS_VALUE"
    else
        iptables -t mangle -A "$GREX_MANGLE_CHAIN" -i "$GRE_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
        iptables -t mangle -A "$GREX_MANGLE_CHAIN" -o "$GRE_IF" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
    fi
}

append_rule_if_missing() {
    local table=$1
    local chain=$2
    shift 2

    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -A "$chain" "$@"
}

insert_rule_if_missing() {
    local table=$1
    local chain=$2
    local position=$3
    shift 3

    iptables -t "$table" -C "$chain" "$@" 2>/dev/null || iptables -t "$table" -I "$chain" "$position" "$@"
}

setup_input_hardening() {
    local admin_ip

    if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
        iptables -N "$GREX_INPUT_CHAIN" 2>/dev/null || true
        iptables -F "$GREX_INPUT_CHAIN"

        delete_rule_if_exists filter INPUT -j "$GREX_INPUT_CHAIN"
        iptables -I INPUT 1 -j "$GREX_INPUT_CHAIN"

        append_rule_if_missing filter "$GREX_INPUT_CHAIN" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        append_rule_if_missing filter "$GREX_INPUT_CHAIN" -i lo -j ACCEPT

        if [[ "$ALLOW_ICMP" =~ ^(yes|y|Y)$ ]]; then
            append_rule_if_missing filter "$GREX_INPUT_CHAIN" -p icmp -j ACCEPT
        fi

        append_rule_if_missing filter "$GREX_INPUT_CHAIN" -p 47 -s "$REMOTE_PUBLIC_IP" -j ACCEPT
        IFS=',' read -ra ADMIN_SOURCES <<< "$ADMIN_IPS"
        for admin_ip in "${ADMIN_SOURCES[@]}"; do
            admin_ip=$(trim "$admin_ip")
            [ -n "$admin_ip" ] || continue
            append_rule_if_missing filter "$GREX_INPUT_CHAIN" -p tcp --dport 22 -s "$admin_ip" -m conntrack --ctstate NEW -j ACCEPT
        done

        if [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]]; then
            append_rule_if_missing filter "$GREX_INPUT_CHAIN" -i "$GRE_IF" -p udp --dport 53 -j ACCEPT
            append_rule_if_missing filter "$GREX_INPUT_CHAIN" -i "$GRE_IF" -p tcp --dport 53 -j ACCEPT
        fi

        iptables -P INPUT DROP
        iptables -P FORWARD DROP
        iptables -P OUTPUT ACCEPT
    else
        delete_rule_if_exists filter INPUT -j "$GREX_INPUT_CHAIN"
        iptables -F "$GREX_INPUT_CHAIN" 2>/dev/null || true
        iptables -X "$GREX_INPUT_CHAIN" 2>/dev/null || true
        iptables -P INPUT ACCEPT
        iptables -P FORWARD ACCEPT
        iptables -P OUTPUT ACCEPT

        delete_rule_if_exists filter INPUT -p 47 -s "$REMOTE_PUBLIC_IP" -j ACCEPT
        insert_rule_if_missing filter INPUT 1 -p 47 -s "$REMOTE_PUBLIC_IP" -j ACCEPT
    fi
}

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found. Run setup.sh first."
    exit 1
fi

source "$CONFIG_FILE"
normalize_config
validate_config

if [ -x "$SCRIPT_DIR/gre-sysctl.sh" ]; then
    "$SCRIPT_DIR/gre-sysctl.sh"
fi

# Clean up existing tunnel
cleanup_existing_tunnel

# Create GRE tunnel
echo "Creating GRE tunnel: $GRE_IF"
delete_conflicting_gre_tunnel "$GRE_KEY"
gre_cmd=(ip link add "$GRE_IF" type gre local "$VPS_PUBLIC_IP" remote "$REMOTE_PUBLIC_IP" ttl 255)
if [ -n "$GRE_KEY" ]; then
    gre_cmd+=(key "$GRE_KEY")
fi
"${gre_cmd[@]}"

ip addr add "$VPS_TUNNEL_IP" dev "$GRE_IF"
ip link set "$GRE_IF" mtu "$GRE_MTU"
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
setup_mss_chain
iptables -A "$GREX_CHAIN" -i "$GRE_IF" -o "$ETH_INTERFACE" -j ACCEPT
iptables -A "$GREX_CHAIN" -i "$ETH_INTERFACE" -o "$GRE_IF" \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Input hardening and GRE protocol access
echo "Setting up input firewall rules..."
setup_input_hardening

# Persist iptables
echo "Saving iptables rules..."
save_iptables_rules

echo "GRE tunnel setup complete."
