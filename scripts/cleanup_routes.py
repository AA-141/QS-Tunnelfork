"""cleanup_routes.py — remove Windows host routes left by QS-Tunnel after an ungraceful exit.

Run this as Administrator whenever you Ctrl-C out of main_client.py before it can clean up:

    python scripts/cleanup_routes.py

The script reads config_client.json (same directory as main_client.py), resolves the same set of
server IPs that main_client.py would have routed, and deletes each ``/32`` host route.

It is safe to run even when QS-Tunnel is not running and even if some routes have already been
removed — missing routes are silently ignored.
"""

import json
import os
import socket
import subprocess
import sys
from urllib.parse import urlparse

HOST_ROUTE_MASK = "255.255.255.255"

# Keep in sync with _IP_SVC_URLS in main_client.py
_IP_SVC_URLS: dict[str, str] = {
    "ezping":     "https://ezping.ir/geoip",
    "ipnumberia": "https://ipnumberia.com/",
    "ipmyp":      "https://ipmyp.ir/",
}


def _resolve(host: str) -> str | None:
    try:
        ip = socket.gethostbyname(host)
        return ip
    except OSError as e:
        print(f"[cleanup] WARNING: Could not resolve {host!r}: {e}")
        return None


def _collect_ips(config: dict) -> set[str]:
    """Return the set of IPs that main_client.py would have added host routes for."""
    ips: set[str] = set()

    # Registration server
    reg = config.get("server_registration_address", "")
    if reg:
        host = reg.rsplit(":", 1)[0]
        ip = _resolve(host)
        if ip:
            ips.add(ip)

    # NAT keep-alive / spoofed-source IP (always a literal IP)
    fake_ip = config.get("fake_send_ip", "").strip()
    if fake_ip:
        ips.add(fake_ip)

    # VLESS server (only present when vless_config is set)
    vless_url = config.get("vless_config", "").strip()
    if vless_url:
        parsed = urlparse(vless_url)
        if parsed.hostname:
            ip = _resolve(parsed.hostname)
            if ip:
                ips.add(ip)

    # Public IP detection service
    svc_url = _IP_SVC_URLS.get(config.get("my_public_ip", ""))
    if svc_url:
        svc_host = urlparse(svc_url).hostname or ""
        if svc_host:
            ip = _resolve(svc_host)
            if ip:
                ips.add(ip)

    return ips


def _delete_route(ip: str) -> None:
    result = subprocess.run(
        ["route", "delete", ip, "mask", HOST_ROUTE_MASK],
        capture_output=True, text=True, timeout=5,
    )
    stdout = (result.stdout or "").strip()
    if result.returncode == 0:
        print(f"[cleanup] Route removed: {ip}")
    else:
        # "Element not found." is normal — the route was already gone.
        stderr = (result.stderr or "").strip()
        msg = stdout or stderr or f"exit code {result.returncode}"
        if "not found" in msg.lower() or "element" in msg.lower():
            print(f"[cleanup] Route already absent: {ip}")
        else:
            print(f"[cleanup] WARNING: Could not remove route for {ip}: {msg}")


def main() -> None:
    if sys.platform != "win32":
        print("[cleanup] Nothing to do — host routes are only added on Windows.")
        sys.exit(0)

    config_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "config_client.json")
    config_path = os.path.normpath(config_path)

    if not os.path.exists(config_path):
        print(f"[cleanup] ERROR: config_client.json not found at {config_path}")
        sys.exit(1)

    with open(config_path, encoding="utf-8-sig") as f:
        config = json.load(f)

    ips = _collect_ips(config)
    if not ips:
        print("[cleanup] No IPs to clean up (config may be unconfigured).")
        sys.exit(0)

    print(f"[cleanup] Removing host routes for: {', '.join(sorted(ips))}")
    for ip in sorted(ips):
        _delete_route(ip)

    print("[cleanup] Done.")


if __name__ == "__main__":
    main()
