# Controlled Egress GRE Tunnel

Selective outbound Internet egress for FortiGate-connected LANs using one GRE tunnel to a Linux VPS.

---

## Overview

This repository provides a complete VPS-side implementation for:

- one GRE tunnel from FortiGate to VPS
- routed egress through the VPS
- NAT for selected internal subnets
- optional local DNS via `dnsmasq`
- systemd-managed service and health monitoring

The goal is a stable, observable, and scalable egress path without proxies.

GREX is designed for common systemd-based VPS distributions such as Ubuntu,
Debian, Rocky, AlmaLinux, CentOS, RHEL, Fedora, openSUSE, and Arch. On
non-systemd systems, `grex activate` can still run the tunnel scripts directly,
but persistent service management is not available through systemd.

---

## Why this architecture?

Traditional proxy-based solutions break Linux systems, Docker, CI/CD, and package managers.
This design keeps routing simple by:

- sending only selected subnets through the GRE tunnel
- NATing only at the VPS egress
- forwarding DNS through the same tunnel path
- using a single GRE tunnel for a simpler, easier-to-debug path

---

## Quick Start

### 1. One-line install

```bash
curl -fsSL https://raw.githubusercontent.com/AlirezaSayyari/GREX/main/bootstrap.sh | sudo bash
```

### 2. Install required utilities

The bootstrap wizard installs these automatically. If you prefer to install
them manually first, use the command for your distribution.

For Ubuntu / Debian:

```bash
sudo apt-get update
sudo apt-get install -y curl iproute2 iptables dnsmasq
```

For Rocky Linux / AlmaLinux / CentOS / RHEL / Fedora:

```bash
sudo dnf install -y curl iproute iptables iptables-services dnsmasq
# or on older systems:
sudo yum install -y curl iproute iptables iptables-services dnsmasq
```

For openSUSE / SLES:

```bash
sudo zypper --non-interactive install curl iproute2 iptables dnsmasq
```

For Arch Linux:

```bash
sudo pacman -Sy --noconfirm --needed curl iproute2 iptables dnsmasq
```

For Alpine Linux:

```bash
sudo apk add --no-cache bash curl iproute2 iptables dnsmasq
```

`curl` is required for external IP validation and diagnostic testing.

### 3. Alternative manual install

```bash
git clone https://github.com/AlirezaSayyari/GREX.git
cd GREX
sudo bash install.sh
sudo bash setup.sh
```

Or open the interactive manager after installation:

```bash
sudo grex
```

Bootstrap installs the project under `/srv/GREX` and creates `grex` under
`/usr/local/bin`, with a `/usr/bin/grex` symlink when possible.

The wizard configures:

- VPS public IP
- FortiGate public IP
- internal subnets
- optional local DNS server with `dnsmasq`
- upstream DNS servers
- Ethernet egress interface
- tunnel IPs and GRE interface name

The VPS public IP is auto-detected during setup and shown as the default value.
Press Enter to accept it, or type another IP if the server is behind a special
network path.

### 5. Start services

On systemd-based distributions:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gre-tunnel
# Only needed if DNS was enabled in the wizard:
sudo systemctl enable --now dnsmasq
```

On non-systemd systems, start GREX directly:

```bash
sudo grex activate
```

---

## Architecture

```text
Servers (selected subnets)
        ↓
FortiGate (Policy-Based Routing)
        ↓
GRE tunnel
        ↓
VPS (NAT + DNS)
        ↓
Internet
```

Key benefits:

- no proxy dependency
- clean routing layer
- DNS follows tunnel path
- single-tunnel design is simpler to operate and troubleshoot

---

## Components

- `setup.sh` — interactive VPS setup wizard
- `install.sh` — installs helper scripts and systemd unit
- `gre-tunnel.sh` — creates the GRE tunnel, routes, NAT, and firewall rules
- `gre-tunnel-stop.sh` — removes the GRE tunnel and related iptables rules
- `manage.sh` — enable/disable/start/stop/status/logs/health/check
- `grex` — shortcut command that runs `/srv/GREX/manage.sh`
- `check.sh` — verifies tunnel interfaces, routing, NAT, and DNS
- `health.sh` — reports tunnel health state
- `gre-tunnel.service` — systemd unit for tunnel startup
- `gre-tunnel.conf.example` — sample config

---

## FortiGate Configuration

### Create GRE tunnel

Example:

```text
config system gre-tunnel
 edit toVPS1
  set interface wan1
  set remote-gw <VPS_PUBLIC_IP>
  set key 1
 next
