import asyncio
import random
import socket
import json
import os
import sys
import hashlib

from utility.packets import build_udp_payload_v4, build_ipv4_header, UDP_PROTO

CLIENT_ID_WIDTH = 3


def bytes_xor(data: bytes, key: bytes) -> bytes:
    return bytes(data[i] ^ key[i % len(key)] for i in range(len(data)))


def create_v4_udp_dgram_socket(blocking: bool, bind_addr: tuple[str, int] | None = None) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setblocking(blocking)
    if bind_addr is not None:
        s.bind(bind_addr)
    return s


try:
    with open(os.path.join(os.path.dirname(sys.argv[0]), "config_server.json"), encoding="utf-8-sig") as f:
        config = json.loads(f.read())
except FileNotFoundError:
    print("[error] config_server.json not found. Make sure it exists in the same directory as main_server.py.")
    sys.exit(1)
except json.JSONDecodeError as e:
    print(f"[error] Failed to parse config_server.json: {e}")
    print("[error] Ensure the file is valid JSON and saved with UTF-8 encoding (with or without BOM).")
    sys.exit(1)

info_decryption_pass = hashlib.sha256(config["info_decryption_pass"].encode()).digest()

bridge_port = int(config["bridge_port"])
registration_port = int(config["registration_port"])
h_out_addr = (config["h_out_address"].rsplit(":", 1)[0], int(config["h_out_address"].rsplit(":", 1)[1]))

print(f"[init] Registration port: {registration_port}")
print(f"[init] Bridge port: {bridge_port}")
print(f"[init] VPN server (h_out_address): {h_out_addr}")

active_clients = {}

ip_id = random.randint(0, 65535)

raw_sender_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_UDP)
raw_sender_sock.setblocking(False)
raw_sender_sock.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)
print("[init] Raw socket created for IP-spoofed replies")


async def client_h_recv(client_id: bytes, client_sock: socket.socket, client_send_info: list):
    """Receive responses from the VPN server and send spoofed UDP replies to the client."""
    loop = asyncio.get_running_loop()
    global ip_id
    client_id_hex = client_id.hex()
    print(f"[client_h_recv:{client_id_hex}] Task started")
    while True:
        try:
            data, addr = await asyncio.wait_for(loop.sock_recvfrom(client_sock, 65535), timeout=30)
        except asyncio.TimeoutError:
            print(f"[client_h_recv:{client_id_hex}] Timeout — client inactive, removing")
            client_sock.close()
            active_clients.pop(client_id, None)
            return
        except Exception as e:
            print(f"[client_h_recv:{client_id_hex}] Receive error: {e}")
            client_sock.close()
            active_clients.pop(client_id, None)
            return
        if not data or addr != h_out_addr:
            continue

        c_spoof_src_ip_bytes, c_spoof_src_port, client_ip_bytes, client_open_port, client_ip_str = client_send_info
        udp_payload = build_udp_payload_v4(data, c_spoof_src_port, client_open_port, c_spoof_src_ip_bytes,
                                           client_ip_bytes)
        ip_header = build_ipv4_header(len(udp_payload), c_spoof_src_ip_bytes, client_ip_bytes, UDP_PROTO,
                                      128, ip_id, True)
        ip_id = (ip_id + 1) & 0xFFFF
        try:
            await loop.sock_sendto(raw_sender_sock, ip_header + udp_payload, (client_ip_str, client_open_port))
        except Exception as e:
            print(f"[client_h_recv:{client_id_hex}] Raw socket send error: {e}")
            client_sock.close()
            active_clients.pop(client_id, None)
            return


async def registration_recv():
    """Listen for client registration packets and maintain the active_clients table."""
    loop = asyncio.get_running_loop()
    reg_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", registration_port))
    print(f"[registration_recv] Listening on port {registration_port}")
    while True:
        try:
            raw_data, addr = await loop.sock_recvfrom(reg_sock, 1024)
        except Exception as e:
            print(f"[registration_recv] Receive error: {e}")
            reg_sock.close()
            while True:
                try:
                    reg_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", registration_port))
                    print("[registration_recv] Socket recreated")
                    break
                except Exception as e:
                    print(f"[registration_recv] Socket recreate error: {e}")
                    await asyncio.sleep(1)
            continue

        if len(raw_data) < CLIENT_ID_WIDTH + 12:
            print(f"[registration_recv] Short packet from {addr}, ignoring")
            continue

        client_id = raw_data[:CLIENT_ID_WIDTH]
        info_encrypted = raw_data[CLIENT_ID_WIDTH:CLIENT_ID_WIDTH + 12]
        info_data = bytes_xor(info_encrypted, info_decryption_pass)

        client_ip_bytes = info_data[:4]
        client_open_port = int.from_bytes(info_data[4:6], byteorder="big")
        c_spoof_src_ip_bytes = info_data[6:10]
        c_spoof_src_port = int.from_bytes(info_data[10:12], byteorder="big")
        client_ip_str = socket.inet_ntop(socket.AF_INET, client_ip_bytes)
        spoof_ip_str = socket.inet_ntop(socket.AF_INET, c_spoof_src_ip_bytes)

        new_send_info = [c_spoof_src_ip_bytes, c_spoof_src_port, client_ip_bytes, client_open_port, client_ip_str]

        if client_id in active_clients:
            _, _, existing_send_info = active_clients[client_id]
            existing_send_info[:] = new_send_info
            print(f"[registration_recv] Client {client_id.hex()} re-registered: "
                  f"{client_ip_str}:{client_open_port}, spoof={spoof_ip_str}:{c_spoof_src_port}")
        else:
            client_sock = create_v4_udp_dgram_socket(False, None)
            t = asyncio.create_task(client_h_recv(client_id, client_sock, new_send_info))
            active_clients[client_id] = (t, client_sock, new_send_info)
            print(f"[registration_recv] New client registered: {client_id.hex()} — "
                  f"{client_ip_str}:{client_open_port}, spoof={spoof_ip_str}:{c_spoof_src_port}")


async def bridge_recv():
    """Receive data forwarded by the VLESS server and route it to the correct client's VPN server socket."""
    loop = asyncio.get_running_loop()
    bridge_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", bridge_port))
    print(f"[bridge_recv] Listening on port {bridge_port}")
    while True:
        try:
            raw_data, addr = await loop.sock_recvfrom(bridge_sock, 65535)
        except Exception as e:
            print(f"[bridge_recv] Receive error: {e}")
            bridge_sock.close()
            while True:
                try:
                    bridge_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", bridge_port))
                    print("[bridge_recv] Socket recreated")
                    break
                except Exception as e:
                    print(f"[bridge_recv] Socket recreate error: {e}")
                    await asyncio.sleep(1)
            continue

        if len(raw_data) <= CLIENT_ID_WIDTH:
            print(f"[bridge_recv] Packet too short from {addr}, ignoring")
            continue

        client_id = raw_data[:CLIENT_ID_WIDTH]
        data = raw_data[CLIENT_ID_WIDTH:]

        try:
            _, client_sock, _ = active_clients[client_id]
        except KeyError:
            print(f"[bridge_recv] Unknown client_id {client_id.hex()} from {addr}, ignoring")
            continue

        try:
            await loop.sock_sendto(client_sock, data, h_out_addr)
        except Exception as e:
            print(f"[bridge_recv] Forward to VPN server error for client {client_id.hex()}: {e}")


async def main():
    tasks = [
        asyncio.create_task(registration_recv()),
        asyncio.create_task(bridge_recv()),
    ]
    print("[main] Server started — waiting for clients")
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    print("[main] A task completed unexpectedly, shutting down")


asyncio.run(main())
