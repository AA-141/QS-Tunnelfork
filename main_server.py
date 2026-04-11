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


def create_v4_udp_dgram_socket(blocking: bool, bind_addr=None) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setblocking(blocking)
    if bind_addr is not None:
        s.bind(bind_addr)
    return s


with open(os.path.join(os.path.dirname(sys.argv[0]), "config_server.json")) as f:
    config = json.loads(f.read())

info_decryption_pass = hashlib.sha256(config["info_decryption_pass"].encode()).digest()

bridge_port = int(config["bridge_port"])
registration_port = int(config["registration_port"])
h_out_addr = (config["h_out_address"].rsplit(":", 1)[0], int(config["h_out_address"].rsplit(":", 1)[1]))

active_clients = {}

ip_id = random.randint(0, 65535)

raw_sender_sock = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_UDP)
raw_sender_sock.setblocking(False)
raw_sender_sock.setsockopt(socket.IPPROTO_IP, socket.IP_HDRINCL, 1)


async def client_h_recv(client_id: bytes, client_sock: socket.socket, client_send_info: list):
    loop = asyncio.get_running_loop()
    global ip_id
    while True:
        try:
            data, addr = await asyncio.wait_for(loop.sock_recvfrom(client_sock, 65535), timeout=30)
        except asyncio.TimeoutError:
            client_sock.close()
            active_clients.pop(client_id, None)
            return
        except Exception:
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
            print("raw_sock send error:", e)
            client_sock.close()
            active_clients.pop(client_id, None)
            return


async def registration_recv():
    loop = asyncio.get_running_loop()
    reg_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", registration_port))
    while True:
        try:
            raw_data, addr = await loop.sock_recvfrom(reg_sock, 1024)
        except Exception as e:
            print("registration_recv error:", e)
            reg_sock.close()
            while True:
                try:
                    reg_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", registration_port))
                    break
                except Exception as e:
                    print("registration_recv socket create error:", e)
                    await asyncio.sleep(1)
            continue

        if len(raw_data) < CLIENT_ID_WIDTH + 12:
            continue

        client_id = raw_data[:CLIENT_ID_WIDTH]
        info_encrypted = raw_data[CLIENT_ID_WIDTH:CLIENT_ID_WIDTH + 12]
        info_data = bytes_xor(info_encrypted, info_decryption_pass)

        client_ip_bytes = info_data[:4]
        client_open_port = int.from_bytes(info_data[4:6], byteorder="big")
        c_spoof_src_ip_bytes = info_data[6:10]
        c_spoof_src_port = int.from_bytes(info_data[10:12], byteorder="big")
        client_ip_str = socket.inet_ntop(socket.AF_INET, client_ip_bytes)

        new_send_info = [c_spoof_src_ip_bytes, c_spoof_src_port, client_ip_bytes, client_open_port, client_ip_str]

        if client_id in active_clients:
            _, _, existing_send_info = active_clients[client_id]
            for i in range(len(existing_send_info)):
                existing_send_info[i] = new_send_info[i]
        else:
            client_sock = create_v4_udp_dgram_socket(False, None)
            t = asyncio.create_task(client_h_recv(client_id, client_sock, new_send_info))
            active_clients[client_id] = (t, client_sock, new_send_info)
            print(f"new client registered: {client_ip_str}:{client_open_port}")


async def bridge_recv():
    loop = asyncio.get_running_loop()
    bridge_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", bridge_port))
    while True:
        try:
            raw_data, addr = await loop.sock_recvfrom(bridge_sock, 65535)
        except Exception as e:
            print("bridge_recv error:", e)
            bridge_sock.close()
            while True:
                try:
                    bridge_sock = create_v4_udp_dgram_socket(False, ("0.0.0.0", bridge_port))
                    break
                except Exception as e:
                    print("bridge_recv socket create error:", e)
                    await asyncio.sleep(1)
            continue

        if len(raw_data) <= CLIENT_ID_WIDTH:
            continue

        client_id = raw_data[:CLIENT_ID_WIDTH]
        data = raw_data[CLIENT_ID_WIDTH:]

        try:
            _, client_sock, _ = active_clients[client_id]
        except KeyError:
            continue

        try:
            await loop.sock_sendto(client_sock, data, h_out_addr)
        except Exception as e:
            print("bridge_recv forward error:", e)


async def main():
    tasks = [
        asyncio.create_task(registration_recv()),
        asyncio.create_task(bridge_recv()),
    ]
    print("started...")
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)


asyncio.run(main())
