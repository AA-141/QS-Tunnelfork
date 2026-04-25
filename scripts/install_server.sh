#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEPLOY_DIR="${REPO_DIR}/deploy"
SERVICES_DIR="${DEPLOY_DIR}/services"
ARTIFACTS_DIR="${DEPLOY_DIR}/artifacts"
DOCS_DIR="${REPO_DIR}/docs"
METHOD_DOCS_DIR="${DOCS_DIR}/methods"
WINDOWS_SCRIPTS_DIR="${REPO_DIR}/scripts/windows"
STATE_FILE="${SERVICES_DIR}/state.env"
LAST_VALUES_FILE="${SERVICES_DIR}/last_values.env"

NON_INTERACTIVE=false
DRY_RUN=false
FORCE=false
COMMAND=""
METHOD=""
ACTION=""
TARGET="generic"

DEFAULT_IFACE="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' || true)"
DEFAULT_IFACE="${DEFAULT_IFACE:-eth0}"

WG_IFACE=""
WG_LISTEN_PORT=""
WG_SERVER_CIDR=""
WG_CLIENT_CIDR=""
QS_REG_PORT=""
QS_BRIDGE_PORT=""
QS_SECRET=""
H_OUT_ADDRESS=""
SERVER_PUBLIC_IP=""
XRAY_LISTEN_PORT=""

log() {
  printf '[info] %s\n' "$*"
}

warn() {
  printf '[warn] %s\n' "$*" >&2
}

err() {
  printf '[error] %s\n' "$*" >&2
}

run_cmd() {
  if [[ "${DRY_RUN}" == true ]]; then
    printf '[dry-run] %s\n' "$*"
    return 0
  fi
  eval "$@"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    err "Please run as root: sudo bash ${REPO_DIR}/scripts/install_server.sh"
    exit 1
  fi
}

ensure_dirs() {
  mkdir -p "${SERVICES_DIR}" "${ARTIFACTS_DIR}" "${METHOD_DOCS_DIR}" "${WINDOWS_SCRIPTS_DIR}"
}

set_defaults() {
  WG_IFACE="${WG_IFACE:-wg0}"
  WG_LISTEN_PORT="${WG_LISTEN_PORT:-51820}"
  WG_SERVER_CIDR="${WG_SERVER_CIDR:-10.66.0.1/24}"
  WG_CLIENT_CIDR="${WG_CLIENT_CIDR:-10.66.0.2/32}"
  QS_REG_PORT="${QS_REG_PORT:-5300}"
  QS_BRIDGE_PORT="${QS_BRIDGE_PORT:-5301}"
  XRAY_LISTEN_PORT="${XRAY_LISTEN_PORT:-443}"
  H_OUT_ADDRESS="${H_OUT_ADDRESS:-127.0.0.1:${WG_LISTEN_PORT}}"
}

load_env_file() {
  local file="$1"
  if [[ -f "${file}" ]]; then
    # shellcheck disable=SC1090
    source "${file}"
  fi
}

load_state() {
  load_env_file "${STATE_FILE}"
  load_env_file "${LAST_VALUES_FILE}"
  set_defaults
}

save_state() {
  cat > "${STATE_FILE}" <<STATE
WIREGUARD_INSTALLED=${WIREGUARD_INSTALLED:-false}
WIREGUARD_ENABLED=${WIREGUARD_ENABLED:-false}
XRAY_INSTALLED=${XRAY_INSTALLED:-false}
XRAY_ENABLED=${XRAY_ENABLED:-false}
TUNNEL_INSTALLED=${TUNNEL_INSTALLED:-false}
TUNNEL_ENABLED=${TUNNEL_ENABLED:-false}
LAST_UPDATED_UTC=$(date -u +%Y-%m-%dT%H:%M:%SZ)
STATE
}

