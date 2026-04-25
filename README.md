# QS-Tunnel

QS-Tunnel is an asymmetric UDP tunnel for low-bandwidth upload and spoofed UDP download paths.

## New server-first management flow

Use one entrypoint for install and operations:

- `scripts/install_server.sh`

This script now handles:
- preflight checks
- install/configure for WireGuard, Xray, and tunnel service
- lifecycle actions (status/start/stop/restart/enable/disable)
- logs/diagnostics
- client artifact export (generic/windows)

## Quick start

```bash
cd QS-Tunnel
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

- Runtime state: `deploy/services/state.env`
- Last used settings: `deploy/services/last_values.env`
- Client exports: `deploy/artifacts/<target>/`
  - exported `qs_client.json` defaults `fake_send_ip` to `1.1.1.1`; change it if you need a different stable UDP endpoint

## Client/server decoupling

Server-side scripts now export client artifacts only. Client platform specifics are handled separately:

- Windows helper: `scripts/windows/setup_client.ps1`
- Windows guide: `docs/windows-client.md`

## Method guides

- `docs/methods/wireguard.md`
- `docs/methods/xray.md`
- `docs/methods/tunnel-service.md`
- `docs/operations-cheatsheet.md`

## Backward compatibility notes

- Existing `config_server.json` and `config_client.json` formats are kept.
- Existing service names remain (`wg-quick@<iface>`, `xray.service`, `qs-tunnel.service`).
- To avoid accidental key rotation, WireGuard keys are only generated if missing.
