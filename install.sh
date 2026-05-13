#!/bin/bash

# Install script for GRE Tunnel project

set -e

INSTALL_DIR="/srv/GREX"

run_as_root() {
    if [ "$EUID" -ne 0 ]; then
        sudo "$@"
    else
        "$@"
    fi
}

echo "Installing GRE Tunnel scripts..."

run_as_root mkdir -p "$INSTALL_DIR"

# Copy project files to the server install directory
run_as_root cp gre-tunnel.sh "$INSTALL_DIR/"
run_as_root cp gre-tunnel-stop.sh "$INSTALL_DIR/"
run_as_root cp check.sh "$INSTALL_DIR/"
run_as_root cp health.sh "$INSTALL_DIR/"
run_as_root cp manage.sh "$INSTALL_DIR/"
run_as_root cp setup.sh "$INSTALL_DIR/"
run_as_root cp gre-tunnel.service "$INSTALL_DIR/"
run_as_root cp gre-tunnel.conf.example "$INSTALL_DIR/"
run_as_root cp README.md "$INSTALL_DIR/"

# Make executable
run_as_root chmod +x "$INSTALL_DIR/gre-tunnel.sh"
run_as_root chmod +x "$INSTALL_DIR/gre-tunnel-stop.sh"
run_as_root chmod +x "$INSTALL_DIR/check.sh"
run_as_root chmod +x "$INSTALL_DIR/health.sh"
run_as_root chmod +x "$INSTALL_DIR/manage.sh"
run_as_root chmod +x "$INSTALL_DIR/setup.sh"

# Create the grex command in a PATH that sudo normally keeps.
run_as_root bash -c 'cat > /usr/bin/grex << "EOF"
#!/bin/bash
exec /srv/GREX/manage.sh "$@"
EOF'
run_as_root chmod +x /usr/bin/grex

# Copy service file
run_as_root cp "$INSTALL_DIR/gre-tunnel.service" /etc/systemd/system/

run_as_root systemctl daemon-reload

echo "Installation complete."
echo "Installed to $INSTALL_DIR."
echo "Run 'sudo grex' to manage the tunnel service or 'sudo grex configure' to configure."
