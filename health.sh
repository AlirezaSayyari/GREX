#!/bin/bash

# Health Check Script

CONFIG_FILE="/etc/gre-tunnel.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found."
    exit 1
fi

source "$CONFIG_FILE"

STATUS="OK"
ISSUES=()
NOTES=()
MISSING_TUNNELS=0

set_status() {
    local new_status=$1

    if [ "$new_status" = "CRITICAL" ]; then
        STATUS="CRITICAL"
    elif [ "$new_status" = "WARNING" ] && [ "$STATUS" != "CRITICAL" ]; then
        STATUS="WARNING"
    fi
}

get_config_value() {
    local var_name=$1
    printf "%s" "${!var_name}"
}

# Check if tunnel interfaces exist and are administratively up
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    gre_if=$(get_config_value "$gre_if_var")
    if [ -z "$gre_if" ]; then
        set_status "CRITICAL"
        ISSUES+=("Tunnel $i GRE interface is not configured")
        continue
    fi
    if ! ip link show "$gre_if" &>/dev/null; then
        set_status "CRITICAL"
        ISSUES+=("Tunnel interface $gre_if does not exist")
        MISSING_TUNNELS=$((MISSING_TUNNELS + 1))
    elif ! ip link show dev "$gre_if" 2>/dev/null | grep -q "<[^>]*UP"; then
        set_status "CRITICAL"
        ISSUES+=("Tunnel interface $gre_if is not UP")
    fi
done

# Check routes
ROUTE_COUNT=0
for ((i=1; i<=NUM_TUNNELS; i++)); do
    gre_if_var="TUNNEL_${i}_GRE_IF"
    gre_if=$(get_config_value "$gre_if_var")
    [ -n "$gre_if" ] || continue
    count=$(ip route show | grep -c "$gre_if" || true)
    ROUTE_COUNT=$((ROUTE_COUNT + count))
done

if [ "$ROUTE_COUNT" -eq 0 ]; then
    set_status "WARNING"
    ISSUES+=("No routes configured via tunnel")
fi

# Check NAT rules
NAT_MISSING=0
IFS=',' read -ra SUBNETS <<< "$INTERNAL_SUBNETS"
for subnet in "${SUBNETS[@]}"; do
    subnet="${subnet#"${subnet%%[![:space:]]*}"}"
    subnet="${subnet%"${subnet##*[![:space:]]}"}"
    [ -n "$subnet" ] || continue
    if ! iptables -t nat -C POSTROUTING -s "$subnet" -o "$ETH_INTERFACE" -j MASQUERADE 2>/dev/null; then
        NAT_MISSING=1
        ISSUES+=("Missing NAT rule for $subnet via $ETH_INTERFACE")
    fi
done

if [ "$NAT_MISSING" -eq 1 ]; then
    set_status "WARNING"
fi

# Check public FortiGate reachability separately from tunnel reachability.
if [ -n "${FORTI_PUBLIC_IP:-}" ]; then
    if ping -c 1 -W 2 "$FORTI_PUBLIC_IP" &>/dev/null; then
        NOTES+=("FortiGate public IP $FORTI_PUBLIC_IP responds to ICMP; this does not prove the GRE tunnel is up")
    else
        NOTES+=("FortiGate public IP $FORTI_PUBLIC_IP did not respond to ICMP; GRE may still work if ICMP is blocked")
    fi
fi

# Check connectivity
for ((i=1; i<=NUM_TUNNELS; i++)); do
    forti_ip_var="TUNNEL_${i}_FORTI_IP"
    forti_ip=$(get_config_value "$forti_ip_var")
    if [ -z "$forti_ip" ]; then
        set_status "CRITICAL"
        ISSUES+=("Tunnel $i FortiGate tunnel IP is not configured")
        continue
    fi
    if ! ping -c 1 -W 2 "$forti_ip" &>/dev/null; then
        set_status "CRITICAL"
        ISSUES+=("Cannot ping FortiGate tunnel IP for tunnel $i")
    fi
done

if [ "$MISSING_TUNNELS" -gt 0 ]; then
    NOTES+=("Run 'sudo grex activate', then check 'sudo journalctl -u gre-tunnel -n 100 --no-pager' if the tunnel interface is still missing")
fi

# Check dnsmasq
if [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]]; then
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        dnsmasq_running() {
            systemctl is-active --quiet dnsmasq
        }
    else
        dnsmasq_running() {
            command -v pgrep >/dev/null 2>&1 && pgrep -x dnsmasq >/dev/null 2>&1
        }
    fi

    if ! dnsmasq_running; then
        set_status "WARNING"
        ISSUES+=("dnsmasq service is not running")
    fi
fi

# Output
echo "Status: $STATUS"
if [ ${#ISSUES[@]} -gt 0 ]; then
    echo "Issues:"
    for issue in "${ISSUES[@]}"; do
        echo "  - $issue"
    done
else
    echo "All checks passed"
fi

if [ ${#NOTES[@]} -gt 0 ]; then
    echo "Notes:"
    for note in "${NOTES[@]}"; do
        echo "  - $note"
    done
fi

exit 0
