#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# antscihub service-manager
#
# Scans SERVICES_DIR for folders containing antscihub.manifest.
# Ensures each declared systemd service is running.
# On boot, optionally pulls repos and re-runs install commands.
# Reports everything encrypted over MQTT to fleet/response/{device}.
# =============================================================================

CONF="/opt/antscihub-pi-service-manager/config/service-manager.conf"
LOG_TAG="antscihub-service-manager"

# --- Load config --------------------------------------------------------------

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

# --- Locate MQTT Python environment ------------------------------------------

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
    logger -t "$LOG_TAG" "FATAL: Cannot find MQTT directory (1-MQTT with mqtt_client.py)"
    exit 1
}

RESPONSE_TOPIC="fleet/response/${DEVICE_ID}"

logger -t "$LOG_TAG" "MQTT_DIR=${MQTT_DIR}"

# --- Wait for network ---------------------------------------------------------

logger -t "$LOG_TAG" "Waiting for network..."
for i in $(seq 1 30); do
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        logger -t "$LOG_TAG" "Network up after ${i}s"
        break
    fi
    sleep 1
done

# --- Helpers ------------------------------------------------------------------

report() {
    local event="$1"
    shift
    local extra_json="$1"
    local timestamp
    timestamp=$(date +%s.%3N)

    logger -t "$LOG_TAG" "${event}: ${extra_json}"

    fleet-publish \
        --topic "${RESPONSE_TOPIC}" \
        --json "{\"schema\":\"fleet.service-manager.v1\",\"event\":\"${event}\",\"device_id\":\"${DEVICE_ID}\",\"timestamp\":${timestamp},${extra_json}}" \
        2>/dev/null || logger -t "$LOG_TAG" "WARN: report failed for ${event}"
}

report_status() {
    local json_payload="$1"
    local timestamp
    timestamp=$(date +%s.%3N)

    fleet-publish \
        --topic "${RESPONSE_TOPIC}" \
        --json "{\"schema\":\"fleet.service-manager.v1\",\"event\":\"status\",\"device_id\":\"${DEVICE_ID}\",\"timestamp\":${timestamp},${json_payload}}" \
        2>/dev/null || logger -t "$LOG_TAG" "WARN: status report failed"
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
    for dir in "${SERVICES_DIR}"/*/; do
        [[ -f "${dir}antscihub.manifest" ]] && found+=("$dir")
    done
    echo "${found[@]}"
}

# --- Associative arrays for tracking state ------------------------------------

declare -A FAIL_COUNTS
declare -A RESTART_ATTEMPTS
declare -A GAVE_UP

# --- Boot phase: pull repos and run install -----------------------------------

boot_update() {
    if [[ "$PULL_ON_BOOT" != "true" ]]; then
        logger -t "$LOG_TAG" "PULL_ON_BOOT disabled, skipping repo updates"
        return
    fi

    logger -t "$LOG_TAG" "Boot phase: pulling repos..."
    report "boot_update_start" "\"services_dir\":\"${SERVICES_DIR}\""

boot_update() {
    if [[ "$PULL_ON_BOOT" != "true" ]]; then
        logger -t "$LOG_TAG" "PULL_ON_BOOT disabled, skipping repo updates"
        return
    fi

    logger -t "$LOG_TAG" "Boot phase: pulling repos..."
    report "boot_update_start" "\"services_dir\":\"${SERVICES_DIR}\""

    # First, pull antscihub-pi-service-manager itself
    local self_dir="${SELF_REPO_DIR:-/opt/antscihub-pi-service-manager}"
    if [[ -d "${self_dir}/.git" ]]; then
        local old_head new_head
        old_head=$(git -C "$self_dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        # Reset any local changes before pulling
        git -C "$self_dir" reset --hard HEAD 2>/dev/null || true
        git -C "$self_dir" clean -fd 2>/dev/null || true

        if git -C "$self_dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
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

    # Now pull each managed service
    local dirs
    dirs=$(discover_services)

    for dir in $dirs; do
        local -A manifest
        parse_manifest "${dir}antscihub.manifest" manifest

        local svc="${manifest[SERVICE_NAME]:-}"
        local remote="${manifest[GIT_REMOTE]:-}"
        local install_cmd="${manifest[INSTALL_CMD]:-}"
        local folder_name
        folder_name=$(basename "$dir")

        if [[ -z "$remote" ]]; then
            logger -t "$LOG_TAG" "No GIT_REMOTE in ${folder_name}, skipping pull"
            continue
        fi

        if [[ ! -d "${dir}.git" ]]; then
            logger -t "$LOG_TAG" "${folder_name} not a git repo, skipping"
            continue
        fi

        report "service_update_start" "\"service\":\"${folder_name}\""

        local old_head new_head
        old_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        # Reset any local changes before pulling
        git -C "$dir" reset --hard HEAD 2>/dev/null || true
        git -C "$dir" clean -fd 2>/dev/null || true

        if git -C "$dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
            new_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

            if [[ "$old_head" != "$new_head" ]]; then
                report "service_update_done" "\"success\":true,\"service\":\"${folder_name}\",\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\""

                if [[ -n "$install_cmd" && "$install_cmd" != "none" ]]; then
                    logger -t "$LOG_TAG" "Running install for ${folder_name}: ${install_cmd}"
                    local install_exit=0
                    if (cd "$dir" && bash -c "$install_cmd") 2>&1 | logger -t "$LOG_TAG"; then
                        report "service_install_done" "\"success\":true,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\""
                    else
                        install_exit=$?
                        report "service_install_done" "\"success\":false,\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"exit_code\":${install_exit}"
                    fi
                fi

                if [[ -n "$svc" && "$svc" != "none" ]]; then
                    systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG" || true
                fi
            else
                logger -t "$LOG_TAG" "${folder_name}: up to date (${old_head:0:8})"
                report "service_update_done" "\"success\":true,\"service\":\"${folder_name}\",\"changed\":false"
            fi
        else
            report "service_update_done" "\"success\":false,\"error\":\"git pull failed\",\"service\":\"${folder_name}\",\"remote\":\"${remote}\""
        fi
    done

    report "boot_update_done" "\"status\":\"complete\""
}

# --- Main loop: monitor services ----------------------------------------------

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

        if [[ -z "$svc" || "$svc" == "none" ]]; then
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

        # Service is not active
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

    # Build JSON arrays
    local managed_json="[]"
    if [[ ${#managed[@]} -gt 0 ]]; then
        managed_json=$(printf '"%s",' "${managed[@]}")
        managed_json="[${managed_json%,}]"
    fi

    local healthy_json="[]"
    if [[ ${#healthy[@]} -gt 0 ]]; then
        healthy_json=$(printf '"%s",' "${healthy[@]}")
        healthy_json="[${healthy_json%,}]"
    fi

    local unhealthy_json="[]"
    if [[ ${#unhealthy[@]} -gt 0 ]]; then
        unhealthy_json=$(printf '"%s",' "${unhealthy[@]}")
        unhealthy_json="[${unhealthy_json%,}]"
    fi

    report_status "\"managed\":${managed_json},\"healthy\":${healthy_json},\"unhealthy\":${unhealthy_json}"
}

# --- Entrypoint ---------------------------------------------------------------

logger -t "$LOG_TAG" "Starting service-manager (pid $$)"
report "boot_start" "\"services_dir\":\"${SERVICES_DIR}\",\"check_interval\":${CHECK_INTERVAL}"

# Boot phase
boot_update

# Monitor loop
while true; do
    check_services
    sleep "$CHECK_INTERVAL"
done