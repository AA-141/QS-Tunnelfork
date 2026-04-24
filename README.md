# QS-Tunnel

Asymmetric UDP tunnel:
- **Upload:** tiny traffic through your VLESS config
- **Download:** IP-spoofed UDP (does not use VLESS bandwidth)

This README is quick-start first. Advanced details are in `examples/` and scripts.

## Quick start (recommended: WireGuard backend)

### 1) Requirements

- Linux VPS (server) with root access
- VPS/network must allow outbound UDP IP spoofing
- UDP ports `5300` and `5301` open on server
- Python `3.12+` on client and server
- A purchased **VLESS WebSocket** URL (used only for upload path)
- A UDP VPN backend (WireGuard recommended)
- Non-CGNAT client internet (public UDP source port should stay stable)

> If your internet is behind CGNAT, spoofed replies may fail.

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
  "info_encryption_pass": "your-shared-secret"
}
```

Most important fields:
- `vless_config`: your purchased VLESS **WS** URL
- `bridge_address`: server `IP:bridge_port` (usually `YOUR_SERVER_IP:5301`)
- `h_in_address`: where your VPN client sends UDP locally (must match your VPN client endpoint)
- `info_encryption_pass`: must equal server secret
- `fake_send_ip` / `fake_send_port`: spoofed source IP:port for server replies (commonly `1.1.1.1:443`)

### 5) Run

On server:
```bash
sudo python main_server.py
```

On client:
```bash
python main_client.py
```

Then start your VPN client (for WireGuard, point endpoint to `127.0.0.1:10443`).

---

## Minimal architecture

1. VPN client sends UDP to QS-Tunnel client (`h_in_address`)
2. QS-Tunnel client forwards upload via VLESS to server `bridge_port`
3. QS-Tunnel server forwards to your local VPN server (`h_out_address`)
4. Replies return as spoofed UDP whose source is `fake_send_ip:fake_send_port` (the server pretends packets come from this IP:port)

---

## Examples and advanced setups

- WireGuard templates: `examples/wireguard/`
- Xray xhttp-h3 templates: `examples/xray_core_xhttp_h3/`
- Hysteria templates: `examples/xray_core_hysteria/`
- Spoofing test tool: `spoof_udp_test.py`
- NAT keep-alive tool: `nat_keep_alive_test.py`

---

## Notes

- QS-Tunnel is a UDP forwarder, not an encryption protocol by itself.
- Use a secure VPN backend (WireGuard / Hysteria / xhttp-h3).
- Python `3.12+` required.

### Known limitations

- CGNAT networks often break spoofed return traffic because NAT rewrites client source ports unpredictably, so server replies cannot reliably target the correct mapped port.
- VPS/network must allow outbound UDP IP spoofing.
