# WireGuard method

## When to use
- Best default for simplicity and predictable performance.
- Lowest operational complexity for most deployments.

## Tradeoffs
- Requires WireGuard kernel/userspace support on server.
- May be easier to identify than heavily obfuscated transports.

## Dependencies
- `wireguard`, `iptables`, `systemd`

## Install
- `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh install --method wireguard`

## Configure
- `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh configure --method wireguard --wg-iface wg0 --wg-listen-port 51820`

## Common commands
- Status: `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh service --method wireguard --action status`
- Start: `... --action start`
- Stop: `... --action stop`
- Restart: `... --action restart`
- Enable: `... --action enable`
- Disable: `... --action disable`
- Logs: `... --action logs`
- Diagnose: `... --action diagnose`

## Troubleshooting
- Run preflight: `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh preflight`
- Check service: `systemctl status wg-quick@wg0`
- Inspect peer state: `wg show`

## Remove / reset
- Remove: `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh remove --method wireguard`
- Reset (regenerate keys): `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh reset --method wireguard --force`
