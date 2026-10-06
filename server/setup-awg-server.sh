#!/bin/bash
#
# setup-awg-server.sh -- one-shot AmneziaWG server setup for RobloxVPN.
#
# Installs AmneziaWG (kernel module + tools) on Ubuntu, enables IP forwarding
# and NAT, generates server/client keys and matching handshake-obfuscation
# parameters, starts the tunnel on UDP port 443, and prints a ready-to-import
# client .conf (split-tunnel: Roblox AS22697 only).
#
# Target: Oracle Cloud Always Free VM (Ubuntu 22.04/24.04, Frankfurt), but
# works on any Ubuntu VPS.
#
# Cloud-init compatible: fully non-interactive. Example user-data:
#   #cloud-config
#   runcmd:
#     - curl -fsSL https://example.com/setup-awg-server.sh | sudo bash
#
# Usage: sudo bash setup-awg-server.sh [--port 443] [--endpoint auto|IP]
#        (re-running regenerates keys and prints a NEW client config)
#
set -euo pipefail

PORT=443
ENDPOINT="auto"

while [ $# -gt 0 ]; do
    case "$1" in
        --port)     PORT="$2"; shift 2 ;;
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ "$(id -u)" -ne 0 ]; then
    echo "run as root (sudo)" >&2; exit 1
fi

export DEBIAN_FRONTEND=noninteractive
WG_IF=awg0
WG_NET="10.8.0.0/24"
SRV_IP="10.8.0.1"
CLI_IP="10.8.0.2"

echo "==> [1/8] base packages"
apt-get update -qq
apt-get install -y -qq software-properties-common curl iptables-persistent \
    build-essential dkms > /dev/null
# Kernel headers for the DKMS module build (Oracle images use linux-oracle).
apt-get install -y -qq "linux-headers-$(uname -r)" > /dev/null 2>&1 \
    || apt-get install -y -qq linux-headers-generic > /dev/null

echo "==> [2/8] AmneziaWG PPA + packages"
add-apt-repository -y ppa:amnezia/ppa > /dev/null 2>&1
apt-get update -qq
apt-get install -y -qq amneziawg-dkms amneziawg-tools > /dev/null
if ! modprobe amneziawg 2>/dev/null; then
    echo "WARNING: amneziawg kernel module did not load." >&2
    echo "Try: dpkg-reconfigure amneziawg-dkms && modprobe amneziawg" >&2
fi

echo "==> [3/8] IP forwarding"
sysctl -w net.ipv4.ip_forward=1 > /dev/null
cat > /etc/sysctl.d/99-roblox-vpn.conf <<EOF
net.ipv4.ip_forward=1
EOF

echo "==> [4/8] keys + obfuscation parameters"
SRV_PRIV="$(awg genkey)"
SRV_PUB="$(echo "$SRV_PRIV" | awg pubkey)"
CLI_PRIV="$(awg genkey)"
CLI_PUB="$(echo "$CLI_PRIV" | awg pubkey)"
PSK="$(awg genpsk)"
# Obfuscation params must match the client config printed at the end.
JC="$(shuf -i 3-10 -n 1)"
JMIN="$(shuf -i 20-60 -n 1)"
JMAX="$((JMIN + $(shuf -i 10-60 -n 1)))"
S1="$(shuf -i 15-127 -n 1)"; S2="$(shuf -i 15-127 -n 1)"
S3="$(shuf -i 15-127 -n 1)"; S4="$(shuf -i 15-127 -n 1)"
H1="$(shuf -i 1-4294967295 -n 1)"; H2="$(shuf -i 1-4294967295 -n 1)"
H3="$(shuf -i 1-4294967295 -n 1)"; H4="$(shuf -i 1-4294967295 -n 1)"

echo "==> [5/8] server config /etc/amneziawg/${WG_IF}.conf"
mkdir -p /etc/amneziawg
cat > "/etc/amneziawg/${WG_IF}.conf" <<EOF
[Interface]
Address = ${SRV_IP}/24
ListenPort = ${PORT}
PrivateKey = ${SRV_PRIV}
MTU = 1420
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
# RobloxVPN client
PublicKey = ${CLI_PUB}
PresharedKey = ${PSK}
AllowedIPs = ${CLI_IP}/32
EOF
chmod 600 "/etc/amneziawg/${WG_IF}.conf"

echo "==> [6/8] NAT (MASQUERADE)"
MAIN_IF="$(ip -4 route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}' | head -n1)"
iptables -t nat -C POSTROUTING -s "$WG_NET" -o "$MAIN_IF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$WG_NET" -o "$MAIN_IF" -j MASQUERADE
iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -i "$WG_IF" -j ACCEPT
iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null \
    || iptables -A FORWARD -o "$WG_IF" -j ACCEPT
netfilter-persistent save > /dev/null 2>&1 || true

echo "==> [7/8] start tunnel"
systemctl enable --now "awg-quick@${WG_IF}" > /dev/null 2>&1
sleep 2
awg show "$WG_IF" > /dev/null && echo "    tunnel ${WG_IF} is up"

echo "==> [8/8] client config"
if [ "$ENDPOINT" = "auto" ]; then
    ENDPOINT="$(curl -4 -s --max-time 10 https://api.ipify.org || true)"
fi
if [ -z "$ENDPOINT" ]; then
    echo "ERROR: could not detect public IP; re-run with --endpoint YOUR_IP" >&2
    exit 1
fi

CLIENT_CONF="/root/roblox-client.conf"
cat > "$CLIENT_CONF" <<EOF
[Interface]
PrivateKey = ${CLI_PRIV}
Address = ${CLI_IP}/32
MTU = 1420
Jc = ${JC}
Jmin = ${JMIN}
Jmax = ${JMAX}
S1 = ${S1}
S2 = ${S2}
S3 = ${S3}
S4 = ${S4}
H1 = ${H1}
H2 = ${H2}
H3 = ${H3}
H4 = ${H4}

[Peer]
PublicKey = ${SRV_PUB}
PresharedKey = ${PSK}
Endpoint = ${ENDPOINT}:${PORT}
AllowedIPs = 128.116.0.0/17
PersistentKeepalive = 25
EOF
chmod 600 "$CLIENT_CONF"

echo
echo "==================== CLIENT CONFIG ===================="
cat "$CLIENT_CONF"
echo "======================================================="
echo
echo "Saved to: $CLIENT_CONF"
echo
echo "IMPORTANT - Oracle Cloud networking:"
echo "  Allow UDP port ${PORT} ingress in the VCN security list / network"
echo "  security group of this instance, or handshakes will never arrive."
echo "Server: AmneziaWG on UDP ${PORT}, split-tunnel (Roblox 128.116.0.0/17)."
