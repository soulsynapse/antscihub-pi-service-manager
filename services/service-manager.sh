#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# antscihub-pi-service-manager  —  main daemon script
# ---------------------------------------------------------------------------
set -uo pipefail
# NOTE: intentionally no -e; this is a long-running daemon that must not exit
# on transient failures.  Every command that can fail is guarded explicitly.

CONF="/opt/antscihub-pi-service-manager/config/service-manager.conf"
LOG_TAG="antscihub-service-manager"

if [[ ! -f "$CONF" ]]; then
    logger -t "$LOG_TAG" "FATAL: config not found at ${CONF}"
    exit 1
fi
source "$CONF"

DEVICE_ID="${DEVICE_ID:-$(hostname)}"

# Resolve SERVICES_DIR dynamically if not set in config
if [[ -z "${SERVICES_DIR:-}" ]]; then
    # FIX #10/#11: use getent to resolve home safely, no eval
    REAL_USER=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
    REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
    SERVICES_DIR="${REAL_HOME}/Desktop"
    logger -t "$LOG_TAG" "SERVICES_DIR not set, resolved to ${SERVICES_DIR}"
fi

# Resolve SELF_REPO_DIR dynamically if not set in config
if [[ -z "${SELF_REPO_DIR:-}" ]]; then
    SELF_REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    logger -t "$LOG_TAG" "SELF_REPO_DIR not set, resolved to ${SELF_REPO_DIR}"
fi
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-3}"
MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-5}"
PULL_ON_BOOT="${PULL_ON_BOOT:-true}"

readonly SERVICE_NONE="none"

find_mqtt_dir() {
    for candidate in \
        "/home/*/Desktop/1-MQTT" \
        "/home/*/1-MQTT"; do
        for dir in $candidate; do
            if [[ -f "${dir}/mqtt_client.py" && -f "${dir}/venv/bin/python3" ]]; then
                echo "$dir"
                return 0
            fi
        done
    done
    return 1
}

MQTT_DIR=$(find_mqtt_dir) || {
    logger -t "$LOG_TAG" "FATAL: Cannot find MQTT directory"
    exit 1
}

VENV_PYTHON="${MQTT_DIR}/venv/bin/python3"
MQTT_HELPER="/opt/antscihub-pi-service-manager/services/mqtt_helper.py"

logger -t "$LOG_TAG" "MQTT_DIR=${MQTT_DIR}"

# --- Systemd notify -----------------------------------------------------------

notify_ready() {
    systemd-notify --ready 2>/dev/null || true
}

notify_watchdog() {
    systemd-notify WATCHDOG=1 2>/dev/null || true
}

# --- Wait for network ---------------------------------------------------------

logger -t "$LOG_TAG" "Waiting for network..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        logger -t "$LOG_TAG" "Network up after ${i}s"
        break
    fi
    sleep 1
done

notify_ready
logger -t "$LOG_TAG" "Notified systemd: ready"

# --- Start persistent MQTT connection -----------------------------------------
# FIX #1: Don't pipe coproc stdout into logger — that consumes the FDs and
#         makes $! point at logger instead of the Python process.
#         Instead, redirect only stderr to logger via process substitution,
#         and keep stdin/stdout connected to the coproc FDs.

logger -t "$LOG_TAG" "Starting MQTT helper..."
coproc MQTT { "$VENV_PYTHON" "$MQTT_HELPER" 2> >(logger -t "$LOG_TAG"); }
MQTT_FD=${MQTT[1]}
MQTT_PID=${MQTT_PID}   # bash automatically sets MQTT_PID for the coproc

sleep 3

if ! kill -0 "$MQTT_PID" 2>/dev/null; then
    logger -t "$LOG_TAG" "FATAL: MQTT helper failed to start"
    exit 1
fi

logger -t "$LOG_TAG" "MQTT helper running (pid ${MQTT_PID})"

cleanup() {
    kill "$MQTT_PID" 2>/dev/null || true
    wait "$MQTT_PID" 2>/dev/null || true
}
trap cleanup EXIT

# --- Helpers ------------------------------------------------------------------

fix_permissions() {
    local dir="$1"
    find "$dir" -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
}

clean_repo() {
    local dir="$1"
    git -C "$dir" checkout -- . 2>/dev/null || true
}