save_last_values() {
  cat > "${LAST_VALUES_FILE}" <<LAST
WG_IFACE=${WG_IFACE}
WG_LISTEN_PORT=${WG_LISTEN_PORT}
WG_SERVER_CIDR=${WG_SERVER_CIDR}
WG_CLIENT_CIDR=${WG_CLIENT_CIDR}
QS_REG_PORT=${QS_REG_PORT}
QS_BRIDGE_PORT=${QS_BRIDGE_PORT}
QS_SECRET=${QS_SECRET}
H_OUT_ADDRESS=${H_OUT_ADDRESS}
SERVER_PUBLIC_IP=${SERVER_PUBLIC_IP}
XRAY_LISTEN_PORT=${XRAY_LISTEN_PORT}
LAST
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

get_service_enabled() {
  local unit="$1"
  if systemctl is-enabled "${unit}" >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

get_service_running() {
  local unit="$1"
  if systemctl is-active "${unit}" >/dev/null 2>&1; then
    echo "yes"
  else
    echo "no"
  fi
}

port_in_use() {
  local port="$1"
  ss -lun "( sport = :${port} )" | tail -n +2 | grep -q ":${port}"
}

detect_server_public_ip() {
  local ip
  ip="$(curl -4 -fsSL https://api.ipify.org 2>/dev/null || true)"
  if [[ -n "${ip}" ]]; then
    SERVER_PUBLIC_IP="${ip}"
    return
  fi
  if [[ -z "${SERVER_PUBLIC_IP}" ]]; then
    SERVER_PUBLIC_IP="YOUR_SERVER_IP"
  fi
}

preflight() {
  require_root
  ensure_dirs
  load_state

  log "Running preflight checks..."

  local failed=false
  local required=(bash ip ss systemctl curl python3)
  for c in "${required[@]}"; do
    if ! command_exists "${c}"; then
      err "Missing required command: ${c}"
      failed=true
    fi
  done

  if [[ -f /etc/os-release ]]; then
    local os_id
    os_id="$(grep '^ID=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    case "${os_id}" in
      ubuntu|debian) ;;
      *) warn "OS '${os_id}' is not officially tested. Continue with caution." ;;
    esac
  else
    warn "/etc/os-release not found; OS compatibility cannot be verified"
  fi

  for p in "${WG_LISTEN_PORT}" "${QS_REG_PORT}" "${QS_BRIDGE_PORT}" "${XRAY_LISTEN_PORT}"; do
    if [[ -n "${p}" ]] && port_in_use "${p}"; then
      warn "UDP port ${p} is currently in use"
    fi
  done

  if [[ "${failed}" == true ]]; then
    err "Preflight failed. Install missing dependencies and retry."
    return 1
  fi

  log "Preflight completed successfully."
}

install_python_stack() {
  local venv_dir="${REPO_DIR}/.venv"
  run_cmd "apt-get update"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv iptables curl"
  run_cmd "python3 -m venv '${venv_dir}'"
  run_cmd "'${venv_dir}/bin/pip' install --upgrade pip"
  run_cmd "'${venv_dir}/bin/pip' install -r '${REPO_DIR}/requirements.txt'"
}

write_qs_service() {
  local wg_unit="wg-quick@${WG_IFACE}.service"
  cat > /etc/systemd/system/qs-tunnel.service <<UNIT
[Unit]
Description=QS-Tunnel server
After=network-online.target ${wg_unit}
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
ExecStart=${REPO_DIR}/.venv/bin/python3 ${REPO_DIR}/main_server.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT
  run_cmd "systemctl daemon-reload"
}

