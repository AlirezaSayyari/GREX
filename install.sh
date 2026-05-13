#!/bin/bash

# Install script for GRE Tunnel project

set -e

if [ "$EUID" -ne 0 ]; then
    SUDO=sudo
else
    SUDO=:
fi

echo "Installing GRE Tunnel scripts..."

# Copy scripts to system locations
$SUDO cp gre-tunnel.sh /usr/local/bin/
$SUDO cp gre-tunnel-stop.sh /usr/local/bin/
$SUDO cp check.sh /usr/local/bin/
$SUDO cp health.sh /usr/local/bin/
$SUDO cp manage.sh /usr/local/bin/
$SUDO cp setup.sh /usr/local/bin/

# Make executable
$SUDO chmod +x /usr/local/bin/gre-tunnel.sh
$SUDO chmod +x /usr/local/bin/gre-tunnel-stop.sh
$SUDO chmod +x /usr/local/bin/check.sh
$SUDO chmod +x /usr/local/bin/health.sh
$SUDO chmod +x /usr/local/bin/manage.sh
$SUDO ln -sf /usr/local/bin/manage.sh /usr/local/bin/grex
$SUDO ln -sf /usr/local/bin/manage.sh /usr/bin/grex
$SUDO chmod +x /usr/local/bin/grex
$SUDO chmod +x /usr/bin/grex

# Create robust wrapper in /usr/bin/grex in case symlink path issues occur
$SUDO bash -c 'cat > /usr/bin/grex << "EOF"
#!/bin/bash
exec /usr/local/bin/manage.sh "$@"
EOF'
$SUDO chmod +x /usr/bin/grex

# Copy service file
$SUDO cp gre-tunnel.service /etc/systemd/system/

$SUDO systemctl daemon-reload

echo "Installation complete."
echo "Run 'sudo grex' to manage the tunnel service or 'sudo bash setup.sh' to configure."