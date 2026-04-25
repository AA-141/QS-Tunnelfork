# QS-Tunnel

Asymmetric UDP tunnel:
- **Upload:** tiny traffic through your VLESS config
- **Download:** IP-spoofed UDP (does not use VLESS bandwidth)

This README is quick-start first. Advanced details are in `examples/` and scripts.

## Quick start (recommended: WireGuard backend)

### 1) Requirements

> **Important:** If your internet is behind CGNAT, spoofed return traffic often cannot reach your client because NAT rewrites source ports unpredictably. Verify your mapping behavior before setup with `python nat_keep_alive_test.py`.

- Linux VPS (server) with root access
- VPS/network must allow outbound UDP IP spoofing
- UDP ports `5300` and `5301` open on server
- Python `3.12+` on client and server
- A **VLESS WebSocket** URL from your proxy/provider account (used only for upload path)
- A UDP VPN backend (WireGuard recommended)
- Non-CGNAT client internet (public UDP source port should stay stable)

### 2) Install

```bash
git clone https://github.com/milad-mamandi/QS-Tunnel.git
cd QS-Tunnel
pip install -r requirements.txt
```

Optional server bootstrap (Ubuntu/Debian):
```bash
sudo bash scripts/install_server.sh
```

### 3) Configure server (`config_server.json`)

```json
{
  "registration_port": 5300,
  "bridge_port": 5301,
  "h_out_address": "127.0.0.1:51820",
  "info_decryption_pass": "your-shared-secret"
}
```

- `h_out_address` = local UDP address of your VPN server (example: WireGuard on `51820`)
- `info_decryption_pass` must match client `info_encryption_pass`

### 4) Configure client (`config_client.json`)

```json
{
  "server_registration_address": "YOUR_SERVER_IP:5300",
  "vless_config": "vless://UUID@HOST:PORT?encryption=none&security=tls&type=ws&path=%2F",
  "bridge_address": "YOUR_SERVER_IP:5301",
  "xray_bridge_inbound": "",
  "h_in_address": "127.0.0.1:10443",
  "fake_send_ip": "1.1.1.1",
  "fake_send_port": 443,
  "my_public_ip": "ezping",
  "info_encryption_pass": "your-shared-secret",
  "fwmark": 51821
}
```

Most important fields:
- `vless_config`: your purchased VLESS **WS** URL
- `bridge_address`: server `IP:bridge_port` (usually `YOUR_SERVER_IP:5301`)
- `h_in_address`: where your VPN client sends UDP locally (must match your VPN client endpoint)
- `info_encryption_pass`: must equal server secret
- `fake_send_ip` / `fake_send_port`: spoofed source IP:port for server replies (commonly `1.1.1.1:443`)
- `fwmark`: Linux only — see [WireGuard routing bypass](#wireguard-routing-bypass-linux) below

### 5) Run

On server:
```bash
sudo python main_server.py
```

On client (root or CAP_NET_ADMIN required on Linux when `fwmark` is set):
```bash
sudo python main_client.py
```

Then start your VPN client (for WireGuard, point endpoint to `127.0.0.1:10443`).

---

## WireGuard routing bypass (Linux)

When WireGuard uses `AllowedIPs = 0.0.0.0/0` it routes **all** traffic through the tunnel.
This captures QS-Tunnel's own internet connections (VLESS WebSocket, registration UDP,
keep-alive UDP) and causes a routing loop — VLESS stops working the moment WireGuard is activated.

**Fix:** use `fwmark` so QS-Tunnel's sockets are stamped with a Linux packet mark that bypasses
WireGuard's routing rules.

**Step 1 — `config_client.json`:** set `"fwmark"` to any non-zero integer, e.g. `51821`.

**Step 2 — `wg0_client.conf`:** add `PostUp`/`PreDown` hooks that install the bypass rule
(use the same integer you chose for `fwmark`):

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address = 10.0.0.2/32
DNS = 1.1.1.1
PostUp  = ip rule add fwmark 51821 table main priority 100
PreDown = ip rule del fwmark 51821 table main priority 100

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:10443
```

**Step 3:** run QS-Tunnel as root (or with `CAP_NET_ADMIN`) — `SO_MARK` requires this privilege.

> **Windows / macOS:** the `fwmark` option is ignored on non-Linux platforms; use split-tunnel
> (`AllowedIPs` that exclude the VLESS server IP) or a similar OS-level bypass instead.

---

## Minimal architecture

1. VPN client sends UDP to QS-Tunnel client (`h_in_address`)
2. QS-Tunnel client forwards upload via VLESS to server `bridge_port`
3. QS-Tunnel server forwards to your local VPN server (`h_out_address`)
4. Replies return as spoofed UDP whose source is `fake_send_ip:fake_send_port` (the server pretends packets come from this IP:port)

---

## Examples and advanced setups

- WireGuard templates: `examples/wireguard/` (complete server/client and QS-Tunnel config samples)
- Xray xhttp-h3 templates: `examples/xray_core_xhttp_h3/` (alternative setup for v2rayN/Xray-core)
- Hysteria templates: `examples/xray_core_hysteria/` (Hysteria-based backend examples)
- Spoofing test tool: `spoof_udp_test.py`
- NAT keep-alive tool: `nat_keep_alive_test.py`

---

## Recovering lost keys or configuration

If you lose the output from the install script, all generated files are still on the server:

| What | Path |
|------|------|
| Server WireGuard private key | `/etc/wireguard/keys/server_private.key` |
| Server WireGuard public key | `/etc/wireguard/keys/server_public.key` |
| Client WireGuard private key | `/etc/wireguard/keys/client_private.key` |
| Client WireGuard public key | `/etc/wireguard/keys/client_public.key` |
| WireGuard interface config (server) | `/etc/wireguard/wg0.conf` (or the interface name you chose) |
| QS-Tunnel server config (shared secret, ports) | `config_server.json` in the repo directory |

To display the client WireGuard config again (server-side):

```bash
echo "[Interface]"
echo "PrivateKey = $(cat /etc/wireguard/keys/client_private.key)"
echo "Address = <WG_CLIENT_CIDR>"
echo "DNS = 1.1.1.1"
echo ""
echo "[Peer]"
echo "PublicKey = $(cat /etc/wireguard/keys/server_public.key)"
echo "AllowedIPs = 0.0.0.0/0, ::/0"
echo "Endpoint = 127.0.0.1:10443"
```

The QS-Tunnel shared secret is the `info_decryption_pass` value in `config_server.json`. Use it as `info_encryption_pass` in `config_client.json`.

If you need to reinstall from scratch, just re-run `sudo bash scripts/install_server.sh` — it will cleanly replace all keys and configs.

---

## Notes

- QS-Tunnel is a UDP forwarder, not an encryption protocol by itself.
- Use a secure VPN backend (WireGuard / Hysteria / xhttp-h3).
- Python `3.12+` required.

### Known limitations

- CGNAT client networks are not supported for reliable spoofed return traffic (see the **Important** warning under **Requirements** in **Quick start**).
- VPS/network must allow outbound UDP IP spoofing.
