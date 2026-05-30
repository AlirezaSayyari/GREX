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
    echo "Usage: $0 {help|configure|activate|deactivate|enable|disable|start|stop|status|logs|health|check}"
    exit 1
}

run_configure() {
    if [ -x "$SCRIPT_DIR/setup.sh" ]; then
        run_as_root bash "$SCRIPT_DIR/setup.sh"
    else
        echo "setup.sh not found in $SCRIPT_DIR"
        exit 1
    fi
}

activate() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Configuration not found. Run 'sudo grex configure' first."
        exit 1
    fi
    source "$CONFIG_FILE"
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
        echo "3) Activate GREX System"
        echo "4) Deactivate GREX System"
        echo "5) Health Check"
        echo "6) Logs"
        echo "0) Exit"
        echo
        read -p "Choose an option [0-6]: " choice
        case "$choice" in
            1)
                echo
                echo "GREX is a GRE tunnel egress management toolkit."
                echo "Use configure to create /etc/gre-tunnel.conf, activate to bring the tunnel up,"
                echo "health to verify config, and logs to inspect service output."
                read -p "Press Enter to continue..." _
                ;;
            2)
                run_configure
                read -p "Press Enter to continue..." _
                ;;
            3)
                activate
                read -p "Press Enter to continue..." _
                ;;
            4)
                deactivate
                read -p "Press Enter to continue..." _
                ;;
            5)
                run_as_root "$SCRIPT_DIR/health.sh"
                read -p "Press Enter to continue..." _
                ;;
            6)
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
        usage
        ;;
    configure)
        run_configure
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
