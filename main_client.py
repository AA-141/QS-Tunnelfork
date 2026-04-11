import asyncio
import random
import socket
import json
import os
import sys
import hashlib
import re
import ssl
import uuid as uuid_module
from urllib.parse import urlparse, parse_qs, unquote

import aiohttp

CLIENT_ID_WIDTH = 3


def bytes_xor(data: bytes, key: bytes) -> bytes:
    return bytes(data[i] ^ key[i % len(key)] for i in range(len(data)))


def create_v4_udp_dgram_socket(blocking: bool, bind_addr: tuple[str, int] | None = None) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setblocking(blocking)
    if bind_addr is not None:
        s.bind(bind_addr)
    return s


def parse_vless_url(url: str) -> dict:
    """Parse a vless:// URL into its components."""
    parsed = urlparse(url)
    if parsed.scheme != "vless":
        raise ValueError(f"Expected vless:// URL, got scheme: {parsed.scheme!r}")
    raw_uuid = parsed.username
    if not raw_uuid:
        raise ValueError("VLESS URL missing UUID")
    try:
        uuid_bytes = uuid_module.UUID(raw_uuid).bytes
    except ValueError as e:
        raise ValueError(f"Invalid UUID in VLESS URL: {e}") from e
    host = parsed.hostname
    port = parsed.port
    if not host or not port:
        raise ValueError("VLESS URL missing host or port")
    params = parse_qs(parsed.query)
    transport = params.get("type", ["tcp"])[0]
    security = params.get("security", ["none"])[0]
    path = unquote(params.get("path", ["/"])[0])
    sni = params.get("sni", [host])[0]
    ws_host_header = params.get("host", [host])[0]
    return {
        "uuid_bytes": uuid_bytes,
        "host": host,
        "port": port,
        "transport": transport,
        "security": security,
        "path": path,
        "sni": sni,
        "ws_host_header": ws_host_header,
    }


def build_vless_udp_request_header(uuid_bytes: bytes, dest_host: str, dest_port: int) -> bytes:
    """
    Build a VLESS request header for UDP.
      [1B version=0][16B UUID][1B addon_len=0][1B cmd=0x02 UDP]
      [2B dest_port BE][1B addr_type=1 IPv4][4B dest_IPv4]
    """
    header = bytearray()
    header.append(0x00)                             # version
    header.extend(uuid_bytes)                       # UUID (16 bytes)
    header.append(0x00)                             # addon length (none)
    header.append(0x02)                             # command: UDP
    header.extend(dest_port.to_bytes(2, "big"))     # destination port
    header.append(0x01)                             # address type: IPv4
    header.extend(socket.inet_aton(dest_host))      # destination IPv4
    return bytes(header)


with open(os.path.join(os.path.dirname(sys.argv[0]), "config_client.json")) as f:
    config = json.loads(f.read())

info_encryption_pass = hashlib.sha256(config["info_encryption_pass"].encode()).digest()

client_id_bytes = os.urandom(CLIENT_ID_WIDTH)
print(f"[init] client_id: {client_id_bytes.hex()}")

# --- Determine upload mode: built-in VLESS or external dokodemo-door ---
vless_cfg_str = config.get("vless_config", "").strip()
bridge_addr_str = config.get("bridge_address", "").strip()
xray_bridge_str = config.get("xray_bridge_inbound", "").strip()

# Try to parse the VLESS URL and bridge address to decide whether built-in VLESS mode is usable.
# Both vless_config and bridge_address must be non-empty and well-formed; otherwise fall back
# to the dokodemo-door (xray_bridge_inbound) path.
_vless_info_tentative = None
_bridge_host_tentative = None
_bridge_port_tentative = None
if vless_cfg_str and bridge_addr_str:
    try:
        _vless_info_tentative = parse_vless_url(vless_cfg_str)
        _bh, _bp = bridge_addr_str.rsplit(":", 1)
        _bridge_host_tentative = _bh
        _bridge_port_tentative = int(_bp)
    except Exception:
        _vless_info_tentative = None

use_builtin_vless = _vless_info_tentative is not None

