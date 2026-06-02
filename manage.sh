#!/bin/bash

# GRE Tunnel Management Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/gre-tunnel.conf"

run_as_root() {
    if [ "$EUID" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "This command must run as root or have sudo installed." >&2
            exit 1
        fi
        sudo "$@"
    else
        "$@"
    fi
}

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

dns_enabled() {
    [[ "${ENABLE_DNSMASQ:-yes}" =~ ^(yes|y|Y)$ ]]
}

show_gre_tunnel_failure() {
    echo "gre-tunnel service failed to start."
    echo
    echo "=== gre-tunnel status ==="
    run_as_root systemctl status gre-tunnel --no-pager -l 2>/dev/null || true
    echo
    echo "=== gre-tunnel logs ==="
    if command -v journalctl >/dev/null 2>&1; then
        run_as_root journalctl -u gre-tunnel -n 100 --no-pager 2>/dev/null || true
    else
        echo "journalctl is not available"
    fi
}

start_dnsmasq_if_enabled() {
    dns_enabled || return 0

    if has_systemd; then
        if systemctl list-unit-files | grep -q '^dnsmasq'; then
            run_as_root systemctl enable --now dnsmasq
        fi
    elif command -v dnsmasq >/dev/null 2>&1; then
        if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -x dnsmasq >/dev/null 2>&1; then
            run_as_root dnsmasq --conf-file=/etc/dnsmasq.d/tunnel.conf --pid-file=/run/grex-dnsmasq.pid
        fi
    else
        echo "dnsmasq is enabled in config but the dnsmasq command was not found."
    fi
}

stop_dnsmasq_if_running() {
    if has_systemd; then
        run_as_root systemctl stop dnsmasq 2>/dev/null || true
    elif [ -f /run/grex-dnsmasq.pid ]; then
        run_as_root kill "$(cat /run/grex-dnsmasq.pid)" 2>/dev/null || true
        run_as_root rm -f /run/grex-dnsmasq.pid
    fi
}

usage() {
    echo "Usage: $0 {help|configure|edit|activate|deactivate|enable|disable|start|stop|status|logs|health|check}"
    exit "${1:-1}"
}

run_configure() {
    if [ -x "$SCRIPT_DIR/setup.sh" ]; then
        run_as_root bash "$SCRIPT_DIR/setup.sh"
    else
        echo "setup.sh not found in $SCRIPT_DIR"
        exit 1
    fi
}

truthy() {
    [[ "${1:-}" =~ ^(yes|y|true|1|on|Y|TRUE)$ ]]
}

trim() {
    local value=$1
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf "%s" "$value"
}

normalize_config() {
    local legacy_public_var
    local legacy_tunnel_var
    local legacy_tunnel_1_var

    legacy_public_var="FO""RTI_PUBLIC_IP"
    legacy_tunnel_var="FO""RTI_TUNNEL_IP"
    legacy_tunnel_1_var="TUNNEL_1_FO""RTI_IP"

    VPS_PUBLIC_IP=${VPS_PUBLIC_IP:-}
    REMOTE_PUBLIC_IP=${REMOTE_PUBLIC_IP:-${!legacy_public_var:-}}
    INTERNAL_SUBNETS=${INTERNAL_SUBNETS:-}
    ENABLE_DNSMASQ=${ENABLE_DNSMASQ:-yes}
    DNS_SERVERS=${DNS_SERVERS:-}
    ETH_INTERFACE=${ETH_INTERFACE:-eth0}
    VPS_TUNNEL_IP=${VPS_TUNNEL_IP:-${TUNNEL_1_VPS_IP:-}}
    REMOTE_TUNNEL_IP=${REMOTE_TUNNEL_IP:-${!legacy_tunnel_var:-${!legacy_tunnel_1_var:-}}}
    GRE_IF=${GRE_IF:-${TUNNEL_1_GRE_IF:-grex}}
    GRE_KEY=${GRE_KEY:-}
    GRE_MTU=${GRE_MTU:-1400}
    MSS_MODE=${MSS_MODE:-fixed}
    MSS_VALUE=${MSS_VALUE:-1360}
    ENABLE_HARDENING=${ENABLE_HARDENING:-yes}
    ADMIN_IPS=${ADMIN_IPS:-${ADMIN_IP:-}}
    ALLOW_ICMP=${ALLOW_ICMP:-yes}
    ENABLE_SYSCTL_HARDENING=${ENABLE_SYSCTL_HARDENING:-yes}
    SYSCTL_PROFILE=${SYSCTL_PROFILE:-safe}
    RP_FILTER=${RP_FILTER:-2}
    TCP_TIMESTAMPS=${TCP_TIMESTAMPS:-1}
    LOG_MARTIANS=${LOG_MARTIANS:-yes}
    DISABLE_IPV6=${DISABLE_IPV6:-no}
    NF_CONNTRACK_MAX=${NF_CONNTRACK_MAX:-262144}
    ENABLE_FAIL2BAN=${ENABLE_FAIL2BAN:-yes}
    FAIL2BAN_SSHD_ENABLED=${FAIL2BAN_SSHD_ENABLED:-true}
    FAIL2BAN_SSHD_PORT=${FAIL2BAN_SSHD_PORT:-22}
    FAIL2BAN_SSHD_MAXRETRY=${FAIL2BAN_SSHD_MAXRETRY:-3}
    FAIL2BAN_SSHD_FINDTIME=${FAIL2BAN_SSHD_FINDTIME:-10m}
    FAIL2BAN_SSHD_BANTIME=${FAIL2BAN_SSHD_BANTIME:-1h}
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Run 'sudo grex configure' first."
        return 1
    fi

    source "$CONFIG_FILE"
    normalize_config
}

write_config() {
    run_as_root bash -c "cat > '$CONFIG_FILE'" << EOF
VPS_PUBLIC_IP=$VPS_PUBLIC_IP
REMOTE_PUBLIC_IP=$REMOTE_PUBLIC_IP
INTERNAL_SUBNETS=$INTERNAL_SUBNETS
ENABLE_DNSMASQ=$ENABLE_DNSMASQ
DNS_SERVERS=$DNS_SERVERS
ETH_INTERFACE=$ETH_INTERFACE
VPS_TUNNEL_IP=$VPS_TUNNEL_IP
REMOTE_TUNNEL_IP=$REMOTE_TUNNEL_IP
GRE_IF=$GRE_IF
GRE_KEY=$GRE_KEY
GRE_MTU=$GRE_MTU
MSS_MODE=$MSS_MODE
MSS_VALUE=$MSS_VALUE
ENABLE_HARDENING=$ENABLE_HARDENING
ADMIN_IPS=$ADMIN_IPS
ALLOW_ICMP=$ALLOW_ICMP
ENABLE_SYSCTL_HARDENING=$ENABLE_SYSCTL_HARDENING
SYSCTL_PROFILE=$SYSCTL_PROFILE
RP_FILTER=$RP_FILTER
TCP_TIMESTAMPS=$TCP_TIMESTAMPS
LOG_MARTIANS=$LOG_MARTIANS
DISABLE_IPV6=$DISABLE_IPV6
NF_CONNTRACK_MAX=$NF_CONNTRACK_MAX
ENABLE_FAIL2BAN=$ENABLE_FAIL2BAN
FAIL2BAN_SSHD_ENABLED=$FAIL2BAN_SSHD_ENABLED
FAIL2BAN_SSHD_PORT=$FAIL2BAN_SSHD_PORT
FAIL2BAN_SSHD_MAXRETRY=$FAIL2BAN_SSHD_MAXRETRY
FAIL2BAN_SSHD_FINDTIME=$FAIL2BAN_SSHD_FINDTIME
FAIL2BAN_SSHD_BANTIME=$FAIL2BAN_SSHD_BANTIME
EOF
}

configure_dnsmasq_file() {
    if ! dns_enabled; then
        stop_dnsmasq_if_running
        if has_systemd; then
            run_as_root systemctl disable dnsmasq 2>/dev/null || true
        fi
        return 0
    fi

    if ! command -v dnsmasq >/dev/null 2>&1 && ! { has_systemd && systemctl list-unit-files | grep -q '^dnsmasq'; }; then
        echo "dnsmasq is enabled but dnsmasq was not found. Install it or disable DNS."
        return 0
    fi

    local listen_ip
    listen_ip=$(echo "$VPS_TUNNEL_IP" | cut -d'/' -f1)

    run_as_root mkdir -p /etc/dnsmasq.d
    run_as_root bash -c "cat > /etc/dnsmasq.d/tunnel.conf" << EOF
bind-dynamic
no-resolv
interface=$GRE_IF
listen-address=$listen_ip
EOF

    local dns
    for dns in ${DNS_SERVERS//,/ }; do
        dns=$(trim "$dns")
        [ -n "$dns" ] || continue
        run_as_root bash -c "printf '%s\n' 'server=$dns' >> /etc/dnsmasq.d/tunnel.conf"
    done
}

configure_fail2ban_from_config() {
    if ! truthy "$ENABLE_FAIL2BAN"; then
        run_as_root rm -f /etc/fail2ban/jail.d/grex-sshd.local
        if has_systemd && systemctl list-unit-files | grep -q '^fail2ban'; then
            run_as_root systemctl restart fail2ban 2>/dev/null || true
        fi
        return 0
    fi

    if ! command -v fail2ban-server >/dev/null 2>&1; then
        echo "fail2ban is enabled but fail2ban-server was not found."
        return 0
    fi

    local ignore_ips
    ignore_ips="127.0.0.1/8 ::1"
    if [ -n "${ADMIN_IPS:-}" ]; then
        ignore_ips="$ignore_ips ${ADMIN_IPS//,/ }"
    fi

    run_as_root mkdir -p /etc/fail2ban/jail.d
    run_as_root bash -c "cat > /etc/fail2ban/jail.d/grex-sshd.local" << EOF
[sshd]
enabled = $FAIL2BAN_SSHD_ENABLED
port = $FAIL2BAN_SSHD_PORT
maxretry = $FAIL2BAN_SSHD_MAXRETRY
findtime = $FAIL2BAN_SSHD_FINDTIME
bantime = $FAIL2BAN_SSHD_BANTIME
ignoreip = $ignore_ips
EOF

    if has_systemd; then
        run_as_root systemctl enable --now fail2ban
        run_as_root systemctl restart fail2ban
    elif command -v service >/dev/null 2>&1; then
        run_as_root service fail2ban restart 2>/dev/null || run_as_root service fail2ban start 2>/dev/null || true
    fi
}

apply_saved_config() {
    load_config || return 1
    configure_dnsmasq_file
    configure_fail2ban_from_config
    if [ -x "$SCRIPT_DIR/gre-sysctl.sh" ]; then
        run_as_root "$SCRIPT_DIR/gre-sysctl.sh"
    fi
    activate
}

edit_config_value() {
    local var_name=$1
    local label=$2
    local current_value
    local new_value

    current_value=${!var_name}
    echo
    echo "$label"
    echo "Current: ${current_value:-<blank>}"
    read -r -p "New value (leave blank to keep current, type <blank> to clear): " new_value
    if [ "$new_value" = "<blank>" ]; then
        printf -v "$var_name" "%s" ""
        write_config
        echo "Cleared $var_name."
    elif [ -n "$new_value" ]; then
        printf -v "$var_name" "%s" "$new_value"
        write_config
        echo "Saved $var_name."
    else
        echo "No change."
    fi
    read -p "Press Enter to continue..." _
}

edit_config_menu() {
    load_config || {
        read -p "Press Enter to continue..." _
        return 0
    }

    while true; do
        clear
        echo "========================================"
        echo "        GREX Configuration Editor        "
        echo "========================================"
        echo " 1) VPS public IP                 [$VPS_PUBLIC_IP]"
        echo " 2) Remote gateway public IP      [$REMOTE_PUBLIC_IP]"
        echo " 3) Internal subnets              [$INTERNAL_SUBNETS]"
        echo " 4) DNS enabled                   [$ENABLE_DNSMASQ]"
        echo " 5) Upstream DNS servers          [$DNS_SERVERS]"
        echo " 6) Ethernet egress interface     [$ETH_INTERFACE]"
        echo " 7) VPS tunnel IP                 [$VPS_TUNNEL_IP]"
        echo " 8) Remote gateway tunnel IP      [$REMOTE_TUNNEL_IP]"
        echo " 9) GRE interface                 [$GRE_IF]"
        echo "10) GRE key                       [${GRE_KEY:-<blank>}]"
        echo "11) GRE MTU                       [$GRE_MTU]"
        echo "12) TCP MSS mode                  [$MSS_MODE]"
        echo "13) TCP MSS value                 [$MSS_VALUE]"
        echo "14) Firewall hardening enabled    [$ENABLE_HARDENING]"
        echo "15) Admin SSH source IPs/CIDRs    [$ADMIN_IPS]"
        echo "16) Allow ICMP                    [$ALLOW_ICMP]"
        echo "17) Sysctl hardening enabled      [$ENABLE_SYSCTL_HARDENING]"
        echo "18) Sysctl profile                [$SYSCTL_PROFILE]"
        echo "19) rp_filter                     [$RP_FILTER]"
        echo "20) TCP timestamps                [$TCP_TIMESTAMPS]"
        echo "21) Log martians                  [$LOG_MARTIANS]"
        echo "22) Disable IPv6                  [$DISABLE_IPV6]"
        echo "23) nf_conntrack_max              [$NF_CONNTRACK_MAX]"
        echo "24) fail2ban enabled              [$ENABLE_FAIL2BAN]"
        echo "25) fail2ban sshd enabled         [$FAIL2BAN_SSHD_ENABLED]"
        echo "26) fail2ban sshd port            [$FAIL2BAN_SSHD_PORT]"
        echo "27) fail2ban maxretry             [$FAIL2BAN_SSHD_MAXRETRY]"
        echo "28) fail2ban findtime             [$FAIL2BAN_SSHD_FINDTIME]"
        echo "29) fail2ban bantime              [$FAIL2BAN_SSHD_BANTIME]"
        echo "A) Apply saved configuration"
        echo "0) Back"
        echo
        read -r -p "Choose an option: " edit_choice
        case "$edit_choice" in
            1) edit_config_value VPS_PUBLIC_IP "VPS public IP" ;;
            2) edit_config_value REMOTE_PUBLIC_IP "Remote gateway public IP" ;;
            3) edit_config_value INTERNAL_SUBNETS "Internal subnets (comma-separated)" ;;
            4) edit_config_value ENABLE_DNSMASQ "Enable DNS with dnsmasq? (yes/no)" ;;
            5) edit_config_value DNS_SERVERS "Upstream DNS servers (comma-separated)" ;;
            6) edit_config_value ETH_INTERFACE "Ethernet egress interface" ;;
            7) edit_config_value VPS_TUNNEL_IP "VPS tunnel IP with mask" ;;
            8) edit_config_value REMOTE_TUNNEL_IP "Remote gateway tunnel IP" ;;
            9) edit_config_value GRE_IF "GRE interface" ;;
            10) edit_config_value GRE_KEY "GRE key (blank for no key)" ;;
            11) edit_config_value GRE_MTU "GRE MTU" ;;
            12) edit_config_value MSS_MODE "TCP MSS mode (fixed/clamp/off)" ;;
            13) edit_config_value MSS_VALUE "TCP MSS value" ;;
            14) edit_config_value ENABLE_HARDENING "Enable firewall hardening? (yes/no)" ;;
            15) edit_config_value ADMIN_IPS "Admin SSH source IPs/CIDRs (comma-separated)" ;;
            16) edit_config_value ALLOW_ICMP "Allow ICMP? (yes/no)" ;;
            17) edit_config_value ENABLE_SYSCTL_HARDENING "Enable sysctl hardening? (yes/no)" ;;
            18) edit_config_value SYSCTL_PROFILE "Sysctl profile (safe/strict/custom)" ;;
            19) edit_config_value RP_FILTER "rp_filter (2 loose, 1 strict, 0 off)" ;;
            20) edit_config_value TCP_TIMESTAMPS "TCP timestamps (1 on, 0 off)" ;;
            21) edit_config_value LOG_MARTIANS "Log martians? (yes/no)" ;;
            22) edit_config_value DISABLE_IPV6 "Disable IPv6? (yes/no)" ;;
            23) edit_config_value NF_CONNTRACK_MAX "nf_conntrack_max" ;;
            24) edit_config_value ENABLE_FAIL2BAN "Enable fail2ban? (yes/no)" ;;
            25) edit_config_value FAIL2BAN_SSHD_ENABLED "fail2ban sshd enabled (true/false)" ;;
            26) edit_config_value FAIL2BAN_SSHD_PORT "fail2ban sshd port" ;;
            27) edit_config_value FAIL2BAN_SSHD_MAXRETRY "fail2ban maxretry" ;;
            28) edit_config_value FAIL2BAN_SSHD_FINDTIME "fail2ban findtime" ;;
            29) edit_config_value FAIL2BAN_SSHD_BANTIME "fail2ban bantime" ;;
            A|a)
                apply_saved_config
                read -p "Press Enter to continue..." _
                ;;
            0)
                return 0
                ;;
            *)
                echo "Invalid selection."
                read -p "Press Enter to continue..." _
                ;;
        esac
        load_config >/dev/null 2>&1 || true
    done
}