wireguard_install() {
  require_root
  ensure_dirs
  load_state
  set_defaults

  log "Installing WireGuard method..."
  run_cmd "apt-get update"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y wireguard iptables"
  run_cmd "modprobe wireguard 2>/dev/null || true"

  run_cmd "install -d -m 700 /etc/wireguard/keys"
  if [[ ! -f /etc/wireguard/keys/server_private.key || ! -f /etc/wireguard/keys/server_public.key ]]; then
    run_cmd "umask 077 && wg genkey | tee /etc/wireguard/keys/server_private.key | wg pubkey > /etc/wireguard/keys/server_public.key"
  fi
  if [[ ! -f /etc/wireguard/keys/client_private.key || ! -f /etc/wireguard/keys/client_public.key ]]; then
    run_cmd "umask 077 && wg genkey | tee /etc/wireguard/keys/client_private.key | wg pubkey > /etc/wireguard/keys/client_public.key"
  fi

  local server_private_key client_public_key
  server_private_key="$(cat /etc/wireguard/keys/server_private.key)"
  client_public_key="$(cat /etc/wireguard/keys/client_public.key)"

  cat > "/etc/wireguard/${WG_IFACE}.conf" <<WGCONF
[Interface]
PrivateKey = ${server_private_key}
Address = ${WG_SERVER_CIDR}
ListenPort = ${WG_LISTEN_PORT}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${DEFAULT_IFACE} -j MASQUERADE

[Peer]
PublicKey = ${client_public_key}
AllowedIPs = ${WG_CLIENT_CIDR}
WGCONF
  chmod 600 "/etc/wireguard/${WG_IFACE}.conf"

  if ! grep -q '^net.ipv4.ip_forward=1$' /etc/sysctl.conf; then
    run_cmd "echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"
  fi
  run_cmd "sysctl -p >/dev/null"

  wireguard_enable
  wireguard_start || true

  WIREGUARD_INSTALLED=true
  save_state
  save_last_values
  log "WireGuard install complete."
}

wireguard_configure() {
  load_state
  set_defaults
  H_OUT_ADDRESS="127.0.0.1:${WG_LISTEN_PORT}"
  save_last_values
  log "WireGuard parameters persisted (iface=${WG_IFACE}, port=${WG_LISTEN_PORT})."
}

wireguard_status() {
  load_state
  local unit="wg-quick@${WG_IFACE}.service"
  cat <<OUT
Method: wireguard
Installed: ${WIREGUARD_INSTALLED:-false}
Enabled: $(get_service_enabled "${unit}")
Running: $(get_service_running "${unit}")
Unit: ${unit}
Port: ${WG_LISTEN_PORT}
Config: /etc/wireguard/${WG_IFACE}.conf
OUT
}

wireguard_start() {
  local unit="wg-quick@${WG_IFACE}.service"
  run_cmd "systemctl reset-failed '${unit}' 2>/dev/null || true"
  run_cmd "systemctl start '${unit}'"
}

wireguard_stop() {
  local unit="wg-quick@${WG_IFACE}.service"
  run_cmd "systemctl stop '${unit}'"
}

wireguard_restart() {
  local unit="wg-quick@${WG_IFACE}.service"
  run_cmd "systemctl restart '${unit}'"
}

wireguard_enable() {
  local unit="wg-quick@${WG_IFACE}.service"
  run_cmd "systemctl enable '${unit}' >/dev/null"
  WIREGUARD_ENABLED=true
  save_state
}

wireguard_disable() {
  local unit="wg-quick@${WG_IFACE}.service"
  run_cmd "systemctl disable '${unit}' >/dev/null"
  WIREGUARD_ENABLED=false
  save_state
}

wireguard_logs() {
  local unit="wg-quick@${WG_IFACE}.service"
  journalctl -eu "${unit}" -n 80 --no-pager || true
}

wireguard_diagnose() {
  local unit="wg-quick@${WG_IFACE}.service"
  log "WireGuard diagnose"
  systemctl status "${unit}" --no-pager || true
  wg show || true
}

wireguard_remove() {
  local unit="wg-quick@${WG_IFACE}.service"
  wireguard_stop || true
  wireguard_disable || true
  run_cmd "rm -f '/etc/wireguard/${WG_IFACE}.conf'"
  WIREGUARD_INSTALLED=false
  save_state
  log "WireGuard removed (keys preserved)."
}

