# Controlled Egress GRE Tunnel

Selective outbound Internet egress for FortiGate-connected LANs using multiple GRE tunnels to a Rocky Linux VPS.

---

## Overview

This repository provides a complete VPS-side implementation for:

- multiple GRE tunnels from FortiGate to VPS
- load-balanced egress routing
- NAT for selected internal subnets
- optional local DNS via `dnsmasq`
- systemd-managed service and health monitoring

The goal is a stable, observable, and scalable egress path without proxies.

---

## Why this architecture?

Traditional proxy-based solutions break Linux systems, Docker, CI/CD, and package managers.
This design keeps routing simple by:

- sending only selected subnets through the GRE tunnels
- NATing only at the VPS egress
- forwarding DNS through the same tunnel path
- using multiple GRE tunnels for throughput and resilience

---

## Quick Start

### 1. One-line install

If the repository is hosted on GitHub as `grex`, use this command:

```bash
curl -fsSL https://raw.githubusercontent.com/yourusername/grex/main/bootstrap.sh | sudo bash
```

Replace `yourusername` with the actual GitHub owner name.

### 2. Install required utilities

For Rocky Linux / CentOS:

```bash
sudo dnf install -y curl || sudo yum install -y curl
sudo dnf install -y dnsmasq iptables-services || sudo yum install -y dnsmasq iptables-services
```

`curl` is required for external IP validation and diagnostic testing.

### 3. Alternative manual install

If you need the repository locally:

```bash
git clone https://github.com/yourusername/grex.git
cd grex
sudo bash install.sh
sudo bash setup.sh
```

The wizard configures:

- VPS public IP
- FortiGate public IP
- number of parallel GRE tunnels
- internal subnets
- optional local DNS server with `dnsmasq`
- upstream DNS servers
- Ethernet egress interface
- per-tunnel IP and GRE interface names

### 5. Start services

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now gre-tunnel
sudo systemctl enable --now dnsmasq
```

---

## Architecture

```text
Servers (selected subnets)
        ↓
FortiGate (Policy-Based Routing)
        ↓
Multiple GRE tunnels (load-balanced)
        ↓
VPS (NAT + DNS)
        ↓
Internet
```

Key benefits:

- no proxy dependency
- clean routing layer
- DNS follows tunnel path
- multiple tunnels improve throughput and redundancy

---

## Components

- `setup.sh` — interactive VPS setup wizard
- `install.sh` — installs helper scripts and systemd unit
- `gre-tunnel.sh` — creates GRE tunnels, routes, NAT, and firewall rules
- `gre-tunnel-stop.sh` — removes GRE tunnels and related iptables rules
- `manage.sh` — enable/disable/start/stop/status/logs/health/check
- `grex` — shortcut command linked to `manage.sh`
- `check.sh` — verifies tunnel interfaces, routing, NAT, and DNS
- `health.sh` — reports health state for all tunnels
- `gre-tunnel.service` — systemd unit for tunnel startup
- `gre-tunnel.conf.example` — sample config

---

## FortiGate Configuration

### Create multiple GRE tunnels

Example for 2 tunnels:

```text
config system gre-tunnel
 edit toVPS1
  set interface wan1
  set remote-gw <VPS_PUBLIC_IP>
  set key 1
 next
 edit toVPS2
  set interface wan1
  set remote-gw <VPS_PUBLIC_IP>
  set key 2
 next
end
```

Assign IPs for the Forti side:

```text
toVPS1: 10.10.10.1/32
toVPS2: 10.10.11.1/32
```

### Load-balanced static routes

```text
config router static
 edit 1
  set dst 0.0.0.0/0
  set gateway 10.10.10.2
  set device toVPS1
  set priority 1
 next
 edit 2
  set dst 0.0.0.0/0
  set gateway 10.10.11.2
  set device toVPS2
  set priority 1
 next
end
```

This creates ECMP-style load balancing across multiple GRE tunnels.

### Policy-based routing

Apply PBR on FortiGate so selected source subnets use the GRE tunnels.
Example:

```text
Source: 192.168.10.1
Outgoing Interface: toVPS1 or toVPS2
Gateway: 10.10.10.2 or 10.10.11.2
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
sudo ip tunnel add gre-forti1 mode gre local <VPS_PUBLIC_IP> remote <FORTI_PUBLIC_IP> ttl 255 key 1
sudo ip addr add 10.10.10.2/30 dev gre-forti1
sudo ip link set gre-forti1 up
sudo ip link set gre-forti1 mtu 1476
```

Repeat for additional tunnels with different keys and IPs.

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

If DNS is enabled in the wizard, `dnsmasq` is configured automatically for each GRE interface.

Example rule file:

```text
interface=gre-forti1
listen-address=10.10.10.2
interface=gre-forti2
listen-address=10.10.11.2
server=1.1.1.1
server=8.8.8.8
```

Start dnsmasq with:

```bash
sudo systemctl enable --now dnsmasq
```

---

## Management

Use the `grex` shortcut for service lifecycle and diagnostics:

```bash
sudo grex enable
sudo grex start
sudo grex status
sudo grex logs
sudo grex health
sudo grex check
sudo grex stop
sudo grex disable
```

---

## Monitoring and Diagnostics

### Traffic monitoring

```bash
tcpdump -ni gre-forti1
tcpdump -ni gre-forti2
```

### DNS monitoring

```bash
tcpdump -ni gre-forti1 port 53
tcpdump -ni gre-forti2 port 53
```

### NAT and firewall inspection

```bash
sudo iptables -t nat -L -n -v
sudo iptables -L FORWARD -n -v
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
- Multiple GRE tunnels increase throughput and resilience, but FortiGate must be configured with matching tunnel keys and IPs.
- Use the wizard for fast deployment; the manual section is provided for reference and troubleshooting.


---

# 🟣 9. Lessons learned

* Proxy ≠ infrastructure solution
* Routing layer is cleaner
* DNS must follow same path
* GRE must be kept alive
* Multiple tunnels increase throughput and provide redundancy
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