if use_builtin_vless:
    print("[init] Upload mode: built-in VLESS WebSocket client")
    vless_info = _vless_info_tentative
    bridge_host = _bridge_host_tentative
    bridge_port_num = _bridge_port_tentative
    print(f"[init] VLESS server: {vless_info['host']}:{vless_info['port']}, "
          f"transport={vless_info['transport']}, security={vless_info['security']}, "
          f"path={vless_info['path']!r}")
    print(f"[init] QS-Tunnel bridge target: {bridge_host}:{bridge_port_num}")
    xray_bridge_addr = None
    xray_bridge_socket = None
else:
    print("[init] Upload mode: external Xray dokodemo-door (xray_bridge_inbound)")
    if not xray_bridge_str:
        raise ValueError("Neither 'vless_config'+'bridge_address' nor 'xray_bridge_inbound' is configured")
    xray_bridge_addr = (xray_bridge_str.rsplit(":", 1)[0], int(xray_bridge_str.rsplit(":", 1)[1]))
    xray_bridge_socket = create_v4_udp_dgram_socket(False, None)
    print(f"[init] Xray bridge inbound: {xray_bridge_addr}")
    vless_info = None
    bridge_host = bridge_port_num = None

server_reg_addr = (config["server_registration_address"].rsplit(":", 1)[0],
                   int(config["server_registration_address"].rsplit(":", 1)[1]))
print(f"[init] Registration server: {server_reg_addr}")

h_inbound_bind_addr = (config["h_in_address"].rsplit(":", 1)[0],
                       int(config["h_in_address"].rsplit(":", 1)[1]))
print(f"[init] VPN app listen address: {h_inbound_bind_addr}")

h_inbound_socket = create_v4_udp_dgram_socket(False, h_inbound_bind_addr)

fake_send_ip = config["fake_send_ip"]
fake_send_port = int(config["fake_send_port"])
print(f"[init] Spoof source (fake_send_ip:port): {fake_send_ip}:{fake_send_port}")

wan_main_socket = create_v4_udp_dgram_socket(False, ("0.0.0.0", 0))
wan_main_socket_port = int(wan_main_socket.getsockname()[1])
print(f"[init] WAN receive socket bound to port: {wan_main_socket_port}")

last_h_addr = None

# Queue for outbound VLESS packets (used only when use_builtin_vless is True)
vless_send_queue: asyncio.Queue[bytes] = asyncio.Queue()


# ---------------------------------------------------------------------------
# Built-in VLESS WebSocket UDP client
# ---------------------------------------------------------------------------

async def _vless_send_loop(ws, is_tls: bool):
    """Read packets from vless_send_queue and send them over the WebSocket."""
    header_sent = False
    print("[vless] Send loop started")
    while True:
        data = await vless_send_queue.get()
        if not header_sent:
            req_header = build_vless_udp_request_header(
                vless_info["uuid_bytes"], bridge_host, bridge_port_num
            )
            frame = req_header + len(data).to_bytes(2, "big") + data
            header_sent = True
            print(f"[vless] Sent VLESS request header + first UDP packet ({len(data)} bytes)")
        else:
            frame = len(data).to_bytes(2, "big") + data
        await ws.send_bytes(frame)


async def _vless_drain_loop(ws):
    """
    Read and discard data arriving on the WebSocket.
    The download path uses IP spoofing (wan_recv), so WebSocket responses
    from the VLESS server are not meaningful for us — but we must drain them
    to avoid back-pressure that would stall the connection.
    """
    header_received = False
    print("[vless] Drain loop started")
    async for msg in ws:
        if msg.type == aiohttp.WSMsgType.BINARY:
            if not header_received:
                header_received = True
                data = msg.data
                addon_len = data[1] if len(data) >= 2 else 0
                print(f"[vless] Server response header received (addon_len={addon_len})")
            # Discard — download comes via IP-spoofed UDP in wan_recv()
        elif msg.type in (aiohttp.WSMsgType.CLOSE, aiohttp.WSMsgType.ERROR):
            print(f"[vless] WebSocket closed/error in drain loop: type={msg.type}")
            break
    print("[vless] Drain loop exiting")