wireguard_reset() {
  if [[ "${FORCE}" != true && "${NON_INTERACTIVE}" != true ]]; then
    read -rp "Reset WireGuard keys and config? [y/N]: " ans
    [[ "${ans}" =~ ^[Yy]$ ]] || return 0
  fi
  wireguard_remove
  run_cmd "rm -f /etc/wireguard/keys/server_private.key /etc/wireguard/keys/server_public.key /etc/wireguard/keys/client_private.key /etc/wireguard/keys/client_public.key"
  wireguard_install
}

xray_install() {
  require_root
  ensure_dirs
  load_state
  log "Installing Xray method..."

  run_cmd "apt-get update"
  if ! run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y xray"; then
    if ! run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y xray-core"; then
      warn "Could not install xray via apt. Install manually, then run configure/status actions."
    fi
  fi

  run_cmd "install -d -m 755 /etc/xray"
  if [[ ! -f /etc/xray/config.jsonc ]]; then
    cp "${REPO_DIR}/examples/xray_core_xhttp_h3/xhttp_h3_server.jsonc" /etc/xray/config.jsonc
  fi

  if command_exists xray && [[ ! -f /etc/systemd/system/xray.service ]]; then
    cat > /etc/systemd/system/xray.service <<UNIT
[Unit]
Description=Xray Service
After=network.target

[Service]
Type=simple
ExecStart=$(command -v xray) run -c /etc/xray/config.jsonc
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT
    run_cmd "systemctl daemon-reload"
  fi

  XRAY_INSTALLED=true
  save_state
  save_last_values
  log "Xray method install complete."
}

xray_configure() {
  load_state
  set_defaults
  run_cmd "install -d -m 755 /etc/xray"
  if [[ -f /etc/xray/config.jsonc ]]; then
    cp /etc/xray/config.jsonc "/etc/xray/config.jsonc.bak.$(date +%s)"
  fi
  cp "${REPO_DIR}/examples/xray_core_xhttp_h3/xhttp_h3_server.jsonc" /etc/xray/config.jsonc
  log "Xray server template refreshed at /etc/xray/config.jsonc"
}

xray_status() {
  load_state
  local unit="xray.service"
  cat <<OUT
Method: xray
Installed: ${XRAY_INSTALLED:-false}
Enabled: $(get_service_enabled "${unit}")
Running: $(get_service_running "${unit}")
Unit: ${unit}
Port: ${XRAY_LISTEN_PORT}
Config: /etc/xray/config.jsonc
OUT
}

xray_start() { run_cmd "systemctl start xray.service"; }
xray_stop() { run_cmd "systemctl stop xray.service"; }
xray_restart() { run_cmd "systemctl restart xray.service"; }

xray_enable() {
  run_cmd "systemctl enable xray.service >/dev/null"
  XRAY_ENABLED=true
  save_state
}

xray_disable() {
  run_cmd "systemctl disable xray.service >/dev/null"
  XRAY_ENABLED=false
  save_state
}

xray_logs() {
  journalctl -eu xray.service -n 80 --no-pager || true
}

xray_diagnose() {
  log "Xray diagnose"
  systemctl status xray.service --no-pager || true
  if command_exists xray; then
    xray version || true
  fi
}

xray_remove() {
  xray_stop || true
  xray_disable || true
  run_cmd "rm -f /etc/xray/config.jsonc"
  XRAY_INSTALLED=false
  save_state
  log "Xray config removed (binary may remain installed)."
}

xray_reset() {
  xray_remove
  xray_install
}

tunnel_install() {
  require_root
  ensure_dirs
  load_state
  set_defaults
  detect_server_public_ip

  log "Installing tunnel service..."
  install_python_stack

  if [[ -z "${QS_SECRET}" ]]; then
    QS_SECRET="$(openssl rand -hex 16)"
  fi

  cat > "${REPO_DIR}/config_server.json" <<CFG
{
  "registration_port": ${QS_REG_PORT},
  "bridge_port": ${QS_BRIDGE_PORT},
  "h_out_address": "${H_OUT_ADDRESS}",
  "info_decryption_pass": "${QS_SECRET}"
}
CFG

  write_qs_service
  tunnel_enable
  tunnel_restart

  if command_exists ufw; then
    run_cmd "ufw allow ${QS_REG_PORT}/udp >/dev/null || true"
    run_cmd "ufw allow ${QS_BRIDGE_PORT}/udp >/dev/null || true"
  fi

  TUNNEL_INSTALLED=true
  save_state
  save_last_values
  log "Tunnel service install complete."
}

