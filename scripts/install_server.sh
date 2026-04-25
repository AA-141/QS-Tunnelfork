#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root: sudo bash scripts/install_server.sh"
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_IFACE="$(ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')"

read -rp "WireGuard interface name [wg0]: " WG_IFACE
WG_IFACE="${WG_IFACE:-wg0}"

read -rp "WireGuard listen port [51820]: " WG_LISTEN_PORT
WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"

read -rp "Server WireGuard IP CIDR [10.66.0.1/24]: " WG_SERVER_CIDR
WG_SERVER_CIDR="${WG_SERVER_CIDR:-10.66.0.1/24}"

read -rp "Client WireGuard IP CIDR [10.66.0.2/32]: " WG_CLIENT_CIDR
WG_CLIENT_CIDR="${WG_CLIENT_CIDR:-10.66.0.2/32}"

read -rp "QS-Tunnel registration UDP port [5300]: " QS_REG_PORT
QS_REG_PORT="${QS_REG_PORT:-5300}"

read -rp "QS-Tunnel bridge UDP port [5301]: " QS_BRIDGE_PORT
QS_BRIDGE_PORT="${QS_BRIDGE_PORT:-5301}"

read -rp "Shared secret for QS-Tunnel (leave empty to auto-generate): " QS_SECRET
if [[ -z "${QS_SECRET}" ]]; then
  QS_SECRET="$(openssl rand -hex 16)"
fi

SERVER_PUBLIC_IP="$(curl -4 -fsSL https://api.ipify.org || true)"
if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
  read -rp "Could not auto-detect server public IP. Enter it manually: " SERVER_PUBLIC_IP
fi

VENV_DIR="${REPO_DIR}/.venv"

echo "[1/8] Installing dependencies..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv wireguard iptables curl
modprobe wireguard 2>/dev/null || true
python3 -m venv "${VENV_DIR}"
"${VENV_DIR}/bin/pip" install --upgrade pip
"${VENV_DIR}/bin/pip" install -r "${REPO_DIR}/requirements.txt"

echo "[2/8] Generating WireGuard keys..."
install -d -m 700 /etc/wireguard/keys
umask 077
wg genkey | tee /etc/wireguard/keys/server_private.key | wg pubkey > /etc/wireguard/keys/server_public.key
wg genkey | tee /etc/wireguard/keys/client_private.key | wg pubkey > /etc/wireguard/keys/client_public.key

SERVER_PRIVATE_KEY="$(cat /etc/wireguard/keys/server_private.key)"
SERVER_PUBLIC_KEY="$(cat /etc/wireguard/keys/server_public.key)"
CLIENT_PRIVATE_KEY="$(cat /etc/wireguard/keys/client_private.key)"
CLIENT_PUBLIC_KEY="$(cat /etc/wireguard/keys/client_public.key)"

echo "[3/8] Writing /etc/wireguard/${WG_IFACE}.conf..."
cat > "/etc/wireguard/${WG_IFACE}.conf" <<EOF
[Interface]
PrivateKey = ${SERVER_PRIVATE_KEY}
Address = ${WG_SERVER_CIDR}
ListenPort = ${WG_LISTEN_PORT}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE

[Peer]
PublicKey = ${CLIENT_PUBLIC_KEY}
AllowedIPs = ${WG_CLIENT_CIDR}
EOF
chmod 600 "/etc/wireguard/${WG_IFACE}.conf"

echo "[4/8] Enabling IPv4 forwarding..."
if ! grep -q "^net.ipv4.ip_forward=1$" /etc/sysctl.conf; then
  echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
fi
sysctl -p >/dev/null

echo "[5/8] Bringing up WireGuard..."
# Clean up any leftover state from a previous install so restart succeeds
systemctl stop "wg-quick@${WG_IFACE}" 2>/dev/null || true
systemctl reset-failed "wg-quick@${WG_IFACE}" 2>/dev/null || true
ip link delete "${WG_IFACE}" 2>/dev/null || true
systemctl enable "wg-quick@${WG_IFACE}" >/dev/null
WG_OK=true
if ! systemctl start "wg-quick@${WG_IFACE}"; then
  WG_OK=false
  echo ""
  echo "[warning] WireGuard failed to start. To diagnose, run:"
  echo "  journalctl -xeu wg-quick@${WG_IFACE}.service"
  echo "[warning] Continuing installation — fix WireGuard manually after setup completes."
  echo ""
fi

echo "[6/8] Writing QS-Tunnel server config..."
cat > "${REPO_DIR}/config_server.json" <<EOF
{
  "registration_port": ${QS_REG_PORT},
  "bridge_port": ${QS_BRIDGE_PORT},
  "h_out_address": "127.0.0.1:${WG_LISTEN_PORT}",
  "info_decryption_pass": "${QS_SECRET}"
}
EOF

echo "[7/8] Creating systemd service for QS-Tunnel..."
cat > /etc/systemd/system/qs-tunnel.service <<EOF
[Unit]
Description=QS-Tunnel server
After=network-online.target wg-quick@${WG_IFACE}.service
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/.venv/bin/python3 ${REPO_DIR}/main_server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable qs-tunnel.service >/dev/null
systemctl restart qs-tunnel.service

echo "[8/8] Opening firewall ports if UFW is installed..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${QS_REG_PORT}/udp" >/dev/null || true
  ufw allow "${QS_BRIDGE_PORT}/udp" >/dev/null || true
  ufw allow "${WG_LISTEN_PORT}/udp" >/dev/null || true
fi

if [[ "${WG_OK}" = false ]]; then
  echo ""
  echo "*** WireGuard did NOT start. Fix it manually, then run:"
  echo "    systemctl start wg-quick@${WG_IFACE}"
  echo ""
fi

cat <<EOF

Install complete.

Server public IP: ${SERVER_PUBLIC_IP}
QS-Tunnel shared secret: ${QS_SECRET}
QS-Tunnel ports: registration=${QS_REG_PORT}, bridge=${QS_BRIDGE_PORT}
WireGuard listen port: ${WG_LISTEN_PORT}

Generated client WireGuard config:

[Interface]
PrivateKey = ${CLIENT_PRIVATE_KEY}
Address = ${WG_CLIENT_CIDR}
DNS = 1.1.1.1

[Peer]
PublicKey = ${SERVER_PUBLIC_KEY}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:10443

Client QS-Tunnel essentials:
- server_registration_address: ${SERVER_PUBLIC_IP}:${QS_REG_PORT}
- bridge_address: ${SERVER_PUBLIC_IP}:${QS_BRIDGE_PORT}
- info_encryption_pass: ${QS_SECRET}
EOF
