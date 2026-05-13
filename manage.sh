#!/bin/bash

# GRE Tunnel Management Script

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="/etc/gre-tunnel.conf"

usage() {
    echo "Usage: $0 {help|configure|activate|deactivate|enable|disable|start|stop|status|logs|health|check}"
    exit 1
}

run_configure() {
    if [ -x "$SCRIPT_DIR/setup.sh" ]; then
        sudo bash "$SCRIPT_DIR/setup.sh"
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
    sudo "$SCRIPT_DIR/gre-tunnel.sh"
    sudo systemctl daemon-reload
    sudo systemctl enable --now gre-tunnel
    if systemctl list-unit-files | grep -q '^dnsmasq'; then
        sudo systemctl enable --now dnsmasq
    fi
    echo "GRE tunnel activated."
}

deactivate() {
    sudo systemctl stop dnsmasq 2>/dev/null || true
    sudo systemctl stop gre-tunnel 2>/dev/null || true
    sudo systemctl disable gre-tunnel 2>/dev/null || true
    sudo systemctl disable dnsmasq 2>/dev/null || true
    sudo "$SCRIPT_DIR/gre-tunnel-stop.sh" || true
    echo "GRE tunnel deactivated."
}

menu() {
    while true; do
        clear
        echo "========================================"
        echo "          GREX Egress Gateway           "
        echo "========================================"
        echo "1) Help & Introduction"
        echo "2) Configure Egress System (Wizard)"
        echo "3) Activate Egress System"
        echo "4) Deactivate Egress System"
        echo "5) Health Check"
        echo "6) Logs"
        echo "7) Exit"
        echo
        read -p "Choose an option [1-7]: " choice
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
                sudo "$SCRIPT_DIR/health.sh"
                read -p "Press Enter to continue..." _
                ;;
            6)
                echo "=== gre-tunnel logs ==="
                sudo journalctl -u gre-tunnel -n 50 --no-pager
                echo "=== dnsmasq logs ==="
                sudo journalctl -u dnsmasq -n 50 --no-pager
                read -p "Press Enter to continue..." _
                ;;
            7)
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
        sudo systemctl enable gre-tunnel
        sudo systemctl enable dnsmasq
        echo "GRE tunnel service enabled"
        ;;
    disable)
        sudo systemctl disable gre-tunnel
        sudo systemctl disable dnsmasq
        echo "GRE tunnel service disabled"
        ;;
    start)
        sudo systemctl start gre-tunnel
        sudo systemctl start dnsmasq
        echo "GRE tunnel started"
        ;;
    stop)
        sudo systemctl stop dnsmasq
        sudo systemctl stop gre-tunnel
        echo "GRE tunnel stopped"
        ;;
    status)
        echo "GRE Tunnel Status:"
        sudo systemctl status gre-tunnel --no-pager -l
        echo
        echo "DNS Service Status:"
        sudo systemctl status dnsmasq --no-pager -l
        ;;
    logs)
        echo "GRE Tunnel Logs:"
        sudo journalctl -u gre-tunnel -n 50 --no-pager
        echo
        echo "DNS Logs:"
        sudo journalctl -u dnsmasq -n 50 --no-pager
        ;;
    health)
        sudo "$SCRIPT_DIR/health.sh"
        ;;
    check)
        sudo "$SCRIPT_DIR/check.sh"
        ;;
    *)
        usage
        ;;
esac