tunnel_configure() {
  load_state
  set_defaults
  if [[ -z "${QS_SECRET}" ]]; then
    if [[ -f "${REPO_DIR}/config_server.json" ]]; then
      QS_SECRET="$(REPO_DIR="${REPO_DIR}" python3 - <<'PY'
import json
import os
from pathlib import Path
p=Path(os.environ['REPO_DIR']) / 'config_server.json'
if p.exists():
    try:
        print(json.loads(p.read_text(encoding='utf-8-sig')).get('info_decryption_pass',''))
    except Exception:
        pass
PY
)"
    fi
  fi
  if [[ -z "${QS_SECRET}" ]]; then
    QS_SECRET="$(openssl rand -hex 16)"
  fi
  cat > "${REPO_DIR}/config_server.json" <<CFG
{
  "registration_port": ${QS_REG_PORT},
  "bridge_port": ${QS_BRIDGE_PORT},
  "h_out_address": "${H_OUT_ADDRESS}",
  "info_decryption_pass": "${QS_SECRET}"
}
CFG
  save_last_values
  log "Tunnel config updated at ${REPO_DIR}/config_server.json"
}

tunnel_status() {
  load_state
  local unit="qs-tunnel.service"
  cat <<OUT
Method: tunnel
Installed: ${TUNNEL_INSTALLED:-false}
Enabled: $(get_service_enabled "${unit}")
Running: $(get_service_running "${unit}")
Unit: ${unit}
Ports: registration=${QS_REG_PORT}, bridge=${QS_BRIDGE_PORT}
Config: ${REPO_DIR}/config_server.json
OUT
}

tunnel_start() { run_cmd "systemctl start qs-tunnel.service"; }
tunnel_stop() { run_cmd "systemctl stop qs-tunnel.service"; }
tunnel_restart() { run_cmd "systemctl restart qs-tunnel.service"; }

tunnel_enable() {
  run_cmd "systemctl enable qs-tunnel.service >/dev/null"
  TUNNEL_ENABLED=true
  save_state
}

tunnel_disable() {
  run_cmd "systemctl disable qs-tunnel.service >/dev/null"
  TUNNEL_ENABLED=false
  save_state
}

tunnel_logs() {
  journalctl -eu qs-tunnel.service -n 120 --no-pager || true
}

tunnel_diagnose() {
  log "Tunnel diagnose"
  systemctl status qs-tunnel.service --no-pager || true
  ss -lun | grep -E ":(${QS_REG_PORT}|${QS_BRIDGE_PORT})\\b" || true
}

tunnel_remove() {
  tunnel_stop || true
  tunnel_disable || true
  run_cmd "rm -f /etc/systemd/system/qs-tunnel.service"
  run_cmd "systemctl daemon-reload"
  TUNNEL_INSTALLED=false
  save_state
  log "Tunnel service unit removed."
}

tunnel_reset() {
  tunnel_remove
  tunnel_install
}