activate() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Run 'sudo grex configure' first."
        exit 1
    fi
    source "$CONFIG_FILE"
    normalize_config
    if has_systemd; then
        run_as_root systemctl daemon-reload
        run_as_root systemctl enable gre-tunnel
        if ! run_as_root systemctl restart gre-tunnel; then
            show_gre_tunnel_failure
            exit 1
        fi
    else
        run_as_root "$SCRIPT_DIR/gre-tunnel.sh"
    fi
    start_dnsmasq_if_enabled
    echo "GRE tunnel activated."
}

deactivate() {
    stop_dnsmasq_if_running
    if has_systemd; then
        run_as_root systemctl stop gre-tunnel 2>/dev/null || true
        run_as_root systemctl disable gre-tunnel 2>/dev/null || true
        run_as_root systemctl disable dnsmasq 2>/dev/null || true
    fi
    run_as_root "$SCRIPT_DIR/gre-tunnel-stop.sh" || true
    echo "GRE tunnel deactivated."
}

menu() {
    while true; do
        clear
        echo "========================================"
        echo "          GREX Egress Gateway           "
        echo "========================================"
        echo "1) Help & Introduction"
        echo "2) Configure GREX System (Wizard)"
        echo "3) Edit GREX Configuration"
        echo "4) Activate GREX System"
        echo "5) Deactivate GREX System"
        echo "6) Health Check"
        echo "7) Logs"
        echo "0) Exit"
        echo
        read -p "Choose an option [0-7]: " choice
        case "$choice" in
            1)
                echo
                echo "GREX is a GRE tunnel egress management toolkit."
                echo "Use configure to create /etc/gre-tunnel.conf, activate to bring the tunnel up,"
                echo "edit to change one setting at a time, health to verify config, and logs to inspect service output."
                read -p "Press Enter to continue..." _
                ;;
            2)
                run_configure
                read -p "Press Enter to continue..." _
                ;;
            3)
                edit_config_menu
                ;;
            4)
                activate
                read -p "Press Enter to continue..." _
                ;;
            5)
                deactivate
                read -p "Press Enter to continue..." _
                ;;
            6)
                run_as_root "$SCRIPT_DIR/health.sh"
                read -p "Press Enter to continue..." _
                ;;
            7)
                echo "=== gre-tunnel logs ==="
                if has_systemd && command -v journalctl >/dev/null 2>&1; then
                    run_as_root journalctl -u gre-tunnel -n 50 --no-pager
                else
                    echo "systemd journal is not available"
                fi
                echo "=== dnsmasq logs ==="
                if has_systemd && command -v journalctl >/dev/null 2>&1; then
                    run_as_root journalctl -u dnsmasq -n 50 --no-pager 2>/dev/null || echo "dnsmasq logs are not available"
                else
                    echo "dnsmasq logs are not available"
                fi
                read -p "Press Enter to continue..." _
                ;;
            0)
                exit 0
                ;;
            *)
                echo "Invalid selection."
                read -p "Press Enter to continue..." _
                ;;
        esac
    done
}

