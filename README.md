```
Selective Internet Egress Architecture via GRE Tunnel (FortiGate + VPS)
```

---

# 🟣 1. Problem Statement

Running infrastructure from Iran introduces two major constraints:

* Internet filtering
* Global sanctions on services like Docker, GitHub, AWS

Traditional solution:

```
HTTP/SOCKS proxy
```

Problem:

* Linux servers break
* Docker pull fails
* CI/CD unstable
* package managers unreliable

We needed:

```
Clean outbound internet path
for selected servers only
```

Without:

* configuring proxy everywhere
* breaking routing
* DNS leaks

---

# 🟣 2. Final Architecture

```
Servers (selected subnets)
        ↓
FortiGate (Policy-Based Routing)
        ↓
GRE Tunnel
        ↓
VPS (NAT + DNS)
        ↓
Internet
```

Key design decisions:

* No proxy
* NAT only on VPS
* PBR on Forti
* DNS forwarded through tunnel
* GRE kept alive via SD-WAN SLA

---

# 🟣 3. VPS Setup (Rocky Linux)

## Enable IP forwarding

```bash
sudo nano /etc/sysctl.conf
```

```
net.ipv4.ip_forward=1
```

```bash
sudo sysctl -p
```

---

## Create GRE tunnel

```bash
GRE_IF="gre-forti"
VPS_PUBLIC_IP="130.x.x.x"
FORTI_PUBLIC_IP="93.x.x.x"
TUN_VPS_IP="10.10.10.2/30"

sudo ip link del $GRE_IF 2>/dev/null

sudo ip tunnel add $GRE_IF mode gre \
  local $VPS_PUBLIC_IP \
  remote $FORTI_PUBLIC_IP \
  ttl 255

sudo ip addr add $TUN_VPS_IP dev $GRE_IF
sudo ip link set $GRE_IF up
sudo ip link set $GRE_IF mtu 1476
```

Check:

```bash
ip -br a | grep gre
```

---

## Routing internal subnets back to tunnel

```bash
sudo ip route add 192.168.0.0/16 dev gre-forti
sudo ip route add 172.16.0.0/12 dev gre-forti
```

---

## NAT outbound traffic

```bash
sudo iptables -t nat -A POSTROUTING -s 192.168.0.0/16 -o eth0 -j MASQUERADE
sudo iptables -t nat -A POSTROUTING -s 172.16.0.0/12 -o eth0 -j MASQUERADE
```

---

## Forward rules

```bash
sudo iptables -I FORWARD 1 -i gre-forti -o eth0 -j ACCEPT
sudo iptables -I FORWARD 2 -i eth0 -o gre-forti \
  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

---

## Allow GRE

```bash
sudo iptables -I INPUT -p 47 -s $FORTI_PUBLIC_IP -j ACCEPT
```

---

## Persist rules

```bash
sudo sh -c 'iptables-save > /etc/sysconfig/iptables'
```

---

# 🟣 4. DNS on VPS

Install dnsmasq:

```bash
sudo dnf install dnsmasq -y
```

Config:

```bash
sudo nano /etc/dnsmasq.d/tunnel.conf
```

```
interface=gre-forti
listen-address=10.10.10.2
server=1.1.1.1
server=8.8.8.8
```

Start:

```bash
sudo systemctl enable --now dnsmasq
```

---

# 🟣 5. FortiGate Config

## GRE interface

```
config system gre-tunnel
 edit toVPS
  set interface wan1
  set remote-gw VPS_PUBLIC_IP
 next
end
```

Assign IP:

```
10.10.10.1/32
```

---

## Static route

```
config router static
 edit 0
  set dst 0.0.0.0/0
  set gateway 10.10.10.2
  set device toVPS
 next
end
```

(only for PBR traffic)

---

## Policy-Based Routing

Example:

```
Source: 192.168.10.1
Outgoing: toVPS
Gateway: 10.10.10.2
```

---

## Firewall policy

```
LAN → GRE
NAT: disable
```

---

## SD-WAN SLA (important)

Add GRE as member
Health check:

```
Ping 10.10.10.2
interval 3
```

This prevents tunnel drop.

---

# 🟣 6. Monitoring

### Tunnel traffic

```bash
tcpdump -ni gre-forti
```

### DNS

```bash
tcpdump -ni gre-forti port 53
```

### NAT

```bash
iptables -t nat -L -n -v
```

---

# 🟣 7. Testing

From server:

```bash
curl ifconfig.io
```

Expected:

```
VPS public IP
```

---

# 🟣 8. Lessons learned

* Proxy ≠ infrastructure solution
* Routing layer is cleaner
* DNS must follow same path
* GRE must be kept alive
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
