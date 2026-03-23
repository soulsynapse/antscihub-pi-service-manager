#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# antscihub-pi-service-manager installer
# Installs the service manager and bootstraps configured module repos.
# Safe to re-run.
# Usage: sudo bash install.sh
# =============================================================================

INSTALL_DIR="/opt/antscihub-pi-service-manager"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULES_FILE="${SCRIPT_DIR}/config/modules.conf"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[install]${NC} $*"; }
err()  { echo -e "${RED}[install]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "Must run as root: sudo bash install.sh"
    exit 1
fi

REAL_USER="${SUDO_USER:-pi}"
REAL_HOME=$(eval echo "~${REAL_USER}")
DESKTOP_DIR="${REAL_HOME}/Desktop"
MANAGER_REPO_DIR="${DESKTOP_DIR}/2-SERVICE-MANAGER"

MQTT_DIR="${DESKTOP_DIR}/1-MQTT"
VENV_PYTHON="${MQTT_DIR}/venv/bin/python3"

log "User=${REAL_USER} Home=${REAL_HOME} Desktop=${DESKTOP_DIR}"

# ─── Helpers ──────────────────────────────────────────────────────────────────

expand_module_path() {
    local raw_path="$1"
    raw_path="${raw_path//$'\r'/}"
    raw_path="${raw_path#\"}"
    raw_path="${raw_path%\"}"
    raw_path="${raw_path#\'}"
    raw_path="${raw_path%\'}"

    case "$raw_path" in
        '~/'*)
            echo "${REAL_HOME}/${raw_path:2}"
            ;;
        "\$HOME/"*)
            echo "${REAL_HOME}/${raw_path#\$HOME/}"
            ;;
        "\${HOME}/"*)
            echo "${REAL_HOME}/${raw_path#\${HOME}/}"
            ;;
        *)
            echo "$raw_path"
            ;;
    esac
}

