#!/bin/bash

# GRE Tunnel Management Script

usage() {
    echo "Usage: $0 {enable|disable|start|stop|status|logs|health|check}"
    exit 1
}

if [ $# -ne 1 ]; then
    usage
fi

COMMAND=$1

case $COMMAND in
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
        ./health.sh
        ;;
    check)
        ./check.sh
        ;;
    *)
        usage
        ;;
esac