async def vless_manager():
    """
    Maintains a persistent VLESS WebSocket UDP connection.
    Reconnects automatically on failure.
    """
    security = vless_info["security"]
    scheme = "wss" if security in ("tls", "reality") else "ws"
    ws_url = f"{scheme}://{vless_info['host']}:{vless_info['port']}{vless_info['path']}"
    headers = {"Host": vless_info["ws_host_header"]}
    ssl_context = None
    if scheme == "wss":
        ssl_context = ssl.create_default_context()
        ssl_context.check_hostname = False
        ssl_context.verify_mode = ssl.CERT_NONE

    print(f"[vless] Manager started — will connect to {ws_url}")

    while True:
        try:
            print(f"[vless] Connecting to {ws_url} ...")
            async with aiohttp.ClientSession(headers=headers) as session:
                async with session.ws_connect(
                    ws_url,
                    ssl=ssl_context,
                    heartbeat=30,
                    receive_timeout=None,
                ) as ws:
                    print(f"[vless] WebSocket connected to {ws_url}")
                    send_task = asyncio.create_task(_vless_send_loop(ws, scheme == "wss"))
                    drain_task = asyncio.create_task(_vless_drain_loop(ws))

                    done, pending = await asyncio.wait(
                        [send_task, drain_task],
                        return_when=asyncio.FIRST_COMPLETED,
                    )
                    for t in pending:
                        t.cancel()
                        try:
                            await t
                        except (asyncio.CancelledError, Exception):
                            pass
                    for t in done:
                        exc = t.exception()
                        if exc:
                            print(f"[vless] Task ended with error: {exc}")

        except Exception as e:
            print(f"[vless] Connection error: {e}")

        print("[vless] Reconnecting in 3 seconds...")
        await asyncio.sleep(3)


# ---------------------------------------------------------------------------
# Core tunnel tasks
# ---------------------------------------------------------------------------

async def h_recv():
    """Receive UDP from the local VPN app and forward upstream (via VLESS or dokodemo-door)."""
    loop = asyncio.get_running_loop()
    global h_inbound_socket
    global last_h_addr
    print(f"[h_recv] Listening for VPN app traffic on {h_inbound_bind_addr}")
    while True:
        use_socket = h_inbound_socket
        try:
            raw_data, addr_h = await loop.sock_recvfrom(use_socket, 65535)
        except Exception as e:
            print(f"[h_recv] Receive error: {e}")
            use_socket.close()
            while True:
                if h_inbound_socket != use_socket:
                    break
                try:
                    h_inbound_socket = create_v4_udp_dgram_socket(False, h_inbound_bind_addr)
                    print("[h_recv] Socket recreated")
                    break
                except Exception as e:
                    print(f"[h_recv] Socket recreate error: {e}")
                    await asyncio.sleep(1)
            continue

        if not raw_data:
            continue

        if last_h_addr != addr_h:
            last_h_addr = addr_h
            print(f"[h_recv] VPN app address updated: {addr_h}")

        packet = client_id_bytes + raw_data

        if use_builtin_vless:
            try:
                vless_send_queue.put_nowait(packet)
            except asyncio.QueueFull:
                print("[h_recv] VLESS send queue full, dropping packet")
        else:
            try:
                await loop.sock_sendto(xray_bridge_socket, packet, xray_bridge_addr)
            except Exception as e:
                print(f"[h_recv] xray_bridge_socket send error: {e}")


async def wan_recv():
    """Receive IP-spoofed UDP replies from the server and forward to the VPN app."""
    loop = asyncio.get_running_loop()
    global h_inbound_socket
    print(f"[wan_recv] Listening for spoofed replies on port {wan_main_socket_port}")
    while True:
        try:
            data, addr_w = await loop.sock_recvfrom(wan_main_socket, 65535)
        except Exception as e:
            print(f"[wan_recv] Receive error: {e}")
            raise

        if not data:
            continue

        if last_h_addr is None:
            print("[wan_recv] Received packet but no VPN app address yet, discarding")
            continue

        use_socket = h_inbound_socket
        try:
            await loop.sock_sendto(use_socket, data, last_h_addr)
        except Exception as e:
            print(f"[wan_recv] Forward to VPN app error: {e}")
            use_socket.close()
            while True:
                if h_inbound_socket != use_socket:
                    break
                try:
                    h_inbound_socket = create_v4_udp_dgram_socket(False, h_inbound_bind_addr)
                    print("[wan_recv] Socket recreated")
                    break
                except Exception as e:
                    print(f"[wan_recv] Socket recreate error: {e}")
                    await asyncio.sleep(1)


