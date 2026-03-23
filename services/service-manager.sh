#!/usr/bin/env bash
set -uo pipefail

CONF="/opt/antscihub-pi-service-manager/config/service-manager.conf"
LOG_TAG="antscihub-service-manager"

if [[ ! -f "$CONF" ]]; then
    logger -t "$LOG_TAG" "FATAL: config not found at ${CONF}"
    exit 1
fi
source "$CONF"

DEVICE_ID="${DEVICE_ID:-$(hostname)}"
SERVICES_DIR="${SERVICES_DIR:?SERVICES_DIR not set in service-manager.conf}"
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

logger -t "$LOG_TAG" "Starting MQTT helper..."
coproc MQTT { "$VENV_PYTHON" "$MQTT_HELPER" 2>&1 | logger -t "$LOG_TAG"; }
MQTT_FD=${MQTT[1]}
MQTT_PID=$!

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
    # Send JSON to the persistent MQTT coprocess
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
    local -n arr_ref="$1"
    if [[ ${#arr_ref[@]} -eq 0 ]]; then
        echo "[]"
        return
    fi
    local json_array
    json_array=$(printf '"%s",' "${arr_ref[@]}")
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

discover_services() {
    local found=()
    while IFS= read -r manifest; do
        found+=("$(dirname "$manifest")/")
    done < <(find "${SERVICES_DIR}" -name "antscihub.manifest" -type f 2>/dev/null)
    echo "${found[@]}"
}

run_install() {
    local dir="$1"
    local install_cmd="$2"
    local folder_name="$3"
    local svc="$4"
    local reason="${5:-update}"

    fix_permissions "$dir"
    logger -t "$LOG_TAG" "Running install for ${folder_name}: ${install_cmd}"
    notify_watchdog
    if (cd "$dir" && bash -c "$install_cmd") 2>&1 | logger -t "$LOG_TAG"; then
        report "service_install_done" "\"success\":true,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"reason\":\"${reason}\""
        if [[ -n "$svc" && "$svc" != "$SERVICE_NONE" ]]; then
            systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG" || true
        fi
        return 0
    else
        local exit_code=$?
        report "service_install_done" "\"success\":false,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"exit_code\":${exit_code}"
        return 1
    fi
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
                sleep 2
                exit 0
            fi
        else
            report "self_update_done" "\"success\":false,\"error\":\"git pull failed\",\"dir\":\"${self_dir}\""
        fi
    else
        logger -t "$LOG_TAG" "Self-update repo not found at ${self_dir}; skipping"
    fi

    # Managed services
    local dirs
    dirs=$(discover_services)

    for dir in $dirs; do
        notify_watchdog
        local -A manifest
        parse_manifest "${dir}antscihub.manifest" manifest

        local svc="${manifest[SERVICE_NAME]:-}"
        local remote="${manifest[GIT_REMOTE]:-}"
        local install_cmd="${manifest[INSTALL_CMD]:-}"
        local folder_name
        folder_name=$(basename "$dir")

        if [[ -z "$remote" ]]; then
            logger -t "$LOG_TAG" "No GIT_REMOTE in ${folder_name}, skipping"
            continue
        fi

        if [[ ! -d "${dir}.git" ]]; then
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
    done

    report "boot_update_done" "\"status\":\"complete\""
}

# --- Health check loop --------------------------------------------------------

check_services() {
    local dirs
    dirs=$(discover_services)

    local managed=()
    local healthy=()
    local unhealthy=()

    for dir in $dirs; do
        local -A manifest
        parse_manifest "${dir}antscihub.manifest" manifest

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
    done

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