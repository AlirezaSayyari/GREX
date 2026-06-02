#!/bin/bash

# Install script for GRE Tunnel project

set -e

INSTALL_DIR="/srv/GREX"
BIN_DIR="/usr/local/bin"
SYSTEMD_DIR="/etc/systemd/system"

run_as_root() {
    if [ "$EUID" -ne 0 ]; then
        if ! command -v sudo >/dev/null 2>&1; then
            echo "This installer must run as root or have sudo installed." >&2
            exit 1
        fi
        sudo "$@"
    else
        "$@"
    fi
}

echo "Installing GRE Tunnel scripts..."

run_as_root mkdir -p "$INSTALL_DIR"
run_as_root mkdir -p "$BIN_DIR"

# Copy project files to the server install directory
run_as_root cp gre-tunnel.sh "$INSTALL_DIR/"
run_as_root cp gre-tunnel-stop.sh "$INSTALL_DIR/"
run_as_root cp gre-sysctl.sh "$INSTALL_DIR/"
run_as_root cp check.sh "$INSTALL_DIR/"
run_as_root cp health.sh "$INSTALL_DIR/"
run_as_root cp manage.sh "$INSTALL_DIR/"
run_as_root cp setup.sh "$INSTALL_DIR/"
run_as_root cp install.sh "$INSTALL_DIR/"
run_as_root cp bootstrap.sh "$INSTALL_DIR/" 2>/dev/null || true
run_as_root cp gre-tunnel.service "$INSTALL_DIR/"
run_as_root cp gre-tunnel.conf.example "$INSTALL_DIR/"
run_as_root cp README.md "$INSTALL_DIR/"

# Make executable
run_as_root chmod +x "$INSTALL_DIR/gre-tunnel.sh"
run_as_root chmod +x "$INSTALL_DIR/gre-tunnel-stop.sh"
run_as_root chmod +x "$INSTALL_DIR/gre-sysctl.sh"
run_as_root chmod +x "$INSTALL_DIR/check.sh"
run_as_root chmod +x "$INSTALL_DIR/health.sh"
run_as_root chmod +x "$INSTALL_DIR/manage.sh"
run_as_root chmod +x "$INSTALL_DIR/setup.sh"
run_as_root chmod +x "$INSTALL_DIR/install.sh"
run_as_root chmod +x "$INSTALL_DIR/bootstrap.sh" 2>/dev/null || true

# Create the grex command in a PATH that sudo normally keeps.
run_as_root bash -c "printf '%s\n' '#!/bin/bash' 'exec /srv/GREX/manage.sh \"\$@\"' > '$BIN_DIR/grex'"
run_as_root chmod +x "$BIN_DIR/grex"

if [ ! -e /usr/bin/grex ] && [ -d /usr/bin ]; then
    run_as_root ln -s "$BIN_DIR/grex" /usr/bin/grex
fi

# Copy service file
if command -v systemctl >/dev/null 2>&1 && [ -d "$SYSTEMD_DIR" ]; then
    run_as_root cp "$INSTALL_DIR/gre-tunnel.service" "$SYSTEMD_DIR/"
    run_as_root systemctl daemon-reload 2>/dev/null || true
    if systemctl is-active --quiet gre-tunnel 2>/dev/null && [ -f /etc/gre-tunnel.conf ]; then
        echo "Restarting active gre-tunnel service to apply the installed version..."
        run_as_root systemctl restart gre-tunnel
    fi
else
    echo "systemd was not detected; grex can still run tunnels directly, but enable/start service commands require systemd."
fi

echo "Installation complete."
echo "Installed to $INSTALL_DIR."
echo "Run 'sudo grex' to manage the tunnel service or 'sudo grex configure' to configure."
