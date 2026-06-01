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

normalize_config() {
    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    FORTI_TUNNEL_IP=${FORTI_TUNNEL_IP:-${TUNNEL_1_FORTI_IP:-}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-gre-forti}}
    GRE_KEY=${GRE_KEY:-}
    ENABLE_HARDENING=${ENABLE_HARDENING:-no}
}

normalize_config

# Check if tunnel interface exists and is administratively up
if [ -z "$GRE_IF" ]; then
    set_status "CRITICAL"
    ISSUES+=("GRE interface is not configured")
elif ! ip link show "$GRE_IF" &>/dev/null; then
    set_status "CRITICAL"
    ISSUES+=("Tunnel interface $GRE_IF does not exist")
    MISSING_TUNNELS=1
elif ! ip link show dev "$GRE_IF" 2>/dev/null | grep -q "<[^>]*UP"; then
    set_status "CRITICAL"
    ISSUES+=("Tunnel interface $GRE_IF is not UP")
fi

# Check routes
ROUTE_COUNT=$(ip route show | grep -c "$GRE_IF" || true)

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

# Check firewall hardening state
if [[ "$ENABLE_HARDENING" =~ ^(yes|y|Y)$ ]]; then
    if ! iptables -C INPUT -j GREX-INPUT 2>/dev/null; then
        set_status "WARNING"
        ISSUES+=("Hardening is enabled but GREX-INPUT is not attached to INPUT")
    fi
    if [ "$(iptables -S INPUT 2>/dev/null | awk '/^-P INPUT/ {print $3}')" != "DROP" ]; then
        set_status "WARNING"
        ISSUES+=("Hardening is enabled but INPUT policy is not DROP")
    fi
    if [ "$(iptables -S FORWARD 2>/dev/null | awk '/^-P FORWARD/ {print $3}')" != "DROP" ]; then
        set_status "WARNING"
        ISSUES+=("Hardening is enabled but FORWARD policy is not DROP")
    fi
fi

# Check public FortiGate reachability separately from tunnel reachability.
if [ -n "${FORTI_PUBLIC_IP:-}" ]; then
    if ping -c 1 -W 2 "$FORTI_PUBLIC_IP" &>/dev/null; then
        NOTES+=("FortiGate public IP $FORTI_PUBLIC_IP responds to ICMP; this does not prove the GRE tunnel is up")
    else
        NOTES+=("FortiGate public IP $FORTI_PUBLIC_IP did not respond to ICMP; GRE may still work if ICMP is blocked")
    fi
fi

if [ -n "$GRE_KEY" ]; then
    NOTES+=("GRE key is set to $GRE_KEY; FortiGate must have the same 'set key $GRE_KEY'")
else
    NOTES+=("GRE key is disabled; FortiGate gre-tunnel should not have a 'set key' value")
fi

# Check connectivity
if [ -z "$FORTI_TUNNEL_IP" ]; then
    set_status "CRITICAL"
    ISSUES+=("FortiGate tunnel IP is not configured")
elif ! ping -c 1 -W 2 "$FORTI_TUNNEL_IP" &>/dev/null; then
    set_status "CRITICAL"
    ISSUES+=("Cannot ping FortiGate tunnel IP $FORTI_TUNNEL_IP")
fi

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
