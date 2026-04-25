# Tunnel service method (QS-Tunnel server)

## When to use
- Required for QS-Tunnel registration/bridge and lifecycle management.
- Use as the managed server component for client uplink/downlink routing.

## Tradeoffs
- Depends on Python runtime and service unit management.
- Requires spoofing-capable VPS/network for expected behavior.

## Dependencies
- `python3`, `python3-venv`, `systemd`
- Repo config: `config_server.json`

## Install
- `sudo bash scripts/install_server.sh install --method tunnel`

## Configure
- `sudo bash scripts/install_server.sh configure --method tunnel --qs-reg-port 5300 --qs-bridge-port 5301 --h-out-address 127.0.0.1:51820`

## Common commands
- Status: `sudo bash scripts/install_server.sh service --method tunnel --action status`
- Start/Stop/Restart/Enable/Disable/Logs/Diagnose via same `service` command.

## Troubleshooting
- Check service: `systemctl status qs-tunnel.service`
- Logs: `journalctl -eu qs-tunnel.service -n 200 --no-pager`
- Validate ports and states: `sudo bash scripts/install_server.sh summary`

## Remove / reset
- Remove: `sudo bash scripts/install_server.sh remove --method tunnel`
- Reset: `sudo bash scripts/install_server.sh reset --method tunnel`