async def reg_send(my_public_ip: str):
    """Send registration packets to the QS-Tunnel server every 20 seconds."""
    loop = asyncio.get_running_loop()
    reg_socket = create_v4_udp_dgram_socket(False, None)
    info_plain = (
        socket.inet_pton(socket.AF_INET, my_public_ip) +
        wan_main_socket_port.to_bytes(2, byteorder="big") +
        socket.inet_pton(socket.AF_INET, fake_send_ip) +
        fake_send_port.to_bytes(2, byteorder="big")
    )
    info_encrypted = bytes_xor(info_plain, info_encryption_pass)
    reg_packet = client_id_bytes + info_encrypted
    print(f"[reg_send] Will register as public IP {my_public_ip}, "
          f"WAN port {wan_main_socket_port}, "
          f"fake_send {fake_send_ip}:{fake_send_port}")
    while True:
        try:
            await loop.sock_sendto(reg_socket, reg_packet, server_reg_addr)
            print(f"[reg_send] Registration packet sent to {server_reg_addr}")
        except Exception as e:
            print(f"[reg_send] Send error: {e}")
        await asyncio.sleep(20)


async def nat_keep_alive():
    """Send periodic keep-alive packets to keep the NAT mapping open."""
    loop = asyncio.get_running_loop()
    print(f"[nat_keep_alive] Sending keep-alives to {fake_send_ip}:{fake_send_port} every 2s")
    while True:
        try:
            await asyncio.sleep(2)
            data = os.urandom(random.randint(257, 499))
            await loop.sock_sendto(wan_main_socket, data, (fake_send_ip, fake_send_port))
        except Exception as e:
            print(f"[nat_keep_alive] Send error: {e}")
            raise


async def fetch_ip(url: str):
    print(f"[fetch_ip] Fetching public IP from {url}")
    async with aiohttp.ClientSession() as session:
        async with session.get(url) as response:
            response.raise_for_status()
            text = await response.text()
            ip_regex = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
            match = ip_regex.search(text)
            if match:
                print(f"[fetch_ip] Detected public IP: {match.group(0)}")
                return match.group(0)
            raise ValueError(f"No IP address found in response from {url}")


async def main():
    loop = asyncio.get_running_loop()
    my_public_ip = config["my_public_ip"]
    if my_public_ip == "ezping":
        my_public_ip = await fetch_ip("https://ezping.ir/geoip")
    elif my_public_ip == "ipnumberia":
        my_public_ip = await fetch_ip("https://ipnumberia.com/")
    elif my_public_ip == "ipmyp":
        my_public_ip = await fetch_ip("https://ipmyp.ir/")
    else:
        print(f"[main] Using configured public IP: {my_public_ip}")

    print(f"[main] Public IP: {my_public_ip}")

    print("[main] Sending initial NAT punch packets...")
    for i in range(3):
        data = os.urandom(random.randint(257, 499))
        await loop.sock_sendto(wan_main_socket, data, (fake_send_ip, fake_send_port))
        print(f"[main] NAT punch packet {i + 1}/3 sent to {fake_send_ip}:{fake_send_port}")
        await asyncio.sleep(0.001)

    tasks = [
        asyncio.create_task(h_recv()),
        asyncio.create_task(wan_recv()),
        asyncio.create_task(reg_send(my_public_ip)),
        asyncio.create_task(nat_keep_alive()),
    ]

    if use_builtin_vless:
        tasks.append(asyncio.create_task(vless_manager()))
        print("[main] Built-in VLESS manager task added")

    print("[main] All tasks started — tunnel is running")
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    print("[main] A task completed unexpectedly, shutting down")


asyncio.run(main())