end
```

Assign IP for the Forti side:

```text
toVPS1: 10.10.10.1/32
```

### Static route

```text
config router static
 edit 1
  set dst 0.0.0.0/0
  set gateway 10.10.10.2
  set device toVPS1
  set priority 1
 next
end
```

### Policy-based routing

Apply PBR on FortiGate so selected source subnets use the GRE tunnel.
Example:

```text
Source: 192.168.10.1
Outgoing Interface: toVPS1
Gateway: 10.10.10.2
```

### Firewall policy

Allow LAN → GRE traffic and disable NAT on FortiGate.

---

## VPS Manual Setup Reference

### 1. Enable IP forwarding

```bash
sudo bash -c 'echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf'
sudo sysctl -p
```

### 2. Create a GRE tunnel

```bash
sudo ip link del gre-forti1 2>/dev/null
sudo ip link add gre-forti1 type gre local <VPS_PUBLIC_IP> remote <FORTI_PUBLIC_IP> ttl 255 key 1
sudo ip addr add 10.10.10.2/30 dev gre-forti1
sudo ip link set gre-forti1 mtu 1476
sudo ip link set gre-forti1 up
```

### 3. Add internal routes

```bash
sudo ip route add 192.168.0.0/16 dev gre-forti1
sudo ip route add 172.16.0.0/12 dev gre-forti1
```

### 4. Configure NAT

```bash
sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -o eth0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o eth0 -j MASQUERADE
```

### 5. Configure forwarding

```bash
sudo iptables -I FORWARD -i gre-forti1 -o eth0 -j ACCEPT
sudo iptables -I FORWARD -i eth0 -o gre-forti1 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### 6. Allow GRE

```bash
sudo iptables -I INPUT -p 47 -s <FORTI_PUBLIC_IP> -j ACCEPT
```

### 7. Persist rules

```bash
sudo sh -c 'iptables-save > /etc/sysconfig/iptables'
```

---

## DNS on VPS

If DNS is enabled in the wizard, `dnsmasq` is configured automatically for the GRE interface.

Example rule file:

```text
interface=gre-forti1
listen-address=10.10.10.2
server=1.1.1.1
server=8.8.8.8
```

Start dnsmasq with:

```bash
sudo systemctl enable --now dnsmasq
```

---

## Management

Run `sudo grex` to open the interactive CLI dashboard.

```bash
sudo grex
```

From the menu you can:

- Configure Egress System (Wizard)
- Activate Egress System
- Deactivate Egress System
- Health Check
- Logs

Command-line aliases still work too:

```bash
sudo grex configure
sudo grex activate
sudo grex deactivate
sudo grex health
sudo grex logs
```

---

## Monitoring and Diagnostics

### Traffic monitoring

```bash
tcpdump -ni gre-forti1
```

### DNS monitoring

```bash
tcpdump -ni gre-forti1 port 53
```

### NAT and firewall inspection

```bash
sudo iptables -t nat -L -n -v
sudo iptables -L FORWARD -n -v
sudo iptables -L GREX-FORWARD -n -v
```

---

## Validation

From an internal server behind FortiGate:

```bash
curl ifconfig.io
```

Expected output:

```text
<VPS public IP>
```

---

## Notes

- This solution is designed for environments where outbound traffic must be routed cleanly through a trusted egress VPS.
- The FortiGate GRE tunnel must use matching key, public endpoints, and tunnel IPs.
- Use the wizard for fast deployment; the manual section is provided for reference and troubleshooting.


---

# 🟣 9. Lessons learned

* Proxy ≠ infrastructure solution
* Routing layer is cleaner
* DNS must follow same path
* GRE must be kept alive
* A single tunnel is simpler to keep reliable
* NAT only at egress

---

# 🟣 9. Use cases

* Docker pull
* Git clone
* API access
* CI/CD
* Linux repos

---

# 🟣 10. Production notes

* Works with FortiGate
* Scalable
* No client config
* Observable
* Stable