if [ $# -eq 0 ]; then
    menu
    exit 0
fi

COMMAND=$1
case $COMMAND in
    help)
        usage 0
        ;;
    configure)
        run_configure
        ;;
    edit)
        edit_config_menu
        ;;
    activate)
        activate
        ;;
    deactivate)
        deactivate
        ;;
    enable)
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        fi
        if has_systemd; then
            run_as_root systemctl enable gre-tunnel
            if dns_enabled && systemctl list-unit-files | grep -q '^dnsmasq'; then
                run_as_root systemctl enable dnsmasq
            fi
            echo "GRE tunnel service enabled"
        else
            echo "enable requires systemd; use 'sudo grex activate' to start GREX directly on this system."
        fi
        ;;
    disable)
        if has_systemd; then
            run_as_root systemctl disable gre-tunnel
            run_as_root systemctl disable dnsmasq 2>/dev/null || true
            echo "GRE tunnel service disabled"
        else
            echo "disable requires systemd; no persistent service was disabled."
        fi
        ;;
    start)
        if [ -f "$CONFIG_FILE" ]; then
            source "$CONFIG_FILE"
        fi
        if has_systemd; then
            run_as_root systemctl start gre-tunnel
        else
            run_as_root "$SCRIPT_DIR/gre-tunnel.sh"
        fi
        start_dnsmasq_if_enabled
        echo "GRE tunnel started"
        ;;
    stop)
        stop_dnsmasq_if_running
        if has_systemd; then
            run_as_root systemctl stop gre-tunnel
        else
            run_as_root "$SCRIPT_DIR/gre-tunnel-stop.sh"
        fi
        echo "GRE tunnel stopped"
        ;;
    status)
        echo "GRE Tunnel Status:"
        if has_systemd; then
            run_as_root systemctl status gre-tunnel --no-pager -l
        else
            run_as_root "$SCRIPT_DIR/health.sh"
        fi
        echo
        echo "DNS Service Status:"
        if has_systemd; then
            run_as_root systemctl status dnsmasq --no-pager -l 2>/dev/null || echo "dnsmasq is not installed or not available"
        elif command -v pgrep >/dev/null 2>&1 && pgrep -x dnsmasq >/dev/null 2>&1; then
            echo "dnsmasq is running"
        else
            echo "dnsmasq is not running"
        fi
        ;;
    logs)
        echo "GRE Tunnel Logs:"
        if has_systemd && command -v journalctl >/dev/null 2>&1; then
            run_as_root journalctl -u gre-tunnel -n 50 --no-pager
        else
            echo "systemd journal is not available"
        fi
        echo
        echo "DNS Logs:"
        if has_systemd && command -v journalctl >/dev/null 2>&1; then
            run_as_root journalctl -u dnsmasq -n 50 --no-pager 2>/dev/null || echo "dnsmasq logs are not available"
        else
            echo "dnsmasq logs are not available"
        fi
        ;;
    health)
        run_as_root "$SCRIPT_DIR/health.sh"
        ;;
    check)
        run_as_root "$SCRIPT_DIR/check.sh"
        ;;
    *)
        usage
        ;;
esac
