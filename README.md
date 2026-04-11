# QS-Tunnel

**Send data with any VLESS config — Receive data with IP Spoofing**

QS-Tunnel is an asymmetric UDP tunnel designed to bypass deep packet inspection (DPI) and censorship. It uses a user-managed Xray/VLESS connection for the upload path (a cheap few-KB trickle), while the much larger download path is delivered via raw IP-spoofed UDP — costing nothing on the VLESS side.

> Related project (similar concept, different implementation): [QQ-Tunnel](https://github.com/patterniha/QQ-Tunnel)

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Quick Start Guides](#quick-start-guides)
   - [Setup A — WireGuard (simplest)](#setup-a--wireguard-simplest)
   - [Setup B — xhttp-h3 with v2rayN on Windows](#setup-b--xhttp-h3-with-v2rayn-on-windows)
3. [Prerequisites](#prerequisites)
4. [Installation](#installation)
5. [Server Configuration](#server-configuration)
6. [Client Configuration](#client-configuration)
7. [Running](#running)
8. [Xray Wiring](#xray-wiring)
9. [VPN Backend Integration](#vpn-backend-integration)
10. [Testing Tools](#testing-tools)
11. [Limitations](#limitations)
12. [Support](#support)

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

## Quick Start Guides

These step-by-step guides each cover a complete, working setup. Pick the one that fits your situation.

> **Before you start** — you need two things no matter which guide you follow:
> 1. A Linux VPS **abroad** (outside the censorship zone) where you run QS-Tunnel server and the VPN server.
> 2. A **purchased VLESS/WebSocket proxy URL** (cheap, any provider) — this is used **only** for QS-Tunnel's upload path. It does **not** carry your VPN traffic; it is just a tiny signalling channel.

---

### Setup A — WireGuard (simplest)

WireGuard encrypts and routes your traffic. QS-Tunnel provides the asymmetric transport that carries it past censorship.

```
Your apps  →  WireGuard client  →  QS-Tunnel client  →  (VLESS upload)  →  QS-Tunnel server  →  WireGuard server
                                         ↑
                               replies arrive here via IP-spoofed UDP (free, no VLESS quota used)
```

**What you need:**
- Linux VPS with root access and UDP ports `5300` and `5301` open
- WireGuard installed on the VPS (`apt install wireguard`)
- WireGuard client on your PC ([wireguard.com/install](https://www.wireguard.com/install/))
- Python ≥ 3.12 on both machines
- A purchased VLESS/WS URL for the QS-Tunnel upload path

---

#### Step 1 — Server: set up WireGuard

```bash
# Generate server keys
wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
cat /etc/wireguard/server_public.key   # ← you will need this on the client
```

Create `/etc/wireguard/wg0.conf` (see `examples/wireguard/wg0_server.conf` for the full template):

```ini
[Interface]
PrivateKey = <SERVER_PRIVATE_KEY>
Address = 10.0.0.1/24
ListenPort = 51820
PostUp   = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE

[Peer]
PublicKey = <CLIENT_PUBLIC_KEY>    # fill in after Step 3
AllowedIPs = 10.0.0.2/32
```

Enable IP forwarding so the server can route internet traffic for clients:

```bash
echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf && sysctl -p
```

Start WireGuard:

```bash
sudo wg-quick up wg0
```

---

#### Step 2 — Server: configure and start QS-Tunnel

In `config_server.json` (or use `examples/wireguard/qs_tunnel_server.jsonc`):

```json
{
  "registration_port": 5300,
  "bridge_port": 5301,
  "h_out_address": "127.0.0.1:51820",
  "info_decryption_pass": "your-shared-secret"
}
```

`h_out_address` points QS-Tunnel at the local WireGuard listener (`ListenPort` from Step 1).

```bash
sudo python main_server.py
```

---

#### Step 3 — Client: generate WireGuard keys

**Windows (PowerShell, in the WireGuard install folder or any directory with `wg` in PATH):**
```powershell
wg genkey | Out-File -Encoding ASCII client_private.key
Get-Content client_private.key | wg pubkey | Out-File -Encoding ASCII client_public.key
Get-Content client_public.key   # ← copy this to the server's [Peer] PublicKey
```

**Linux:**
```bash
wg genkey | tee client_private.key | wg pubkey > client_public.key
cat client_public.key   # ← copy this to the server's [Peer] PublicKey
```

After copying the client public key to the server, reload WireGuard:
```bash
sudo wg syncconf wg0 <(wg-quick strip wg0)
```

---

#### Step 4 — Client: configure WireGuard

In WireGuard for Windows, click **Add Tunnel → Create from scratch** (or create a `.conf` file on Linux). Use `examples/wireguard/wg0_client.conf` as a template:

```ini
[Interface]
PrivateKey = <CLIENT_PRIVATE_KEY>
Address = 10.0.0.2/32
DNS = 1.1.1.1

[Peer]
PublicKey = <SERVER_PUBLIC_KEY>
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:10443
```

> **Why `127.0.0.1:10443`?** The `Endpoint` must point to QS-Tunnel's `h_in_address`. QS-Tunnel is listening there locally and will relay the WireGuard packets to the server. Do **not** put the real server IP here.

---

#### Step 5 — Client: configure QS-Tunnel

In `config_client.json` (or use `examples/wireguard/qs_tunnel_client.jsonc`):

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

Key fields:

| Field | What to set |
|---|---|
| `server_registration_address` | Your VPS public IP and port 5300 |
| `vless_config` | Your purchased VLESS/WS URL (for the upload path only) |
| `bridge_address` | Your VPS public IP and port 5301 |
| `h_in_address` | Must match the WireGuard `Endpoint` (`127.0.0.1:10443`) |
| `fake_send_ip` / `fake_send_port` | A stable public IP:port to open a NAT hole through (e.g. `1.1.1.1:443`). The server spoofs download replies as if they come from here. |
| `info_encryption_pass` | Must match `info_decryption_pass` on the server |

---

#### Step 6 — Client: start QS-Tunnel, then activate WireGuard

```bash
python main_client.py
```

Once QS-Tunnel prints `[main] All tasks started — tunnel is running`, click **Activate** in WireGuard for Windows (or `sudo wg-quick up wg0` on Linux). Your traffic now flows through the tunnel.

---

### Setup B — xhttp-h3 with v2rayN on Windows

Use this setup if you already run v2rayN on Windows and want to use Xray-core's xhttp-h3 (HTTP/3 over QUIC) as the VPN layer.

> **Two separate roles, two separate configs:**
> - **VPN layer (xhttp-h3):** Xray-core with xhttp-h3 transport — this encrypts and routes your traffic. Configured in v2rayN as a custom server.
> - **Upload transport (VLESS):** A cheap VLESS/WS proxy URL passed to QS-Tunnel's `vless_config`. Used only to carry the tiny upload signal. This is completely separate from the xhttp-h3 server.

```
Your apps
    │ (system proxy / TUN)
    ▼
v2rayN  ← uses the custom xhttp-h3 Xray config
    │ xhttp-h3 UDP → 127.0.0.1:10443  (QS-Tunnel's h_in_address)
    ▼
QS-Tunnel client
    │ upload: VLESS/WS → purchased proxy → YOUR_SERVER_IP:5301
    ▼
QS-Tunnel server
    │ → 127.0.0.1:443  (h_out_address = Xray xhttp-h3 server)
    ▼
Xray server (xhttp-h3 inbound)
    │ direct internet
    ▼
Destination
```

---

#### Step 1 — Server: generate a TLS certificate

```bash
# Self-signed (quick); replace CN with your domain or IP
openssl req -x509 -newkey rsa:2048 \
  -keyout /etc/xray/key.pem \
  -out /etc/xray/cert.pem \
  -days 365 -nodes \
  -subj "/CN=YOUR_SERVER_DOMAIN_OR_IP"

# Get the SHA-256 fingerprint (needed in the client config):
openssl x509 -in /etc/xray/cert.pem -noout -fingerprint -sha256 \
  | sed 's/://g' | awk -F= '{print $2}'
```

Note the fingerprint — you will paste it into the client config as `pinnedPeerCertSha256`.

---

#### Step 2 — Server: install Xray and configure xhttp-h3

Install Xray-core:
```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

Copy `examples/xray_core_xhttp_h3/xhttp_h3_server.jsonc` to `/etc/xray/config.json` and fill in every `// set` placeholder:

| Placeholder | Value |
|---|---|
| `listen` | `"0.0.0.0"` |
| `port` | `443` (or any free UDP port — keep it consistent with `h_out_address`) |
| `id` | a new UUID: `python3 -c "import uuid; print(uuid.uuid4())"` |
| `email` | any label, e.g. `"user@example.com"` |
| `serverName` | your server domain or IP |
| `certificateFile` | `/etc/xray/cert.pem` |
| `keyFile` | `/etc/xray/key.pem` |
| `host` (xhttpSettings) | your server domain or IP |
| `password` (salamander) | a random string, e.g. `"sal-secret-123"` |

Start Xray:
```bash
sudo systemctl start xray
```

Open the firewall for the port you chose (e.g. 443 UDP):
```bash
ufw allow 443/udp   # or use your cloud provider's security group
```

---

#### Step 3 — Server: configure and start QS-Tunnel

In `config_server.json`:

```json
{
  "registration_port": 5300,
  "bridge_port": 5301,
  "h_out_address": "127.0.0.1:443",
  "info_decryption_pass": "your-shared-secret"
}
```

`h_out_address` must match the Xray server's listen `port` from Step 2.

```bash
sudo python main_server.py
```

---

#### Step 4 — Client (Windows): add custom config to v2rayN

1. Open v2rayN.
2. Click **Servers** → **Add custom server**.
3. Paste the content of `examples/xray_core_xhttp_h3/xhttp_h3_client.jsonc` into the editor (or import the file).
4. Fill in every `// set` placeholder:

| Placeholder | Value |
|---|---|
| `address` | `"127.0.0.1"` — QS-Tunnel's `h_in_address` host |
| `port` | `10443` — QS-Tunnel's `h_in_address` port |
| `id` | the UUID you set on the server (Step 2) |
| `serverName` | your server domain or IP |
| `pinnedPeerCertSha256` | the fingerprint from Step 1 |
| `host` (xhttpSettings) | your server domain or IP |
| `password` (salamander) | same as server (Step 2) |

> **Why `address = "127.0.0.1"` and `port = 10443`?** v2rayN sends its xhttp-h3 packets to that address. QS-Tunnel is listening there and relays the packets to the server. The `serverName` / TLS fields still refer to the real server — TLS uses SNI, not the destination IP.

5. Set this server as **active** in v2rayN (right-click → **Set as active server**).

---

#### Step 5 — Client: configure QS-Tunnel

In `config_client.json`:

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

`vless_config` is the **transport VLESS** — a separate VLESS/WS proxy for QS-Tunnel's upload path only. It is **not** the xhttp-h3 server you set up in Steps 1–2. Paste a purchased WS/TLS VLESS URL here.

---

#### Step 6 — Client: start QS-Tunnel, then enable v2rayN proxy

```bash
python main_client.py
```

Once QS-Tunnel prints `[main] All tasks started — tunnel is running`, switch v2rayN to **System Proxy** mode (right-click the tray icon → **System Proxy → Automatically configure system proxy**), or enable TUN mode for full-device routing.

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
  "server_registration_address": "YOUR_SERVER_IP:5300",
  "vless_config": "",
  "bridge_address": "YOUR_SERVER_IP:5301",
  "xray_bridge_inbound": "",
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
| `vless_config` | **(Recommended)** Full VLESS URL from your purchased config — QS-Tunnel connects to the VLESS server directly, no separate Xray needed |
| `bridge_address` | `ip:port` of the QS-Tunnel server's bridge listener (e.g. `YOUR_SERVER_IP:5301`). Used when `vless_config` is set. The VLESS server will proxy UDP to this address |
| `xray_bridge_inbound` | **(Advanced / legacy)** `ip:port` of a local Xray `dokodemo-door` UDP inbound. Leave empty when using `vless_config` |
| `h_in_address` | `ip:port` where the client listens for outbound data from the local VPN client |
| `fake_send_ip` | IP the server should spoof as the source of replies. Must be an IP your NAT already has an open mapping for (typically a DNS resolver or any IP you send keep-alives to) |
| `fake_send_port` | Source port the server should use when spoofing replies |
| `my_public_ip` | Your public IPv4, or `"ezping"` / `"ipnumberia"` / `"ipmyp"` for auto-detection |
| `info_encryption_pass` | Shared secret matching server's `info_decryption_pass` |

> **Note:** Set **both** `vless_config` (a valid VLESS URL) **and** `bridge_address` (your server's `IP:bridge_port`) to enable built-in VLESS mode. If either is missing or invalid, QS-Tunnel falls back to `xray_bridge_inbound` mode. Only one mode is used at a time.

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

### Option A — Built-in VLESS client (recommended, no Xray config needed)

Paste your purchased VLESS URL directly into `vless_config` and set `bridge_address` to your QS-Tunnel server's `IP:bridge_port`. QS-Tunnel opens the WebSocket connection itself, sends packets via the VLESS protocol, and the purchased server proxies them to your bridge.

Example `config_client.json` with a WS/plain VLESS config:

```json
{
  "vless_config": "vless://eb4c65c7-0a09-4750-80e8-8cde3e026d0f@ezterar.popol.cfd:8443?encryption=none&security=none&type=ws&path=%2F",
  "bridge_address": "YOUR_SERVER_IP:5301",
  ...
}
```

Supported transports: `type=ws` (plain WebSocket) and `type=ws` with `security=tls` or `security=reality`.

### Option B — External Xray with dokodemo-door (advanced)

If you prefer to manage Xray yourself, leave `vless_config` empty and set `xray_bridge_inbound` to the address of a local Xray `dokodemo-door` UDP inbound:

```json
{
  "xray_bridge_inbound": "127.0.0.1:5302",
  ...
}
```

Minimal Xray inbound snippet (add to your existing Xray config):

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

---

## VPN Backend Integration

QS-Tunnel is a **UDP forwarder** only. It does not encrypt data or handle routing by itself. You need a reliable UDP-based VPN protocol to carry actual traffic through the tunnel.

Recommended backends (example configs in `examples/`):
- **WireGuard** — simple, widely supported UDP VPN. See [Setup A](#setup-a--wireguard-simplest) for a complete walkthrough and `examples/wireguard/` for ready-to-use config templates.
- **Hysteria 2** — high-performance QUIC-based protocol (`examples/xray_core_hysteria/`)
- **xhttp-h3** — HTTP/3-based transport via Xray-core (`examples/xray_core_xhttp_h3/`). See [Setup B](#setup-b--xhttp-h3-with-v2rayn-on-windows) for a complete v2rayN walkthrough.

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