run_module_install() {
    local module_dir="$1"

    if [[ ! -f "${module_dir}/antscihub.manifest" ]]; then
        return
    fi

    local install_cmd=""
    while IFS='=' read -r mkey mval; do
        [[ "$mkey" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$mkey" ]] && continue
        mkey=$(echo "$mkey" | xargs)
        mval=$(echo "$mval" | xargs)
        if [[ "$mkey" == "INSTALL_CMD" ]]; then
            install_cmd="$mval"
        fi
    done < "${module_dir}/antscihub.manifest"

    if [[ -n "$install_cmd" ]]; then
        log "Running install for $(basename "${module_dir}"): ${install_cmd}"
        find "${module_dir}" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
        if ! (cd "${module_dir}" && bash -c "$install_cmd"); then
            warn "Install failed for $(basename "${module_dir}")"
        fi
    fi
}

install_modules() {
    if [[ ! -f "${MODULES_FILE}" ]]; then
        warn "No modules file at ${MODULES_FILE}; skipping module bootstrap"
        return
    fi

    log "Bootstrapping modules from ${MODULES_FILE}..."

    while IFS='|' read -r repo_url target_path; do
        [[ -z "${repo_url// /}" ]] && continue
        [[ "${repo_url}" =~ ^[[:space:]]*# ]] && continue

        repo_url="$(echo "${repo_url}" | xargs)"
        target_path="$(echo "${target_path}" | xargs)"

        if [[ -z "$repo_url" || -z "$target_path" ]]; then
            warn "Invalid module line, expected REPO_URL|TARGET_PATH"
            continue
        fi

        local resolved_target
        resolved_target="$(expand_module_path "$target_path")"

        if [[ "$resolved_target" == '~/'* ]]; then
            resolved_target="${REAL_HOME}/${resolved_target:2}"
        fi

        log "Module target resolved: ${target_path} -> ${resolved_target}"

        mkdir -p "$(dirname "${resolved_target}")"

        if [[ -d "${resolved_target}/.git" ]]; then
            log "Updating module: ${repo_url} -> ${resolved_target}"
            if ! git -C "${resolved_target}" pull --ff-only; then
                warn "Failed to update ${resolved_target}; continuing"
            fi
        elif [[ -e "${resolved_target}" ]]; then
            if [[ -d "${resolved_target}" ]] && [[ -z "$(find "${resolved_target}" -mindepth 1 -maxdepth 1 2>/dev/null)" ]]; then
                log "Cloning module into existing empty dir: ${repo_url} -> ${resolved_target}"
                rmdir "${resolved_target}" 2>/dev/null || true
                if ! git clone "${repo_url}" "${resolved_target}"; then
                    warn "Failed to clone ${repo_url} into ${resolved_target}; continuing"
                    continue
                fi
                run_module_install "${resolved_target}"
            else
                warn "Target exists and is not a git repo, skipping: ${resolved_target}"
                warn "If this path should be managed, remove or rename it, then re-run install.sh"
                continue
            fi
        else
            log "Cloning module: ${repo_url} -> ${resolved_target}"
            if ! git clone "${repo_url}" "${resolved_target}"; then
                warn "Failed to clone ${repo_url} into ${resolved_target}; continuing"
                continue
            fi
            run_module_install "${resolved_target}"
        fi

        if id -u "${REAL_USER}" >/dev/null 2>&1; then
            chown -R "${REAL_USER}:${REAL_USER}" "${resolved_target}" 2>/dev/null || true
        fi
    done < "${MODULES_FILE}"
}

# ─── Preflight ────────────────────────────────────────────────────────────────

if [[ ! -d "${MQTT_DIR}" ]]; then
    err "MQTT directory not found at ${MQTT_DIR}"
    err "Is fleet-shell installed? Run the fleet-shell installer first."
    exit 1
fi

if [[ ! -f "${VENV_PYTHON}" ]]; then
    err "Python venv not found at ${VENV_PYTHON}"
    err "Is fleet-shell installed correctly?"
    exit 1
fi

if ! "${VENV_PYTHON}" -c "import paho.mqtt.client; from cryptography.fernet import Fernet" 2>/dev/null; then
    err "MQTT venv missing required packages"
    err "Re-run fleet-shell installer or: ${MQTT_DIR}/venv/bin/pip install paho-mqtt cryptography python-dotenv"
    exit 1
fi

if ! command -v git &>/dev/null; then
    log "Installing git..."
    apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1
fi

# Bootstrap modules before setting up service
install_modules

# ─── Stop old service ─────────────────────────────────────────────────────────

# Stop old meta service if it exists
systemctl stop antscihub-meta 2>/dev/null || true
systemctl disable antscihub-meta 2>/dev/null || true
rm -f /etc/systemd/system/antscihub-meta.service

# Stop service-manager if already running
systemctl stop antscihub-service-manager 2>/dev/null || true

# ─── Copy files ───────────────────────────────────────────────────────────────

log "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/services"
mkdir -p "${MANAGER_REPO_DIR}"

rsync -a --exclude='.git' --exclude='.gitignore' "${SCRIPT_DIR}/" "${INSTALL_DIR}/"

# Remove old meta files if present
rm -f "${INSTALL_DIR}/services/meta-service.sh"
rm -f "${INSTALL_DIR}/services/antscihub-meta.service"
rm -f "${INSTALL_DIR}/config/meta.conf"

chmod +x "${INSTALL_DIR}/services/service-manager.sh"

# Migrate meta.conf → service-manager.conf if needed
if [[ -f "${INSTALL_DIR}/config/meta.conf" && ! -f "${INSTALL_DIR}/config/service-manager.conf" ]]; then
    log "Migrating meta.conf → service-manager.conf"
    mv "${INSTALL_DIR}/config/meta.conf" "${INSTALL_DIR}/config/service-manager.conf"
fi

# Set SERVICES_DIR in config if blank
if grep -q '^SERVICES_DIR=""' "${INSTALL_DIR}/config/service-manager.conf" 2>/dev/null; then
    sed -i "s|^SERVICES_DIR=\"\"|SERVICES_DIR=\"${DESKTOP_DIR}\"|" "${INSTALL_DIR}/config/service-manager.conf"
fi

# Set SELF_REPO_DIR in config if blank
if grep -q '^SELF_REPO_DIR=""' "${INSTALL_DIR}/config/service-manager.conf" 2>/dev/null; then
    SELF_REPO_DIR_DEFAULT="${INSTALL_DIR}"
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        SELF_REPO_DIR_DEFAULT="${SCRIPT_DIR}"
    fi
    sed -i "s|^SELF_REPO_DIR=\"\"|SELF_REPO_DIR=\"${SELF_REPO_DIR_DEFAULT}\"|" "${INSTALL_DIR}/config/service-manager.conf"
fi

# ─── Disable Wi-Fi power management ──────────────────────────────────────────

log "Disabling Wi-Fi power management..."

mkdir -p /etc/NetworkManager/conf.d
cat > /etc/NetworkManager/conf.d/99-antscihub-wifi-powersave.conf <<'EOF'
[connection]
wifi.powersave = 2
EOF

cat > /etc/udev/rules.d/70-antscihub-wifi-powersave.rules <<'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/usr/sbin/iwconfig %k power off"
EOF

ip link show wlan0 &>/dev/null && iwconfig wlan0 power off 2>/dev/null || true

# ─── Install systemd unit ────────────────────────────────────────────────────

log "Installing systemd service..."

cp "${INSTALL_DIR}/services/antscihub-service-manager.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now antscihub-service-manager.service

sleep 3
if systemctl is-active --quiet antscihub-service-manager; then
    log "  ✓ antscihub-service-manager running"
else
    err "  ✗ antscihub-service-manager failed to start"
    journalctl -u antscihub-service-manager --no-pager -n 20 || true
fi

# ─── Report install ──────────────────────────────────────────────────────────

"${VENV_PYTHON}" -c "
import sys, time
sys.path.insert(0, '${MQTT_DIR}')
from mqtt_client import fleet, DEVICE_ID
fleet.loop_start()
if fleet.wait_until_connected(timeout=10):
    fleet.publish('fleet/response/' + DEVICE_ID, {
        'schema': 'fleet.service-manager.v1',
        'event': 'service_manager_installed',
        'device_id': DEVICE_ID,
        'timestamp': time.time(),
        'version': '$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)',
        'install_dir': '${INSTALL_DIR}',
    }, encrypt=True)
    time.sleep(1)
fleet.loop_stop()
" 2>/dev/null || warn "Install report failed (non-critical)"

# ─── Done ─────────────────────────────────────────────────────────────────────

log "============================================"
log " antscihub-pi-service-manager installed!"
log ""
log " Config:  ${INSTALL_DIR}/config/service-manager.conf"
log " Logs:    journalctl -u antscihub-service-manager -f"
log " Status:  systemctl status antscihub-service-manager"
log ""
log " To add a managed service, place a folder"
log " in ${DESKTOP_DIR}/ with an"
log " antscihub.manifest file. See README."
log "============================================"