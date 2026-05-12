#!/bin/bash

# Install script for GRE Tunnel project

echo "Installing GRE Tunnel scripts..."

# Copy scripts to system locations
sudo cp gre-tunnel.sh /usr/local/bin/
sudo cp gre-tunnel-stop.sh /usr/local/bin/
sudo cp check.sh /usr/local/bin/
sudo cp health.sh /usr/local/bin/
sudo cp manage.sh /usr/local/bin/

# Make executable
sudo chmod +x /usr/local/bin/gre-tunnel.sh
sudo chmod +x /usr/local/bin/gre-tunnel-stop.sh
sudo chmod +x /usr/local/bin/check.sh
sudo chmod +x /usr/local/bin/health.sh
sudo chmod +x /usr/local/bin/manage.sh
sudo chmod +x /usr/local/bin/check.sh
sudo chmod +x /usr/local/bin/health.sh
sudo chmod +x /usr/local/bin/manage.sh

# Copy service file
sudo cp gre-tunnel.service /etc/systemd/system/

echo "Installation complete."
echo "Run 'sudo bash setup.sh' to configure."