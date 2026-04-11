import asyncio
import random
import socket
import json
import os
import sys
import hashlib
import re

CLIENT_ID_WIDTH = 3


def bytes_xor(data: bytes, key: bytes) -> bytes:
    return bytes(data[i] ^ key[i % len(key)] for i in range(len(data)))


def create_v4_udp_dgram_socket(blocking: bool, bind_addr=None) -> socket.socket:
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setblocking(blocking)
    if bind_addr is not None:
        s.bind(bind_addr)
    return s


with open(os.path.join(os.path.dirname(sys.argv[0]), "config_client.json")) as f:
    config = json.loads(f.read())

info_encryption_pass = hashlib.sha256(config["info_encryption_pass"].encode()).digest()

client_id_bytes = os.urandom(CLIENT_ID_WIDTH)

xray_bridge_addr = (config["xray_bridge_inbound"].rsplit(":", 1)[0],
                    int(config["xray_bridge_inbound"].rsplit(":", 1)[1]))

server_reg_addr = (config["server_registration_address"].rsplit(":", 1)[0],
                   int(config["server_registration_address"].rsplit(":", 1)[1]))

h_inbound_bind_addr = (config["h_in_address"].rsplit(":", 1)[0],
                       int(config["h_in_address"].rsplit(":", 1)[1]))

h_inbound_socket = create_v4_udp_dgram_socket(False, h_inbound_bind_addr)

xray_bridge_socket = create_v4_udp_dgram_socket(False, None)

fake_send_ip = config["fake_send_ip"]
fake_send_port = int(config["fake_send_port"])

wan_main_socket = create_v4_udp_dgram_socket(False, ("0.0.0.0", 0))
wan_main_socket_port = int(wan_main_socket.getsockname()[1])

last_h_addr = None


async def h_recv():
    loop = asyncio.get_running_loop()
    global h_inbound_socket
    global last_h_addr
    while True:
        use_socket = h_inbound_socket
        try:
            raw_data, addr_h = await loop.sock_recvfrom(use_socket, 65535)
        except Exception as e:
            print("h_inbound_socket recv error:", e)
            use_socket.close()
            while True:
                if h_inbound_socket != use_socket:
                    break
                try:
                    h_inbound_socket = create_v4_udp_dgram_socket(False, h_inbound_bind_addr)
                    break
                except Exception as e:
                    print("h_inbound_socket create error:", e)
                    await asyncio.sleep(1)
            continue

        if not raw_data:
            continue

        if last_h_addr != addr_h:
            last_h_addr = addr_h
            print("vpn app address:", addr_h)

        try:
            await loop.sock_sendto(xray_bridge_socket, client_id_bytes + raw_data, xray_bridge_addr)
        except Exception as e:
            print("xray_bridge_socket send error:", e)


async def wan_recv():
    loop = asyncio.get_running_loop()
    global h_inbound_socket
    while True:
        try:
            data, addr_w = await loop.sock_recvfrom(wan_main_socket, 65535)
        except Exception as e:
            print("wan receive socket recv error:", e)
            raise

        if not data:
            continue

        if last_h_addr is None:
            continue

        use_socket = h_inbound_socket
        try:
            await loop.sock_sendto(use_socket, data, last_h_addr)
        except Exception as e:
            print("h_inbound_socket send error:", e)
            use_socket.close()
            while True:
                if h_inbound_socket != use_socket:
                    break
                try:
                    h_inbound_socket = create_v4_udp_dgram_socket(False, h_inbound_bind_addr)
                    break
                except Exception as e:
                    print("h_inbound_socket create error:", e)
                    await asyncio.sleep(1)


async def reg_send(my_public_ip: str):
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
    while True:
        try:
            await loop.sock_sendto(reg_socket, reg_packet, server_reg_addr)
        except Exception as e:
            print("reg_send error:", e)
        await asyncio.sleep(20)


async def nat_keep_alive():
    loop = asyncio.get_running_loop()
    while True:
        try:
            await asyncio.sleep(2)
            data = os.urandom(random.randint(257, 499))
            await loop.sock_sendto(wan_main_socket, data, (fake_send_ip, fake_send_port))
        except Exception as e:
            print("nat puncher send error:", e)
            raise


async def fetch_ip(url: str):
    import aiohttp
    async with aiohttp.ClientSession() as session:
        async with session.get(url) as response:
            response.raise_for_status()
            text = await response.text()
            ip_regex = re.compile(r"\b\d{1,3}(?:\.\d{1,3}){3}\b")
            match = ip_regex.search(text)
            if match:
                return match.group(0)
            raise ValueError(f"No ip address found in {url}")


async def main():
    loop = asyncio.get_running_loop()
    my_public_ip = config["my_public_ip"]
    if my_public_ip == "ezping":
        my_public_ip = await fetch_ip("https://ezping.ir/geoip")
    elif my_public_ip == "ipnumberia":
        my_public_ip = await fetch_ip("https://ipnumberia.com/")
    elif my_public_ip == "ipmyp":
        my_public_ip = await fetch_ip("https://ipmyp.ir/")

    for _ in range(3):
        data = os.urandom(random.randint(257, 499))
        await loop.sock_sendto(wan_main_socket, data, (fake_send_ip, fake_send_port))
        await asyncio.sleep(0.001)

    tasks = [
        asyncio.create_task(h_recv()),
        asyncio.create_task(wan_recv()),
        asyncio.create_task(reg_send(my_public_ip)),
        asyncio.create_task(nat_keep_alive()),
    ]
    print("started...")
    await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)


asyncio.run(main())
