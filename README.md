# QS-Tunnel

**Send data with DNS Queries — Receive data with IP Spoofing**

QS-Tunnel is a covert, asymmetric UDP tunnel designed to bypass deep packet inspection (DPI) and censorship. It exploits the fact that DNS traffic is rarely blocked and that many network providers allow spoofed UDP replies to reach end-users.

> Related project (similar concept, different implementation): [QQ-Tunnel](https://github.com/patterniha/QQ-Tunnel)

---

## Table of Contents

1. [How It Works](#how-it-works)
2. [Modes](#modes)
3. [Prerequisites](#prerequisites)
4. [Installation](#installation)
5. [Server Configuration](#server-configuration)
6. [Client Configuration](#client-configuration)
7. [Running](#running)
8. [VPN Backend Integration](#vpn-backend-integration)
9. [Testing Tools](#testing-tools)
10. [Limitations](#limitations)
11. [Support](#support)

---

## How It Works

QS-Tunnel uses two completely different channels for the two directions of traffic:

```
CLIENT SIDE                                  SERVER SIDE
──────────────────────────────────────────────────────────────────
VPN App  ──UDP──►  h_inbound                 h_out  ──UDP──►  VPN Server
                        │                      ▲
                        │ base32-encode         │ forward
                        ▼                       │
               DNS query packets  ──UDP/53──►  wan_recv (port 53)
               (payload hidden                 (parses DNS labels,
                in subdomains)                  reassembles data)

VPN App  ◄─UDP──  wan_recv                   h_out  ◄─UDP──  VPN Server
                        ▲                      │
                        │ spoofed UDP           │ raw socket
                        │ from fake_send_ip     │ IP spoof
                        └──────────────────────┘
```

### Upload path (client → server)
1. The local VPN application sends a UDP packet to `h_in_address`.
2. The client base32-encodes the payload and fragments it across one or more DNS query names (embedded as subdomain labels, e.g. `<data>.<domain>`).
3. Each fragment is sent as a standard DNS `A`/`NS`/… query to one of the configured `dns_ips` (public DNS resolvers that forward queries to the server's domain).
4. The server listens on UDP port 53, parses incoming DNS queries, extracts and reassembles the payload, and forwards it to `h_out_address` (the local VPN server inbound).

### Download path (server → client)
1. The VPN server sends a UDP response to the server process via `h_out_address`.
2. The server builds a raw IPv4/UDP packet with a **spoofed source IP and port** (`fake_send_ip:fake_send_port` — chosen by the client and communicated to the server via encrypted info packets).
3. The spoofed packet is sent directly to the client's public IP and open port using a raw socket.
4. The client's `wan_recv` listener receives the spoofed packet and forwards it to the VPN application.

### Client identification and info exchange
Before data can flow, the client sends a special "info" DNS query (fragment part `63`, last_fragment=`false`) containing a 12-byte XOR-encrypted payload:

| Bytes | Content |
|-------|---------|
| 0–3 | Client public IPv4 |
| 4–5 | Client open UDP port (for spoofed replies) |
| 6–9 | Desired spoof source IPv4 (`fake_send_ip`) |
| 10–11 | Desired spoof source port (`fake_send_port`) |

The encryption key is `SHA-256(info_encryption_pass)`, which must match on both sides.

### Fragmentation protocol
Each DNS query subdomain label set carries:
- `client_id` (7 base32 chars in n-1 mode, absent in 1-1 mode)
- `data_offset` (3 base32 chars — rolling packet sequence number)
- `fragment_part` (1 base32 char + 1 magic byte: `0`/`1` for parts 0–31, `8`/`9` for parts 32–63; `1`/`9` = last fragment)
- `chunk_data` (remaining label space, base32-encoded payload chunk)

The server uses `DataHandler` to reassemble fragments by `data_offset` key within a 13-second window.

---

## Modes

### `1-1` — Tunnel mode (single client / relay server)

```
User Device ──any protocol──► Iran Relay Server ──DNS queries──► Abroad Server
                               (runs main_client.py)             (runs main_server.py)
                                       ▲
                               (VPN panel installed here)
                                spoofed UDP ◄──────────────────────┘
```

- The client side runs on an **Iran relay server** (not on the end user's device).
- Users connect to the relay server using any protocol; the relay uses Hysteria/WireGuard/xhttp-h3 as its outbound (pointing to `h_in_address`).
- Upload bandwidth is shared (~1 Mbps total) — only suitable for a small number of users.
- Set `"mode": "1-1"` in both `config_client.json` and `config_server.json`.

### `n-1` — Direct mode (multiple clients)

```
User Device A ──DNS queries──►
User Device B ──DNS queries──►  Abroad Server (main_server.py)
User Device C ──DNS queries──►
        ▲▲▲
        ║║║  spoofed UDP (per-client fake_send_ip:fake_send_port)
        ╚╩╝
```

- Each user runs `main_client.py` **directly on their own device** (no relay server needed).
- Each client is identified by a random 7-character base32 `client_id`.
- Each client picks its own `fake_send_ip:fake_send_port` — the IP/port from which the server will spoof replies.
- Upload bandwidth is **per-client** independent (no sharing bottleneck).
- **Requires a non-CGNAT connection** (home/fixed broadband). Mobile networks (which change source ports via CGNAT) are not supported because the client's open port must remain stable.
- Set `"mode": "n-1"` in both config files.

---

## Prerequisites

### Server (abroad / outside censorship zone)
- Linux with raw socket capability (`CAP_NET_RAW` or root)
- The server's network provider must **allow IP spoofing** on outbound UDP packets
- Python ≥ 3.12
- `numba` (used for fast IP/UDP checksum calculation)

### Client
- Python ≥ 3.12
- `aiohttp` (optional — only needed if using `"ezping"/"ipnumberia"/"ipmyp"` for automatic public IP detection)
- A non-CGNAT internet connection for `n-1` mode
- A VPN backend that speaks UDP: **Hysteria 2**, **WireGuard**, or **xhttp-h3 over QUIC** (see [VPN Backend Integration](#vpn-backend-integration))

### DNS infrastructure
- One or more DNS resolver IPs that will forward queries for your domain(s) to your server.
  - Point your domain's NS records to your server, or use a custom authoritative DNS setup.
  - Many public DNS resolvers cap label length: use `max_domain_len` ≤ 99 or switch `send_query_type_int` to a different record type (A=1, NS=2, etc.).

---

## Installation

```bash
git clone https://github.com/milad-mamandi/QS-Tunnel.git
cd QS-Tunnel
pip install -r requirements.txt   # server: numba; client: aiohttp (optional)
```

---

## Server Configuration

Edit `config_server.json`:

```json
{
  "mode": "n-1",
  "receive_port": 53,
  "recv_domains": ["tunnel.example.com"],
  "h_out_address": "127.0.0.1:443",
  "info_decryption_pass": "your-shared-secret"
}
```

| Key | Description |
|-----|-------------|
| `mode` | `"1-1"` (single client) or `"n-1"` (multi-client) |
| `receive_port` | UDP port to listen on for DNS queries — usually `53` |
| `recv_domains` | List of domains whose queries this server should accept (suffix match) |
| `h_out_address` | `ip:port` of the local VPN server inbound (e.g. Hysteria/WireGuard listener) |
| `info_decryption_pass` | Shared secret for decrypting client info packets — must match client's `info_encryption_pass` |

---

## Client Configuration

Edit `config_client.json`:

```json
{
  "mode": "n-1",
  "dns_ips": ["8.8.8.8", "1.1.1.1"],
  "send_domains": ["tunnel.example.com"],
  "fake_send_ip": "1.2.3.4",
  "fake_send_port": 443,
  "h_in_address": "127.0.0.1:10443",
  "max_domain_len": 99,
  "max_sub_len": 63,
  "retries": 1,
  "send_sock_numbers": 512,
  "my_public_ip": "ezping",
  "send_query_type_int": 1,
  "packets_send_interval": 0.001,
  "info_encryption_pass": "your-shared-secret"
}
```

| Key | Description |
|-----|-------------|
| `mode` | `"1-1"` or `"n-1"` — must match server |
| `dns_ips` | List of DNS resolver IPs to send queries to |
| `send_domains` | List of domains to use as query suffixes |
| `fake_send_ip` | IP address the server should spoof as the source of replies. Must be reachable from the server and allowed through the client's NAT/firewall |
| `fake_send_port` | Source port the server should use when spoofing replies |
| `h_in_address` | `ip:port` where the client listens for outbound data from the local VPN client |
| `max_domain_len` | Maximum DNS domain length in bytes (≤ 253; many resolvers cap at 99–151) |
| `max_sub_len` | Maximum label length (≤ 63, per DNS spec) |
| `retries` | Number of extra times each packet is sent (0 = send once, 1 = send twice) |
| `send_sock_numbers` | Number of parallel UDP send sockets (increase if hitting OS limits: `ulimit -n 32768`) |
| `my_public_ip` | Your public IPv4, or `"ezping"` / `"ipnumberia"` / `"ipmyp"` for auto-detection |
| `send_query_type_int` | DNS query type integer (1=A, 2=NS, 28=AAAA, etc.) |
| `packets_send_interval` | Delay in seconds between sending each DNS fragment (minimum 0.001 s; 0.1 s on Windows) |
| `info_encryption_pass` | Shared secret matching server's `info_decryption_pass` |

### Choosing `fake_send_ip` and `fake_send_port`
The server will spoof UDP packets *from* `fake_send_ip:fake_send_port` *to* your public IP and open port. For these spoofed packets to reach you:
- `fake_send_ip` must be an IP that your NAT/router will forward to you — typically the same IP/port you are already sending DNS queries from (i.e. a DNS resolver IP), or any IP that your NAT has an open mapping for.
- If you are behind NAT, run `nat_keep_alive_test.py` (see [Testing Tools](#testing-tools)) to keep the mapping open before testing spoofing.

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

On Android (Termux), run `main_client.py` directly. If using a VPN app like v2rayNG, make sure to **exclude** the Termux process from the VPN tunnel (otherwise DNS queries will loop through the VPN).

---

## VPN Backend Integration

QS-Tunnel is a **UDP forwarder** only. It does not encrypt data or handle routing by itself. You need a reliable UDP-based VPN protocol to carry actual traffic through the tunnel.

Recommended backends (example configs in `examples/`):
- **Hysteria 2** — high-performance QUIC-based protocol (`examples/xray_core_hysteria/`)
- **xhttp-h3** — HTTP/3-based transport via Xray-core (`examples/xray_core_xhttp_h3/`)
- **WireGuard** — straightforward UDP VPN

### Wiring diagram (n-1, direct mode)

```
User Apps
    │
    ▼
VPN Client (e.g. Hysteria client / Xray)
    │  outbound UDP to h_in_address
    ▼
main_client.py  (h_inbound listening on h_in_address)
    │  DNS queries → dns_ips → server's domain
    ▼
[internet — DNS infrastructure]
    │
    ▼
main_server.py  (listening on port 53)
    │  forward to h_out_address
    ▼
VPN Server (e.g. Hysteria server / Xray)
    │  response UDP back to main_server.py
    ▼
main_server.py  (raw socket, IP-spoofed reply to client)
    │
    ▼
main_client.py  (wan_recv receives spoofed packet)
    │  forward to last_h_addr (VPN client)
    ▼
VPN Client
    │
    ▼
User Apps
```

The VPN client's outbound should point to `h_in_address`. On the server, `h_out_address` should point to the VPN server's inbound listener.

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

If the client is behind NAT, first run `nat_keep_alive_test.py` on the client side to open a NAT mapping.

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

- **Upload speed cap (~1 Mbps per client in 1-1 mode):** DNS query rate is throttled by `packets_send_interval` and resolver forwarding latency. In n-1 mode each client has its own independent upload budget.
- **CGNAT incompatibility (n-1 mode):** Mobile/shared NATs rewrite source ports unpredictably, making it impossible for the server to reliably spoof replies to the correct port.
- **IP spoofing availability:** Not all cloud providers permit raw socket IP spoofing. You must test whether your server provider allows it (most VPS providers in certain regions do; most major cloud providers block it by default).
- **DNS resolver length limits:** Many resolvers silently drop queries with labels longer than 63 bytes or domains longer than 99–151 bytes. Tune `max_domain_len` and `send_query_type_int` accordingly.
- **No built-in encryption of payload:** The data channel relies entirely on the VPN backend (Hysteria/WireGuard/xhttp-h3) for encryption. The info packet (client IP/port/spoof settings) is XOR-encrypted with a SHA-256-derived key.
- **Python ≥ 3.12 required**; `numba` must be installed on the server (JIT-compiled checksum).

---

## Support

If this project helped you access a free internet, please consider a donation:

**USDT (BEP20):** `0x76a768B53Ca77B43086946315f0BDF21156bF424`

Telegram:
- https://t.me/projectXhttp
- https://t.me/patterniha
