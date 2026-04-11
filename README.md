# QS-Tunnel

**Send data with any VLESS config — Receive data with IP Spoofing**

QS-Tunnel is an asymmetric UDP tunnel designed to bypass deep packet inspection (DPI) and censorship. It uses a user-managed Xray/VLESS connection for the upload path (a cheap few-KB trickle), while the much larger download path is delivered via raw IP-spoofed UDP — costing nothing on the VLESS side.

> Related project (similar concept, different implementation): [QQ-Tunnel](https://github.com/patterniha/QQ-Tunnel)

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Prerequisites](#prerequisites)
3. [Installation](#installation)
4. [Server Configuration](#server-configuration)
5. [Client Configuration](#client-configuration)
6. [Running](#running)
7. [Xray Wiring](#xray-wiring)
8. [VPN Backend Integration](#vpn-backend-integration)
9. [Testing Tools](#testing-tools)
10. [Limitations](#limitations)
11. [Support](#support)

---

## How It Works

QS-Tunnel uses two completely different channels for the two directions of traffic:

```
CLIENT SIDE                                        SERVER SIDE
─────────────────────────────────────────────────────────────────────────
VPN App ──UDP──► h_in_address                      h_out ──UDP──► VPN Server
                      │                               ▲
                      │ prepend [3B client_id]        │ forward
                      ▼                               │
             xray_bridge_inbound              bridge_recv (:bridge_port)
             (user's Xray inbound)
                      │
                      │ Xray/VLESS (user-managed)
                      ▼
             [purchased VLESS server]
                      │ forwards to SERVER_IP:bridge_port
                      └───────────────────────────────►

VPN App ◄─UDP── wan_recv                           h_out ◄─UDP── VPN Server
                      ▲                               │
                      │ spoofed UDP                   │ raw socket
                      │ from fake_send_ip             │ IP spoof
                      └───────────────────────────────┘
```

### Upload path (client → server) — uses tiny VLESS bandwidth

1. The local VPN application sends a UDP packet to `h_in_address`.
2. QS-Tunnel client prepends a 3-byte `client_id` and forwards the packet to `xray_bridge_inbound` — a local UDP address where the user's Xray `dokodemo-door` inbound is listening.
3. Xray carries the packet via the user's VLESS connection to their purchased Xray server.
4. The Xray server must be configured to forward incoming UDP to `SERVER_IP:bridge_port`.
5. QS-Tunnel server receives the packet, strips the `client_id` header, and forwards the payload to `h_out_address` (the local VPN server inbound).

### Download path (server → client) — free, uses no VLESS bandwidth

1. The VPN server sends a UDP response to the server process via `h_out_address`.
2. The server builds a raw IPv4/UDP packet with a **spoofed source IP and port** (`fake_send_ip:fake_send_port` — chosen by the client and communicated via encrypted registration packets).
3. The spoofed packet is sent directly to the client's public IP and open port using a raw socket.
4. The client's `wan_recv` listener receives the spoofed packet and forwards it to the VPN application.

### Client registration

Before data can flow, the client sends a 15-byte registration packet to the server's `registration_port` every 20 seconds:

```
[ client_id (3 bytes) ] [ XOR-encrypted info (12 bytes) ]
```

The 12-byte info payload (encrypted with `SHA-256(info_encryption_pass)`) contains:

| Bytes | Content |
|-------|---------|
| 0–3   | Client public IPv4 |
| 4–5   | Client open UDP port (for spoofed replies) |
| 6–9   | Desired spoof source IPv4 (`fake_send_ip`) |
| 10–11 | Desired spoof source port (`fake_send_port`) |

---

## Prerequisites

### Server (abroad / outside censorship zone)

- Linux with raw socket capability (`CAP_NET_RAW` or root)
- The server's network provider must **allow IP spoofing** on outbound UDP packets
- Python ≥ 3.12
- `aiohttp` is not required on the server

### Client

- Python ≥ 3.12
- `aiohttp` (only needed if using `"ezping"/"ipnumberia"/"ipmyp"` for automatic public IP detection)
- A non-CGNAT internet connection (your public UDP port must remain stable)
- A running Xray instance with a working VLESS outbound pointing to your purchased Xray server, and a `dokodemo-door` UDP inbound on `xray_bridge_inbound`
- A VPN backend that speaks UDP: **Hysteria 2**, **WireGuard**, or **xhttp-h3 over QUIC** (see [VPN Backend Integration](#vpn-backend-integration))

---

## Installation

```bash
git clone https://github.com/milad-mamandi/QS-Tunnel.git
cd QS-Tunnel
pip install -r requirements.txt   # client only: aiohttp
```

---

## Server Configuration

Edit `config_server.json`:

```json
{
  "registration_port": 5300,
  "bridge_port": 5301,
  "h_out_address": "127.0.0.1:443",
  "info_decryption_pass": "your-shared-secret"
}
```

| Key | Description |
|-----|-------------|
| `registration_port` | UDP port the server listens on for client registration packets |
| `bridge_port` | UDP port the server listens on for data forwarded by the user's Xray server |
| `h_out_address` | `ip:port` of the local VPN server inbound (e.g. Hysteria/WireGuard listener) |
| `info_decryption_pass` | Shared secret for decrypting client registration packets — must match client's `info_encryption_pass` |

---

## Client Configuration

Edit `config_client.json`:

```json
{
  "server_registration_address": "SERVER_IP:5300",
  "xray_bridge_inbound": "127.0.0.1:5302",
  "h_in_address": "127.0.0.1:10443",
  "fake_send_ip": "1.2.3.4",
  "fake_send_port": 443,
  "my_public_ip": "ezping",
  "info_encryption_pass": "your-shared-secret"
}
```

| Key | Description |
|-----|-------------|
| `server_registration_address` | `ip:port` of QS-Tunnel server's registration listener |
| `xray_bridge_inbound` | `ip:port` of the local Xray `dokodemo-door` UDP inbound |
| `h_in_address` | `ip:port` where the client listens for outbound data from the local VPN client |
| `fake_send_ip` | IP the server should spoof as the source of replies. Must be an IP your NAT already has an open mapping for (typically `fake_send_ip` of a DNS resolver or any IP you send keep-alives to) |
| `fake_send_port` | Source port the server should use when spoofing replies |
| `my_public_ip` | Your public IPv4, or `"ezping"` / `"ipnumberia"` / `"ipmyp"` for auto-detection |
| `info_encryption_pass` | Shared secret matching server's `info_decryption_pass` |

---

## Running

### Server
```bash
# Requires root or CAP_NET_RAW for raw socket IP spoofing
sudo python main_server.py
```

### Client
```bash
python main_client.py
```

---

## Xray Wiring

QS-Tunnel does **not** manage or configure Xray. You set up and run Xray independently. The only requirement is:

**On the client side** — Xray must have a `dokodemo-door` UDP inbound on the address set in `xray_bridge_inbound` (default `127.0.0.1:5302`), with its traffic routed through your VLESS outbound toward the purchased Xray server.

**On the server side (your purchased Xray server)** — its outbound for the traffic coming from QS-Tunnel must forward UDP to `QS_TUNNEL_SERVER_IP:bridge_port` (default `bridge_port` 5301). Because you do not own the purchased Xray server, you will need to configure it with an outbound rule that forwards to the QS-Tunnel server you *do* control.

### Minimal client-side Xray snippet (dokodemo-door inbound)

```json
{
  "inbounds": [
    {
      "tag": "qs-bridge-in",
      "protocol": "dokodemo-door",
      "listen": "127.0.0.1",
      "port": 5302,
      "settings": {
        "address": "QS_TUNNEL_SERVER_IP",
        "port": 5301,
        "network": "udp"
      }
    }
  ]
}
```

Add your existing VLESS outbound and routing rules so that traffic tagged `qs-bridge-in` exits via the VLESS outbound.

> **Note:** The `address`/`port` inside `dokodemo-door` settings sets the destination the dokodemo-door forwards to — this should be the QS-Tunnel server's `bridge_port`. Adjust to match your setup.

---

## VPN Backend Integration

QS-Tunnel is a **UDP forwarder** only. It does not encrypt data or handle routing by itself. You need a reliable UDP-based VPN protocol to carry actual traffic through the tunnel.

Recommended backends (example configs in `examples/`):
- **Hysteria 2** — high-performance QUIC-based protocol (`examples/xray_core_hysteria/`)
- **xhttp-h3** — HTTP/3-based transport via Xray-core (`examples/xray_core_xhttp_h3/`)
- **WireGuard** — straightforward UDP VPN

### Wiring diagram

```
User Apps
    │
    ▼
VPN Client (e.g. Hysteria client / Xray)
    │  outbound UDP to h_in_address
    ▼
main_client.py  (listening on h_in_address)
    │  prepend client_id → xray_bridge_inbound (Xray dokodemo-door)
    ▼
Xray process (user-managed)
    │  VLESS outbound → purchased Xray server → forwards to SERVER_IP:bridge_port
    ▼
main_server.py  (bridge_recv on bridge_port)
    │  strip client_id → forward to h_out_address
    ▼
VPN Server (e.g. Hysteria server / Xray)
    │  response UDP back to main_server.py
    ▼
main_server.py  (raw socket, IP-spoofed reply to client)
    │
    ▼
main_client.py  (wan_recv receives spoofed packet → forward to last_h_addr)
    │
    ▼
VPN Client
    │
    ▼
User Apps
```

---

## Testing Tools

### `spoof_udp_test.py` — Verify IP spoofing works
Run on the **server** to send a single spoofed UDP packet to a target IP:

```python
# Edit at the top of spoof_udp_test.py:
SPOOFED_SRC_IP = "1.1.1.1"   # IP the server will pretend to send from
DST_IP = "2.2.2.2"            # Client's public IP
UDP_SRC_PORT = 443
UDP_DST_PORT = 60443           # Client's open port
DATA = b"1234"
```

```bash
sudo python spoof_udp_test.py
```

### `nat_keep_alive_test.py` — Open/keep a NAT mapping
Run on the **client** to send keep-alive packets and hold a NAT mapping open:

```python
# Edit at the top of nat_keep_alive_test.py:
SPOOFED_DST_IP = "1.1.1.1"   # IP to send keep-alives to (must be reachable)
UDP_SRC_PORT = 60443           # Local port to bind
UDP_DST_PORT = 443
```

```bash
python nat_keep_alive_test.py
```

---

## Limitations

- **Upload speed limited by VLESS config:** Each upstream packet travels through the user's purchased VLESS config. Upload throughput is capped by that connection's latency and the VPN backend's packet rate.
- **CGNAT incompatibility:** Mobile/shared NATs rewrite source ports unpredictably, making it impossible for the server to reliably spoof replies to the correct port.
- **IP spoofing availability:** Not all cloud providers permit raw socket IP spoofing. You must test whether your server provider allows it.
- **No built-in encryption of payload:** The data channel relies entirely on the VPN backend (Hysteria/WireGuard/xhttp-h3) for encryption. The registration packet is XOR-encrypted with a SHA-256-derived key.
- **Python ≥ 3.12 required**

---

## Support

If this project helped you access a free internet, please consider a donation:

**USDT (BEP20):** `0x76a768B53Ca77B43086946315f0BDF21156bF424`

Telegram:
- https://t.me/projectXhttp
- https://t.me/patterniha