export_artifacts() {
  require_root
  ensure_dirs
  load_state
  detect_server_public_ip

  local out_dir="${ARTIFACTS_DIR}/${TARGET}"
  run_cmd "mkdir -p '${out_dir}'"

  if [[ -f /etc/wireguard/keys/client_private.key && -f /etc/wireguard/keys/server_public.key ]]; then
    cat > "${out_dir}/wireguard_client.conf" <<WGCLIENT
[Interface]
PrivateKey = $(cat /etc/wireguard/keys/client_private.key)
Address = ${WG_CLIENT_CIDR}
DNS = 1.1.1.1

[Peer]
PublicKey = $(cat /etc/wireguard/keys/server_public.key)
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 127.0.0.1:10443
WGCLIENT
  fi

  if [[ -z "${QS_SECRET}" && -f "${REPO_DIR}/config_server.json" ]]; then
    QS_SECRET="$(REPO_DIR="${REPO_DIR}" python3 - <<'PY'
import json
import os
from pathlib import Path
p=Path(os.environ['REPO_DIR']) / 'config_server.json'
if p.exists():
    d=json.loads(p.read_text(encoding='utf-8-sig'))
    print(d.get('info_decryption_pass',''))
PY
)"
  fi

  cat > "${out_dir}/qs_client.json" <<QSCFG
{
  "server_registration_address": "${SERVER_PUBLIC_IP}:${QS_REG_PORT}",
  "vless_config": "",
  "bridge_address": "${SERVER_PUBLIC_IP}:${QS_BRIDGE_PORT}",
  "xray_bridge_inbound": "",
  "h_in_address": "127.0.0.1:10443",
  "fake_send_ip": "1.1.1.1",
  "fake_send_port": 443,
  "my_public_ip": "ezping",
  "info_encryption_pass": "${QS_SECRET}"
}
QSCFG

  cp "${REPO_DIR}/examples/xray_core_xhttp_h3/xhttp_h3_client.jsonc" "${out_dir}/xray_client_xhttp_h3.jsonc"
  cp "${REPO_DIR}/examples/xray_core_hysteria/hysteria_client.jsonc" "${out_dir}/xray_client_hysteria.jsonc"

  cat > "${out_dir}/metadata.txt" <<META
Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
Target: ${TARGET}
Server IP: ${SERVER_PUBLIC_IP}
Methods: wireguard,xray,tunnel
Files:
- wireguard_client.conf (if keys exist)
- qs_client.json
- xray_client_xhttp_h3.jsonc
- xray_client_hysteria.jsonc
META

  log "Artifacts exported to ${out_dir}"
}

upgrade_self() {
  require_root
  run_cmd "apt-get update"
  run_cmd "DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-venv wireguard iptables curl"
  log "Core dependencies upgraded."
}

summary() {
  load_state
  detect_server_public_ip
  set_defaults

  cat <<SUM
===== QS-Tunnel Server Summary =====
Server public IP: ${SERVER_PUBLIC_IP}
Repo: ${REPO_DIR}
State file: ${STATE_FILE}

[wireguard]
  installed: ${WIREGUARD_INSTALLED:-false}
  enabled: $(get_service_enabled "wg-quick@${WG_IFACE}.service")
  running: $(get_service_running "wg-quick@${WG_IFACE}.service")
  unit: wg-quick@${WG_IFACE}.service
  port: ${WG_LISTEN_PORT}/udp
  config: /etc/wireguard/${WG_IFACE}.conf

[xray]
  installed: ${XRAY_INSTALLED:-false}
  enabled: $(get_service_enabled "xray.service")
  running: $(get_service_running "xray.service")
  unit: xray.service
  port: ${XRAY_LISTEN_PORT}/udp (template default)
  config: /etc/xray/config.jsonc

[tunnel]
  installed: ${TUNNEL_INSTALLED:-false}
  enabled: $(get_service_enabled "qs-tunnel.service")
  running: $(get_service_running "qs-tunnel.service")
  unit: qs-tunnel.service
  ports: registration=${QS_REG_PORT}/udp bridge=${QS_BRIDGE_PORT}/udp
  config: ${REPO_DIR}/config_server.json
SUM

  if port_in_use "${WG_LISTEN_PORT}"; then warn "Port conflict check: WG port ${WG_LISTEN_PORT} is in use"; fi
  if port_in_use "${QS_REG_PORT}"; then warn "Port conflict check: registration port ${QS_REG_PORT} is in use"; fi
  if port_in_use "${QS_BRIDGE_PORT}"; then warn "Port conflict check: bridge port ${QS_BRIDGE_PORT} is in use"; fi
  if port_in_use "${XRAY_LISTEN_PORT}"; then warn "Port conflict check: xray port ${XRAY_LISTEN_PORT} is in use"; fi
}

