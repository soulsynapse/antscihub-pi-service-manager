#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# antscihub-pi-service-manager installer
# Installs the meta service and bootstraps configured module repos. Safe to re-run.
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

log "User=${REAL_USER} Home=${REAL_HOME} Desktop=${DESKTOP_DIR}"

expand_module_path() {
    local raw_path="$1"
    if [[ "$raw_path" == ~/* ]]; then
        echo "${REAL_HOME}/${raw_path#~/}"
    elif [[ "$raw_path" == "\$HOME"/* ]]; then
        echo "${REAL_HOME}/${raw_path#\$HOME/}"
    else
        echo "$raw_path"
    fi
}

install_modules() {
    if [[ ! -f "${MODULES_FILE}" ]]; then
        warn "No modules file at ${MODULES_FILE}; skipping module bootstrap"
        return
    fi

    log "Bootstrapping modules from ${MODULES_FILE}..."

    while IFS='|' read -r repo_url target_path; do
        # Skip comments and blank lines
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

        mkdir -p "$(dirname "${resolved_target}")"

        if [[ -d "${resolved_target}/.git" ]]; then
            log "Updating module: ${repo_url} -> ${resolved_target}"
            if ! git -C "${resolved_target}" pull --ff-only >/dev/null 2>&1; then
                warn "Failed to update ${resolved_target}; continuing"
            fi
        elif [[ -e "${resolved_target}" ]]; then
            warn "Target exists but is not a git repo, skipping: ${resolved_target}"
        else
            log "Cloning module: ${repo_url} -> ${resolved_target}"
            if ! git clone "${repo_url}" "${resolved_target}" >/dev/null 2>&1; then
                warn "Failed to clone ${repo_url}; continuing"
                continue
            fi
        fi

        if id -u "${REAL_USER}" >/dev/null 2>&1; then
            chown -R "${REAL_USER}:${REAL_USER}" "${resolved_target}" 2>/dev/null || true
        fi
    done < "${MODULES_FILE}"
}

# --- Preflight ----------------------------------------------------------------

if ! command -v fleet-publish &>/dev/null; then
    err "fleet-publish not found. Is fleet-shell installed?"
    exit 1
fi

if ! command -v git &>/dev/null; then
    log "Installing git..."
    apt-get update -qq && apt-get install -y -qq git > /dev/null 2>&1
fi

# Bootstrap configured module repositories before setting up service.
install_modules

# --- Copy files ---------------------------------------------------------------

log "Installing to ${INSTALL_DIR}..."
mkdir -p "${INSTALL_DIR}/config"
mkdir -p "${INSTALL_DIR}/services"
mkdir -p "${MANAGER_REPO_DIR}"

# Copy everything except .git
rsync -a --exclude='.git' --exclude='.gitignore' "${SCRIPT_DIR}/" "${INSTALL_DIR}/"

# Set SERVICES_DIR in config if blank
if grep -q '^SERVICES_DIR=""' "${INSTALL_DIR}/config/meta.conf" 2>/dev/null; then
    sed -i "s|^SERVICES_DIR=\"\"|SERVICES_DIR=\"${DESKTOP_DIR}\"|" "${INSTALL_DIR}/config/meta.conf"
fi

# Set SELF_REPO_DIR in config if blank.
# Prefer the git-backed source path used to run install.sh so self-updates can pull.
if grep -q '^SELF_REPO_DIR=""' "${INSTALL_DIR}/config/meta.conf" 2>/dev/null; then
    SELF_REPO_DIR_DEFAULT="${INSTALL_DIR}"
    if [[ -d "${SCRIPT_DIR}/.git" ]]; then
        SELF_REPO_DIR_DEFAULT="${SCRIPT_DIR}"
    fi
    sed -i "s|^SELF_REPO_DIR=\"\"|SELF_REPO_DIR=\"${SELF_REPO_DIR_DEFAULT}\"|" "${INSTALL_DIR}/config/meta.conf"
fi

chmod +x "${INSTALL_DIR}/services/meta-service.sh"

# --- Disable Wi-Fi power management ------------------------------------------

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

# --- Install systemd unit -----------------------------------------------------

log "Installing systemd service..."
cp "${INSTALL_DIR}/services/antscihub-meta.service" /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now antscihub-meta.service

log "  ✓ antscihub-meta enabled and started"

# --- Report -------------------------------------------------------------------

fleet-publish --topic "fleet/managed-services/$(hostname)/install" \
    --json "{\"event\":\"meta_installed\",\"version\":\"$(git -C "${SCRIPT_DIR}" rev-parse --short HEAD 2>/dev/null || echo unknown)\"}" \
    2>/dev/null || true

# --- Done ---------------------------------------------------------------------

log "============================================"
log " antscihub-pi-service-manager installed!"
log ""
log " Config:  ${INSTALL_DIR}/config/meta.conf"
log " Logs:    journalctl -t antscihub-meta -f"
log " Status:  systemctl status antscihub-meta"
log ""
log " To add a managed service, place a folder"
log " in ${DESKTOP_DIR}/ with an"
log " antscihub.manifest file. See README."
log "============================================"