pull_repo() {
    local dir="$1"
    clean_repo "$dir"
    if git -C "$dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
        fix_permissions "$dir"
        return 0
    fi
    logger -t "$LOG_TAG" "Pull failed for ${dir}, resetting and retrying"
    git -C "$dir" reset --hard HEAD 2>/dev/null || true
    git -C "$dir" clean -fd 2>/dev/null || true
    if git -C "$dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
        fix_permissions "$dir"
        return 0
    fi
    return 1
}

mqtt_send() {
    echo "$1" >&"$MQTT_FD" 2>/dev/null || logger -t "$LOG_TAG" "WARN: mqtt_send failed"
}

report() {
    local event="$1"
    shift
    local extra_json="$1"
    local timestamp
    timestamp=$(date +%s.%3N)

    logger -t "$LOG_TAG" "${event}: ${extra_json}"
    mqtt_send "{\"schema\":\"fleet.service-manager.v1\",\"event\":\"${event}\",\"device_id\":\"${DEVICE_ID}\",\"timestamp\":${timestamp},${extra_json}}"
}

report_status() {
    local json_payload="$1"
    report "status" "${json_payload}"
}

array_to_json() {
    # FIX #8: accept the array name but guard against empty / missing
    local arr_name="$1"
    local -n _arr_ref="$arr_name" 2>/dev/null || { echo "[]"; return; }
    if [[ ${#_arr_ref[@]} -eq 0 ]]; then
        echo "[]"
        return
    fi
    local json_array
    json_array=$(printf '"%s",' "${_arr_ref[@]}")
    echo "[${json_array%,}]"
}

parse_manifest() {
    local manifest_path="$1"
    local -n _out="$2"

    _out=()
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        _out["$key"]="$value"
    done < "$manifest_path"
}

# FIX #3: discover_services now uses null-delimited output so paths with
#         spaces are handled correctly.
discover_services() {
    find "${SERVICES_DIR}" -name "antscihub.manifest" -type f -print0 2>/dev/null \
        | while IFS= read -r -d '' manifest; do
            printf '%s\0' "$(dirname "$manifest")/"
        done
}

# FIX #5: capture the real exit code of the install command via PIPESTATUS
run_install() {
    local dir="$1"
    local install_cmd="$2"
    local folder_name="$3"
    local svc="$4"
    local reason="${5:-update}"

    fix_permissions "$dir"
    logger -t "$LOG_TAG" "Running install for ${folder_name}: ${install_cmd}"
    notify_watchdog

    (cd "$dir" && bash -c "$install_cmd") 2>&1 | logger -t "$LOG_TAG"
    local exit_code=${PIPESTATUS[0]}

    if [[ "$exit_code" -eq 0 ]]; then
        report "service_install_done" "\"success\":true,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"reason\":\"${reason}\""
        if [[ -n "$svc" && "$svc" != "$SERVICE_NONE" ]]; then
            systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG" || true
        fi
        return 0
    else
        report "service_install_done" "\"success\":false,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"exit_code\":${exit_code}"
        return 1
    fi
}

# --- Clone missing modules from modules.conf ---------------------------------

clone_missing_modules() {
    local modules_conf="${SELF_REPO_DIR}/config/modules.conf"

    if [[ ! -f "$modules_conf" ]]; then
        logger -t "$LOG_TAG" "No modules.conf found at ${modules_conf}"
        return
    fi

    # FIX #11: resolve home safely via getent, no eval
    local real_user real_home
    real_user=$(getent passwd | awk -F: '$3 >= 1000 && $3 < 60000 {print $1; exit}')
    real_home=$(getent passwd "$real_user" | cut -d: -f6)

    logger -t "$LOG_TAG" "Checking modules.conf for new repos..."

    while IFS='|' read -r repo_url target_path; do
        [[ "$repo_url" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${repo_url// /}" ]] && continue

        repo_url=$(echo "$repo_url" | xargs)
        target_path=$(echo "$target_path" | xargs)
        [[ -z "$target_path" ]] && continue

        # Expand ~ and $HOME
        case "$target_path" in
            '~/'*)
                target_path="${real_home}/${target_path:2}"
                ;;
            "\$HOME/"*)
                target_path="${real_home}/${target_path#\$HOME/}"
                ;;
            "\${HOME}/"*)
                target_path="${real_home}/${target_path#\${HOME}/}"
                ;;
        esac

        # Already cloned?
        if [[ -d "${target_path}/.git" ]]; then
            continue
        fi

        logger -t "$LOG_TAG" "New module: cloning ${repo_url} → ${target_path}"
        notify_watchdog

        mkdir -p "$(dirname "$target_path")"

        if git clone "$repo_url" "$target_path" 2>&1 | logger -t "$LOG_TAG"; then
            report "module_cloned" "\"success\":true,\"repo\":\"${repo_url}\",\"path\":\"${target_path}\""
            fix_permissions "$target_path"

            # Fix ownership
            if id -u "${real_user}" >/dev/null 2>&1; then
                chown -R "${real_user}:${real_user}" "${target_path}" 2>/dev/null || true
            fi

            # Run install if manifest exists
            if [[ -f "${target_path}/antscihub.manifest" ]]; then
                # FIX #4: unset before re-declaring
                unset new_manifest
                local -A new_manifest
                parse_manifest "${target_path}/antscihub.manifest" new_manifest

                local install_cmd="${new_manifest[INSTALL_CMD]:-}"
                local svc="${new_manifest[SERVICE_NAME]:-}"
                local folder_name
                folder_name=$(basename "$target_path")

                if [[ -n "$install_cmd" && "$install_cmd" != "$SERVICE_NONE" ]]; then
                    run_install "$target_path" "$install_cmd" "$folder_name" "$svc" "first_install"
                fi
            fi
        else
            report "module_cloned" "\"success\":false,\"repo\":\"${repo_url}\",\"path\":\"${target_path}\""
        fi

    done < "$modules_conf"
}

# --- State tracking -----------------------------------------------------------

declare -A FAIL_COUNTS
declare -A RESTART_ATTEMPTS
declare -A GAVE_UP

# --- Boot phase ---------------------------------------------------------------

boot_update() {
    if [[ "$PULL_ON_BOOT" != "true" ]]; then
        logger -t "$LOG_TAG" "PULL_ON_BOOT disabled, skipping"
        return
    fi

    notify_watchdog
    logger -t "$LOG_TAG" "Boot phase: pulling repos..."
    report "boot_update_start" "\"services_dir\":\"${SERVICES_DIR}\""

    # Self-update
    local self_dir="${SELF_REPO_DIR:-/opt/antscihub-pi-service-manager}"
    if [[ -d "${self_dir}/.git" ]]; then
        local old_head new_head
        old_head=$(git -C "$self_dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        notify_watchdog
        if pull_repo "$self_dir"; then
            new_head=$(git -C "$self_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
            if [[ "$old_head" != "$new_head" ]]; then
                report "self_update_done" "\"success\":true,\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\",\"source\":\"${self_dir}\""
                logger -t "$LOG_TAG" "Self-updated, re-running install.sh..."
                bash "${self_dir}/install.sh" 2>&1 | logger -t "$LOG_TAG"
                report "self_reinstalled" "\"head\":\"${new_head:0:8}\""
                # FIX #7: cleanup trap will fire on exit and properly kill MQTT_PID
                sleep 2
                exit 0
            fi
        else
            report "self_update_done" "\"success\":false,\"error\":\"git pull failed\",\"dir\":\"${self_dir}\""
        fi
    else
        logger -t "$LOG_TAG" "Self-update repo not found at ${self_dir}; skipping"
    fi

    # Clone any new modules from modules.conf
    clone_missing_modules

    # FIX #3: read null-delimited service directories
    while IFS= read -r -d '' dir; do
        notify_watchdog

        # FIX #4: unset before re-declaring to avoid stale keys
        unset manifest
        local -A manifest
        # FIX #6: use explicit / separator (double slash is harmless)
        parse_manifest "${dir}/antscihub.manifest" manifest

        local svc="${manifest[SERVICE_NAME]:-}"
        local remote="${manifest[GIT_REMOTE]:-}"
        local install_cmd="${manifest[INSTALL_CMD]:-}"
        local folder_name
        folder_name=$(basename "$dir")

        if [[ -z "$remote" ]]; then
            logger -t "$LOG_TAG" "No GIT_REMOTE in ${folder_name}, skipping"
            continue
        fi

        if [[ ! -d "${dir}/.git" ]]; then
            logger -t "$LOG_TAG" "${folder_name} not a git repo, skipping"
            continue
        fi
            local old_head new_head
        old_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        notify_watchdog
        if pull_repo "$dir"; then
            new_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

            if [[ "$old_head" != "$new_head" ]]; then
                report "service_update_done" "\"success\":true,\"service\":\"${folder_name}\",\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\""

                if [[ -n "$install_cmd" && "$install_cmd" != "$SERVICE_NONE" ]]; then
                    run_install "$dir" "$install_cmd" "$folder_name" "$svc" "update"
                fi
            else
                logger -t "$LOG_TAG" "${folder_name}: up to date (${old_head:0:8})"

                if [[ -n "$svc" && "$svc" != "$SERVICE_NONE" ]] && ! systemctl cat "$svc" &>/dev/null; then
                    logger -t "$LOG_TAG" "${folder_name}: service not installed, running install"
                    if [[ -n "$install_cmd" && "$install_cmd" != "$SERVICE_NONE" ]]; then
                        run_install "$dir" "$install_cmd" "$folder_name" "$svc" "first_install"
                    fi
                fi
            fi
        else
            report "service_update_done" "\"success\":false,\"error\":\"git pull failed\",\"service\":\"${folder_name}\",\"remote\":\"${remote}\""
        fi
    done < <(discover_services)

    report "boot_update_done" "\"status\":\"complete\""
}

# --- Health check loop --------------------------------------------------------

check_services() {
    local managed=()
    local healthy=()
    local unhealthy=()

    # FIX #3: read null-delimited service directories
    while IFS= read -r -d '' dir; do
        # FIX #4: unset before re-declaring to avoid stale keys
        unset manifest
        local -A manifest
        # FIX #6: use explicit / separator
        parse_manifest "${dir}/antscihub.manifest" manifest

        local svc="${manifest[SERVICE_NAME]:-}"
        local no_restart="${manifest[NO_AUTO_RESTART]:-false}"
        local grace="${manifest[STARTUP_GRACE]:-10}"
        local folder_name
        folder_name=$(basename "$dir")

        if [[ -z "$svc" || "$svc" == "$SERVICE_NONE" ]]; then
            continue
        fi

        managed+=("$svc")

        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            healthy+=("$svc")
            FAIL_COUNTS["$svc"]=0
            RESTART_ATTEMPTS["$svc"]=0
            GAVE_UP["$svc"]=0
            continue
        fi

        local fails=${FAIL_COUNTS["$svc"]:-0}
        fails=$((fails + 1))
        FAIL_COUNTS["$svc"]=$fails

        if [[ "${GAVE_UP["$svc"]:-0}" == "1" ]]; then
            unhealthy+=("$svc")
            continue
        fi

        if [[ "$no_restart" == "true" ]]; then
            report "service_down" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"auto_restart\":false,\"consecutive_failures\":${fails}"
            unhealthy+=("$svc")
            continue
        fi

        if [[ "$fails" -ge "$RESTART_THRESHOLD" ]]; then
            local attempts=${RESTART_ATTEMPTS["$svc"]:-0}
            attempts=$((attempts + 1))
            RESTART_ATTEMPTS["$svc"]=$attempts

            if [[ "$attempts" -gt "$MAX_RESTART_ATTEMPTS" ]]; then
                GAVE_UP["$svc"]=1
                report "service_gave_up" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"restart_attempts\":${attempts}"
                unhealthy+=("$svc")
                continue
            fi

            report "service_restart" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"reason\":\"consecutive failures: ${fails}\",\"attempt\":${attempts}"

            if systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG"; then
                FAIL_COUNTS["$svc"]=0
                sleep "$grace"

                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    report "service_recovered" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                    RESTART_ATTEMPTS["$svc"]=0
                    healthy+=("$svc")
                    continue
                else
                    report "service_restart_failed" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                    unhealthy+=("$svc")
                fi
            else
                report "service_restart_error" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                unhealthy+=("$svc")
            fi
        else
            logger -t "$LOG_TAG" "${svc} not active (failure ${fails}/${RESTART_THRESHOLD})"
            unhealthy+=("$svc")
        fi
    done < <(discover_services)

    local managed_json
    local healthy_json
    local unhealthy_json

    managed_json=$(array_to_json managed)
    healthy_json=$(array_to_json healthy)
    unhealthy_json=$(array_to_json unhealthy)

    report_status "\"managed\":${managed_json},\"healthy\":${healthy_json},\"unhealthy\":${unhealthy_json}"
}

# --- Entrypoint ---------------------------------------------------------------

logger -t "$LOG_TAG" "Starting service-manager (pid $$)"
report "boot_start" "\"services_dir\":\"${SERVICES_DIR}\",\"check_interval\":${CHECK_INTERVAL}"

# Boot phase
boot_update

# Monitor loop
while true; do
    notify_watchdog
    check_services
    sleep "$CHECK_INTERVAL"
done