prompt_default() {
  local var_name="$1"
  local prompt="$2"
  local default="$3"
  local input
  if [[ "${NON_INTERACTIVE}" == true ]]; then
    printf -v "${var_name}" '%s' "${default}"
    return
  fi
  read -rp "${prompt} [${default}]: " input
  input="${input:-${default}}"
  printf -v "${var_name}" '%s' "${input}"
}

configure_prompts() {
  load_state
  set_defaults
  prompt_default WG_IFACE "WireGuard interface name" "${WG_IFACE}"
  prompt_default WG_LISTEN_PORT "WireGuard listen port" "${WG_LISTEN_PORT}"
  prompt_default WG_SERVER_CIDR "Server WireGuard CIDR" "${WG_SERVER_CIDR}"
  prompt_default WG_CLIENT_CIDR "Client WireGuard CIDR" "${WG_CLIENT_CIDR}"
  prompt_default QS_REG_PORT "QS registration UDP port" "${QS_REG_PORT}"
  prompt_default QS_BRIDGE_PORT "QS bridge UDP port" "${QS_BRIDGE_PORT}"
  prompt_default XRAY_LISTEN_PORT "Xray listen port (template)" "${XRAY_LISTEN_PORT}"
  prompt_default H_OUT_ADDRESS "QS h_out_address" "127.0.0.1:${WG_LISTEN_PORT}"
  if [[ -z "${QS_SECRET}" ]]; then
    QS_SECRET="$(openssl rand -hex 16)"
  fi
  save_last_values
}

apply_method_command() {
  local method="$1"
  local action="$2"
  case "${method}" in
    wireguard) "wireguard_${action}" ;;
    xray) "xray_${action}" ;;
    tunnel) "tunnel_${action}" ;;
    *) err "Unknown method '${method}'"; return 1 ;;
  esac
}

install_methods() {
  local methods
  if [[ "${METHOD}" == "all" || -z "${METHOD}" ]]; then
    methods=(wireguard xray tunnel)
  else
    methods=("${METHOD}")
  fi
  for m in "${methods[@]}"; do
    apply_method_command "${m}" install
  done
}

configure_methods() {
  local methods
  if [[ "${METHOD}" == "all" || -z "${METHOD}" ]]; then
    methods=(wireguard xray tunnel)
  else
    methods=("${METHOD}")
  fi
  for m in "${methods[@]}"; do
    apply_method_command "${m}" configure
  done
}

service_methods() {
  local methods
  if [[ -z "${ACTION}" ]]; then
    err "Missing --action for service command"
    return 1
  fi
  if [[ "${METHOD}" == "all" || -z "${METHOD}" ]]; then
    methods=(wireguard xray tunnel)
  else
    methods=("${METHOD}")
  fi
  for m in "${methods[@]}"; do
    apply_method_command "${m}" "${ACTION}"
  done
}

remove_methods() {
  local methods
  if [[ "${METHOD}" == "all" || -z "${METHOD}" ]]; then
    methods=(wireguard xray tunnel)
  else
    methods=("${METHOD}")
  fi
  for m in "${methods[@]}"; do
    apply_method_command "${m}" remove
  done
}

reset_methods() {
  local methods
  if [[ "${METHOD}" == "all" || -z "${METHOD}" ]]; then
    methods=(wireguard xray tunnel)
  else
    methods=("${METHOD}")
  fi
  for m in "${methods[@]}"; do
    apply_method_command "${m}" reset
  done
}

print_help() {
  cat <<HELP
Usage: sudo bash scripts/install_server.sh <command> [options]

Commands:
  preflight
  summary
  install --method wireguard|xray|tunnel|all
  configure --method wireguard|xray|tunnel|all
  service --method wireguard|xray|tunnel|all --action status|start|stop|restart|enable|disable|logs|diagnose
  export --target generic|windows
  remove --method wireguard|xray|tunnel|all
  reset --method wireguard|xray|tunnel|all
  upgrade-self

Options:
  --non-interactive
  --dry-run
  --force
  --method <value>
  --action <value>
  --target <value>
  --wg-iface <value>
  --wg-listen-port <value>
  --wg-server-cidr <value>
  --wg-client-cidr <value>
  --qs-reg-port <value>
  --qs-bridge-port <value>
  --qs-secret <value>
  --h-out-address <value>
  --server-public-ip <value>
  --xray-listen-port <value>
HELP
}

