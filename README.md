# Controlled Egress GRE Tunnel

Selective outbound Internet egress for routed networks using one GRE tunnel to a Linux VPS.

---

## Overview

This repository provides a complete VPS-side implementation for:

- one GRE tunnel from a remote gateway to VPS
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
sudo apt-get install -y curl iproute2 iptables dnsmasq fail2ban
```

For Rocky Linux / AlmaLinux / CentOS / RHEL / Fedora:

```bash
sudo dnf install -y curl iproute iptables iptables-services dnsmasq fail2ban
# or on older systems:
sudo yum install -y curl iproute iptables iptables-services dnsmasq fail2ban
```

For openSUSE / SLES:

```bash
sudo zypper --non-interactive install curl iproute2 iptables dnsmasq fail2ban
```

For Arch Linux:

```bash
sudo pacman -Sy --noconfirm --needed curl iproute2 iptables dnsmasq fail2ban
```

For Alpine Linux:

```bash
sudo apk add --no-cache bash curl iproute2 iptables dnsmasq fail2ban
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
- remote gateway public IP
- internal subnets
- optional local DNS server with `dnsmasq`
- upstream DNS servers
- Ethernet egress interface
- tunnel IPs and GRE interface name
- GRE MTU and TCP MSS handling
- optional VPS firewall hardening
- admin SSH source IPs/CIDRs when hardening is enabled
- kernel/network sysctl hardening profile
- optional fail2ban SSH protection

The VPS public IP is auto-detected during setup and shown as the default value.
Press Enter to accept it, or type another IP if the server is behind a special
network path.

The wizard writes `/etc/gre-tunnel.conf` and applies the configuration
immediately. If hardening is enabled, firewall rules are applied during the
wizard run, so make sure the admin SSH source IP is correct.

After the initial wizard, use `sudo grex edit` or menu option `Edit GREX
Configuration` to change one setting at a time without walking through the full
setup again. The editor saves each field immediately; choose `Apply saved
configuration` inside that submenu when you want GREX to restart services and
apply the saved values.

### 4. Start services

The wizard applies the configuration automatically. To start or restart later on
systemd-based distributions:

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
Remote gateway / router (policy-based routing)
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

## Remote Gateway Configuration

### Create GRE tunnel

Vendor syntax differs, but the remote gateway must create a GRE tunnel toward
the VPS public IP.

Generic values:

```text
remote public endpoint: <VPS_PUBLIC_IP>
remote tunnel IP:      10.10.10.1
VPS tunnel IP:         10.10.10.2
```

Assign the tunnel IP on the gateway side:

```text
GRE peer interface: 10.10.10.1/30 or 10.10.10.1/32 with remote 10.10.10.2
```

### Static route

Route selected traffic, or a default route in a separate routing table, toward
the VPS tunnel IP.

```text
destination: selected internal egress routes or 0.0.0.0/0
gateway:     10.10.10.2
interface:   GRE peer interface
```

### Policy-based routing

Apply PBR on the remote gateway so selected source subnets use the GRE tunnel.
Example:

```text
Source: 192.168.10.1
Outgoing Interface: toVPS1
Gateway: 10.10.10.2
```

### Firewall policy

Allow LAN to GRE traffic on the remote gateway. NAT should normally happen on
the VPS egress side, not on the remote gateway side.

---

## VPS Manual Setup Reference

### 1. Enable IP forwarding

```bash
sudo bash -c 'echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf'
sudo sysctl -p
```

### 2. Create a GRE tunnel

```bash
sudo ip link del grex 2>/dev/null
sudo ip link add grex type gre local <VPS_PUBLIC_IP> remote <REMOTE_PUBLIC_IP> ttl 255
sudo ip addr add 10.10.10.2/30 dev grex
sudo ip link set grex mtu 1400
sudo ip link set grex up
```

### 3. Add internal routes

```bash
sudo ip route add 192.168.0.0/16 dev grex
sudo ip route add 172.16.0.0/12 dev grex
```

### 4. Configure NAT

```bash
sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -o eth0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o eth0 -j MASQUERADE
```

### 5. Configure forwarding

```bash
sudo iptables -N GREX-FORWARD 2>/dev/null || true
sudo iptables -I FORWARD 1 -j GREX-FORWARD
sudo iptables -A GREX-FORWARD -i grex -o eth0 -j ACCEPT
sudo iptables -A GREX-FORWARD -i eth0 -o grex -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -t mangle -N GREX-MANGLE 2>/dev/null || true
sudo iptables -t mangle -I FORWARD 1 -j GREX-MANGLE
sudo iptables -t mangle -A GREX-MANGLE -i grex -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
sudo iptables -t mangle -A GREX-MANGLE -o grex -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1360
```

Use `--clamp-mss-to-pmtu` instead of `--set-mss 1360` if PMTU discovery is
reliable on your path. The wizard exposes this as `MSS_MODE`.

### 6. Harden VPS input and default forwarding

Replace `<ADMIN_IP_OR_CIDR>` before applying these rules. Repeat the SSH rule
for every allowed admin source. Add allow rules first, then set default policies
to avoid locking yourself out.

