# Windows client setup

## Fast path (recommended)
1. Export artifacts on server:
   - `sudo bash scripts/install_server.sh export --target windows`
2. Copy `deploy/artifacts/windows/` to Windows.
3. Run PowerShell helper:
   - `powershell -ExecutionPolicy Bypass -File .\scripts\windows\setup_client.ps1 -ArtifactDir .\deploy\artifacts\windows`
4. Fill `vless_config` or `xray_bridge_inbound` in `qs_client.json`.
5. Run QS client on Windows:
   - `python main_client.py`

## Manual path
1. Install WireGuard for Windows and Python 3.12+.
2. Import `wireguard_client.conf` in WireGuard UI.
3. Place `qs_client.json` near `main_client.py` and update settings.
4. Start `main_client.py`, then activate the WireGuard tunnel.

## Quick checks
- Validate JSON format of `qs_client.json`.
- Confirm server ports are reachable (`5300/udp`, `5301/udp`, and backend port).
- If traffic fails, run server `summary` and `service --action diagnose`.