interactive_menu() {
  configure_prompts

  while true; do
    cat <<MENU

QS-Tunnel unified server manager
1) Preflight checks
2) Summary
3) Install all methods
4) Configure all methods
5) Service action (choose method)
6) Export client artifacts
7) Remove method
8) Reset method
9) Upgrade core dependencies
0) Exit
MENU
    read -rp "Select an option: " choice
    case "${choice}" in
      1) preflight ;;
      2) summary ;;
      3) METHOD=all; install_methods ;;
      4) METHOD=all; configure_methods ;;
      5)
        read -rp "Method (wireguard/xray/tunnel/all): " METHOD
        read -rp "Action (status/start/stop/restart/enable/disable/logs/diagnose): " ACTION
        service_methods
        ;;
      6)
        read -rp "Target (generic/windows): " TARGET
        TARGET="${TARGET:-generic}"
        export_artifacts
        ;;
      7)
        read -rp "Method to remove (wireguard/xray/tunnel/all): " METHOD
        remove_methods
        ;;
      8)
        read -rp "Method to reset (wireguard/xray/tunnel/all): " METHOD
        reset_methods
        ;;
      9) upgrade_self ;;
      0) break ;;
      *) warn "Invalid selection" ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      preflight|summary|install|configure|service|export|remove|reset|upgrade-self|help|-h|--help)
        if [[ -z "${COMMAND}" ]]; then
          COMMAND="$1"
        else
          err "Multiple commands provided"
          exit 1
        fi
        shift
        ;;
      --method)
        METHOD="$2"
        shift 2
        ;;
      --action)
        ACTION="$2"
        shift 2
        ;;
      --target)
        TARGET="$2"
        shift 2
        ;;
      --non-interactive)
        NON_INTERACTIVE=true
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --force)
        FORCE=true
        shift
        ;;
      --wg-iface)
        WG_IFACE="$2"
        shift 2
        ;;
      --wg-listen-port)
        WG_LISTEN_PORT="$2"
        shift 2
        ;;
      --wg-server-cidr)
        WG_SERVER_CIDR="$2"
        shift 2
        ;;
      --wg-client-cidr)
        WG_CLIENT_CIDR="$2"
        shift 2
        ;;
      --qs-reg-port)
        QS_REG_PORT="$2"
        shift 2
        ;;
      --qs-bridge-port)
        QS_BRIDGE_PORT="$2"
        shift 2
        ;;
      --qs-secret)
        QS_SECRET="$2"
        shift 2
        ;;
      --h-out-address)
        H_OUT_ADDRESS="$2"
        shift 2
        ;;
      --server-public-ip)
        SERVER_PUBLIC_IP="$2"
        shift 2
        ;;
      --xray-listen-port)
        XRAY_LISTEN_PORT="$2"
        shift 2
        ;;
      *)
        err "Unknown argument: $1"
        exit 1
        ;;
    esac
  done
}

main() {
  ensure_dirs
  load_state
  parse_args "$@"
  set_defaults

  if [[ -z "${COMMAND}" ]]; then
    interactive_menu
    return
  fi

  case "${COMMAND}" in
    preflight) preflight ;;
    summary) summary ;;
    install) preflight && install_methods ;;
    configure) configure_methods ;;
    service) service_methods ;;
    export) export_artifacts ;;
    remove) remove_methods ;;
    reset) reset_methods ;;
    upgrade-self) upgrade_self ;;
    help|-h|--help) print_help ;;
    *) err "Unknown command: ${COMMAND}"; print_help; exit 1 ;;
  esac
}

main "$@"
