# Xray method

## When to use
- Use when transport flexibility or traffic shaping is required.
- Good fit when WireGuard alone is blocked or less reliable.

## Tradeoffs
- More moving parts than WireGuard.
- Package availability can vary across Linux distributions.

## Dependencies
- `xray` or `xray-core`, `systemd`
- Server template path: `/etc/xray/config.jsonc`

## Install
- `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh install --method xray`

## Configure
- `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh configure --method xray`
- Edit `/etc/xray/config.jsonc` with your real listen/port/certs/IDs.

## Common commands
- Status: `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh service --method xray --action status`
- Start/Stop/Restart/Enable/Disable/Logs/Diagnose via same `service` command.

## Troubleshooting
- Validate template values before start.
- Inspect service logs: `journalctl -eu xray.service -n 200 --no-pager`
- Run global summary to detect conflicts: `... install_server.sh summary`

## Remove / reset
- Remove: `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh remove --method xray`
- Reset: `sudo bash /home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh reset --method xray`
