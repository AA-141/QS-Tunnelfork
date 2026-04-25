# QS-Tunnel

QS-Tunnel is an asymmetric UDP tunnel for low-bandwidth upload and spoofed UDP download paths.

## New server-first management flow

Use one entrypoint for install and operations:

- `/home/runner/work/QS-Tunnel/QS-Tunnel/scripts/install_server.sh`

This script now handles:
- preflight checks
- install/configure for WireGuard, Xray, and tunnel service
- lifecycle actions (status/start/stop/restart/enable/disable)
- logs/diagnostics
- client artifact export (generic/windows)

## Quick start

```bash
cd /home/runner/work/QS-Tunnel/QS-Tunnel
sudo bash scripts/install_server.sh preflight
sudo bash scripts/install_server.sh install --method all
sudo bash scripts/install_server.sh summary
sudo bash scripts/install_server.sh export --target windows
```

## Interactive mode

Run without args for menu mode:

```bash
sudo bash scripts/install_server.sh
```

## CLI commands

```bash
sudo bash scripts/install_server.sh preflight
sudo bash scripts/install_server.sh summary
sudo bash scripts/install_server.sh install --method wireguard|xray|tunnel|all
sudo bash scripts/install_server.sh configure --method wireguard|xray|tunnel|all
sudo bash scripts/install_server.sh service --method wireguard|xray|tunnel|all --action status|start|stop|restart|enable|disable|logs|diagnose
sudo bash scripts/install_server.sh export --target generic|windows
sudo bash scripts/install_server.sh remove --method wireguard|xray|tunnel|all
sudo bash scripts/install_server.sh reset --method wireguard|xray|tunnel|all --force
```

## Method selection

- **WireGuard**: simplest baseline, best default for most users.
- **Xray**: flexible transport/obfuscation at higher operational complexity.
- **Tunnel service**: managed QS server runtime and diagnostics anchor.

## Artifacts and state

- Runtime state: `/home/runner/work/QS-Tunnel/QS-Tunnel/deploy/services/state.env`
- Last used settings: `/home/runner/work/QS-Tunnel/QS-Tunnel/deploy/services/last_values.env`
- Client exports: `/home/runner/work/QS-Tunnel/QS-Tunnel/deploy/artifacts/<target>/`

## Client/server decoupling

Server-side scripts now export client artifacts only. Client platform specifics are handled separately:

- Windows helper: `/home/runner/work/QS-Tunnel/QS-Tunnel/scripts/windows/setup_client.ps1`
- Windows guide: `/home/runner/work/QS-Tunnel/QS-Tunnel/docs/windows-client.md`

## Method guides

- `/home/runner/work/QS-Tunnel/QS-Tunnel/docs/methods/wireguard.md`
- `/home/runner/work/QS-Tunnel/QS-Tunnel/docs/methods/xray.md`
- `/home/runner/work/QS-Tunnel/QS-Tunnel/docs/methods/tunnel-service.md`
- `/home/runner/work/QS-Tunnel/QS-Tunnel/docs/operations-cheatsheet.md`

## Backward compatibility notes

- Existing `config_server.json` and `config_client.json` formats are kept.
- Existing service names remain (`wg-quick@<iface>`, `xray.service`, `qs-tunnel.service`).
- To avoid accidental key rotation, WireGuard keys are only generated if missing.
