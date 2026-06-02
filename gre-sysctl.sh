#!/bin/bash

# GREX kernel/network hardening manager.
# Generates /etc/sysctl.d/99-grex-hardening.conf from /etc/gre-tunnel.conf.

set -e

CONFIG_FILE="/etc/gre-tunnel.conf"
SYSCTL_FILE="/etc/sysctl.d/99-grex-hardening.conf"

if [ "$EUID" -ne 0 ]; then
    echo "gre-sysctl.sh must be run as root." >&2
    exit 1
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Configuration file $CONFIG_FILE not found. Run setup.sh first." >&2
    exit 1
fi

source "$CONFIG_FILE"

truthy() {
    [[ "${1:-}" =~ ^(yes|y|true|1|on|Y|TRUE)$ ]]
}

sysctl_supported() {
    sysctl -q -n "$1" >/dev/null 2>&1
}

sysctl_current() {
    sysctl -q -n "$1" 2>/dev/null || true
}

write_sysctl() {
    local key=$1
    local value=$2

    if sysctl_supported "$key"; then
        printf '%s = %s\n' "$key" "$value" >> "$SYSCTL_FILE"
    else
        echo "Skipping unsupported sysctl: $key"
    fi
}

ENABLE_SYSCTL_HARDENING=${ENABLE_SYSCTL_HARDENING:-yes}
SYSCTL_PROFILE=${SYSCTL_PROFILE:-safe}
RP_FILTER=${RP_FILTER:-2}
TCP_TIMESTAMPS=${TCP_TIMESTAMPS:-1}
LOG_MARTIANS=${LOG_MARTIANS:-yes}
DISABLE_IPV6=${DISABLE_IPV6:-no}
NF_CONNTRACK_MAX=${NF_CONNTRACK_MAX:-262144}

if ! [[ "$RP_FILTER" =~ ^[0-2]$ ]]; then
    echo "RP_FILTER must be 0, 1, or 2." >&2
    exit 1
fi

if ! [[ "$TCP_TIMESTAMPS" =~ ^[01]$ ]]; then
    echo "TCP_TIMESTAMPS must be 0 or 1." >&2
    exit 1
fi

if [ -n "$NF_CONNTRACK_MAX" ] && ! [[ "$NF_CONNTRACK_MAX" =~ ^[0-9]+$ ]]; then
    echo "NF_CONNTRACK_MAX must be a number." >&2
    exit 1
fi

if ! truthy "$ENABLE_SYSCTL_HARDENING"; then
    rm -f "$SYSCTL_FILE"
    echo "GREX sysctl hardening disabled and config removed. Existing runtime sysctl values were not reverted."
    exit 0
fi

mkdir -p "$(dirname "$SYSCTL_FILE")"

cat > "$SYSCTL_FILE" << EOF
# Managed by GREX. Do not edit manually; run 'sudo grex configure'.
# Profile: $SYSCTL_PROFILE
EOF

write_sysctl kernel.kptr_restrict 2
write_sysctl kernel.dmesg_restrict 1
write_sysctl kernel.randomize_va_space 2
if [ "$(sysctl_current kernel.unprivileged_bpf_disabled)" = "2" ]; then
    write_sysctl kernel.unprivileged_bpf_disabled 2
else
    write_sysctl kernel.unprivileged_bpf_disabled 1
fi

write_sysctl net.ipv4.ip_forward 1
write_sysctl net.ipv4.conf.all.forwarding 1
write_sysctl net.ipv4.conf.default.forwarding 1

write_sysctl net.ipv4.conf.all.rp_filter "$RP_FILTER"
write_sysctl net.ipv4.conf.default.rp_filter "$RP_FILTER"

write_sysctl net.ipv4.icmp_echo_ignore_broadcasts 1
write_sysctl net.ipv4.icmp_ignore_bogus_error_responses 1

write_sysctl net.ipv4.tcp_syncookies 1
write_sysctl net.ipv4.tcp_rfc1337 1
write_sysctl net.ipv4.tcp_sack 1
write_sysctl net.ipv4.tcp_timestamps "$TCP_TIMESTAMPS"

if truthy "$LOG_MARTIANS"; then
    write_sysctl net.ipv4.conf.all.log_martians 1
    write_sysctl net.ipv4.conf.default.log_martians 1
else
    write_sysctl net.ipv4.conf.all.log_martians 0
    write_sysctl net.ipv4.conf.default.log_martians 0
fi

write_sysctl net.ipv4.conf.all.accept_source_route 0
write_sysctl net.ipv4.conf.default.accept_source_route 0
write_sysctl net.ipv4.conf.all.accept_redirects 0
write_sysctl net.ipv4.conf.default.accept_redirects 0
write_sysctl net.ipv4.conf.all.send_redirects 0
write_sysctl net.ipv4.conf.default.send_redirects 0

if truthy "$DISABLE_IPV6"; then
    write_sysctl net.ipv6.conf.all.disable_ipv6 1
    write_sysctl net.ipv6.conf.default.disable_ipv6 1
fi

if [ -n "$NF_CONNTRACK_MAX" ]; then
    write_sysctl net.netfilter.nf_conntrack_max "$NF_CONNTRACK_MAX"
fi

sysctl -p "$SYSCTL_FILE"
echo "GREX sysctl hardening applied from $SYSCTL_FILE."