```bash
sudo iptables -N GREX-INPUT 2>/dev/null || true
sudo iptables -I INPUT 1 -j GREX-INPUT
sudo iptables -A GREX-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
sudo iptables -A GREX-INPUT -i lo -j ACCEPT
sudo iptables -A GREX-INPUT -p icmp -j ACCEPT
sudo iptables -A GREX-INPUT -p 47 -s <REMOTE_PUBLIC_IP> -j ACCEPT
sudo iptables -A GREX-INPUT -p tcp --dport 22 -s <ADMIN_IP_OR_CIDR> -m conntrack --ctstate NEW -j ACCEPT
sudo iptables -P INPUT DROP
sudo iptables -P FORWARD DROP
sudo iptables -P OUTPUT ACCEPT
```

If DNS is enabled on the VPS, also allow DNS on the GRE interface:

```bash
sudo iptables -A GREX-INPUT -i grex -p udp --dport 53 -j ACCEPT
sudo iptables -A GREX-INPUT -i grex -p tcp --dport 53 -j ACCEPT
```

GREX applies these hardening rules automatically when enabled in the wizard.

### 7. Kernel and network hardening

GREX can also generate a dedicated sysctl profile at:

```bash
/etc/sysctl.d/99-grex-hardening.conf
```

The wizard exposes this as `ENABLE_SYSCTL_HARDENING`. The default `safe`
profile keeps compatibility with GRE/NAT gateways:

- enables IPv4 forwarding
- enables syncookies and common TCP protections
- disables source routes and ICMP redirects
- uses `rp_filter=2` loose mode, which is safer for GRE/asymmetric routing than strict mode
- keeps TCP timestamps enabled by default
- leaves IPv6 enabled unless you explicitly disable it
- sets `nf_conntrack_max` when the kernel exposes that sysctl

Use the `strict` profile only when you know the GRE path is symmetric. It sets
`rp_filter=1`, which can break valid routed or tunneled traffic on some paths.

You can apply this module directly:

```bash
sudo /srv/GREX/gre-sysctl.sh
```

`sudo grex configure` and `sudo grex activate` apply it automatically when it is
enabled.

### 8. fail2ban SSH protection

When enabled in the wizard, GREX writes `/etc/fail2ban/jail.d/grex-sshd.local`
with these defaults:

```ini
[sshd]
enabled = true
port = 22
maxretry = 3
findtime = 10m
bantime = 1h
```

The wizard lets you edit each value and adds the configured admin SSH sources
to `ignoreip` so your management IPs are not banned.

### 9. Minimal non-hardened forwarding

If hardening is disabled, the minimal direct forwarding rules are:

```bash
sudo iptables -I FORWARD -i grex -o eth0 -j ACCEPT
sudo iptables -I FORWARD -i eth0 -o grex -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

### 10. Allow GRE

```bash
sudo iptables -I INPUT -p 47 -s <REMOTE_PUBLIC_IP> -j ACCEPT
```

### 11. Persist rules

```bash
sudo sh -c 'iptables-save > /etc/sysconfig/iptables'
```

---

## DNS on VPS

If DNS is enabled in the wizard, `dnsmasq` is configured automatically for the GRE interface.

Example rule file:

```text
interface=grex
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
- Edit Egress System settings one by one
- Activate Egress System
- Deactivate Egress System
- Health Check
- Logs
- Upgrade GREX to the latest published version
- Back up and restore the GREX config

Command-line aliases still work too:

```bash
sudo grex configure
sudo grex edit
sudo grex version
sudo grex check-upgrade
sudo grex upgrade
sudo grex backup
sudo grex restore
sudo grex activate
sudo grex deactivate
sudo grex health
sudo grex logs
```

`sudo grex version` shows the installed version on the server and checks the
latest GitHub release/tag. `sudo grex upgrade` downloads the latest published
version, runs `install.sh`, preserves `/etc/gre-tunnel.conf`, and does not run
the setup wizard again.

GREX stores configuration backups under `/var/backups/grex`. The setup wizard,
configuration editor, restore flow, and upgrade flow create a backup before
changing sensitive state. `/etc/gre-tunnel.conf` is kept as `root:root` with
`600` permissions.

GREX validates critical IP, CIDR, MTU, MSS, sysctl, and admin allowlist values
before saving or activating a configuration. When firewall hardening is enabled,
GREX also warns if the current SSH source IP is not covered by `ADMIN_IPS`.

---

## Monitoring and Diagnostics

### Traffic monitoring

```bash
tcpdump -ni grex
```

### DNS monitoring

```bash
tcpdump -ni grex port 53
```

### NAT and firewall inspection

```bash
sudo iptables -t nat -L -n -v
sudo iptables -L FORWARD -n -v
sudo iptables -L GREX-FORWARD -n -v
```

---

## Validation

From an internal server behind the remote gateway:

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
- The remote GRE endpoint must use matching key, public endpoints, and tunnel IPs.
- Use the wizard for fast deployment; the manual section is provided for reference and troubleshooting.


---

# Lessons learned

* Proxy ≠ infrastructure solution
* Routing layer is cleaner
* DNS must follow same path
* GRE must be kept alive
* A single tunnel is simpler to keep reliable
* NAT only at egress

---

# Use cases

* Docker pull
* Git clone
* API access
* CI/CD
* Linux repos

---

# Production notes

* Works with GRE-capable gateways
* Scalable
* No client config
* Observable
* Stable
