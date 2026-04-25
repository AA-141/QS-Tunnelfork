# Operations cheatsheet

## Core workflow
1. `sudo bash scripts/install_server.sh preflight`
2. `sudo bash scripts/install_server.sh install --method all`
3. `sudo bash scripts/install_server.sh summary`
4. `sudo bash scripts/install_server.sh export --target windows`

## Service management
- `sudo bash scripts/install_server.sh service --method wireguard --action status`
- `sudo bash scripts/install_server.sh service --method xray --action restart`
- `sudo bash scripts/install_server.sh service --method tunnel --action logs`

## Toggle methods on/off
- Enable: `... service --method <wireguard|xray|tunnel> --action enable`
- Disable: `... service --method <wireguard|xray|tunnel> --action disable`

## Cleanup / recovery
- Remove one method: `... remove --method wireguard`
- Reset one method: `... reset --method tunnel --force`
- Refresh dependencies: `... upgrade-self`
