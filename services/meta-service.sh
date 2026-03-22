#!/usr/bin/env bash
set -uo pipefail

# =============================================================================
# antscihub meta-service
#
# Scans SERVICES_DIR for folders containing antscihub.manifest.
# Ensures each declared systemd service is running.
# On boot, optionally pulls repos and re-runs install commands.
# Reports everything via fleet-publish.
# =============================================================================

CONF="/opt/antscihub-pi-service-manager/config/meta.conf"
LOG_TAG="antscihub-meta"

# --- Load config --------------------------------------------------------------

if [[ ! -f "$CONF" ]]; then
    logger -t "$LOG_TAG" "FATAL: config not found at ${CONF}"
    exit 1
fi
source "$CONF"

DEVICE_ID="${DEVICE_ID:-$(hostname)}"
SERVICES_DIR="${SERVICES_DIR:?SERVICES_DIR not set in meta.conf}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
RESTART_THRESHOLD="${RESTART_THRESHOLD:-3}"
MAX_RESTART_ATTEMPTS="${MAX_RESTART_ATTEMPTS:-5}"
PULL_ON_BOOT="${PULL_ON_BOOT:-true}"
TOPIC_PREFIX="${MQTT_TOPIC_PREFIX:-fleet/managed-services}/${DEVICE_ID}/meta"

# --- Helpers ------------------------------------------------------------------

report() {
    local event="$1"
    shift
    local json="$1"
    logger -t "$LOG_TAG" "${event}: ${json}"
    fleet-publish --topic "${TOPIC_PREFIX}" \
        --json "{\"event\":\"${event}\",${json}}" \
        2>/dev/null || logger -t "$LOG_TAG" "WARN: fleet-publish failed for ${event}"
}

parse_manifest() {
    # Reads a manifest file into associative array passed by nameref
    local manifest_path="$1"
    local -n _out="$2"

    _out=()
    while IFS='=' read -r key value; do
        # Skip comments and blanks
        [[ "$key" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$key" ]] && continue
        # Trim whitespace
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        _out["$key"]="$value"
    done < "$manifest_path"
}

discover_services() {
    # Returns list of directories under SERVICES_DIR that have antscihub.manifest
    local found=()
    for dir in "${SERVICES_DIR}"/*/; do
        [[ -f "${dir}antscihub.manifest" ]] && found+=("$dir")
    done
    echo "${found[@]}"
}

# --- Associative arrays for tracking state ------------------------------------

declare -A FAIL_COUNTS          # service_name -> consecutive check failures
declare -A RESTART_ATTEMPTS     # service_name -> consecutive restart attempts
declare -A GAVE_UP              # service_name -> 1 if we stopped trying

# --- Boot phase: pull repos and run install -----------------------------------

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
        
        if git -C "$self_dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
            new_head=$(git -C "$self_dir" rev-parse HEAD 2>/dev/null || echo "unknown")
            if [[ "$old_head" != "$new_head" ]]; then
                report "self_updated" "\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\",\"source\":\"${self_dir}\""
                logger -t "$LOG_TAG" "Self-updated, re-running install.sh..."
                bash "${self_dir}/install.sh" 2>&1 | logger -t "$LOG_TAG"
                # install.sh will restart this service, so exit cleanly
                report "self_reinstalled" "\"head\":\"${new_head:0:8}\""
                exit 0
            fi
        else
            report "self_pull_failed" "\"dir\":\"${self_dir}\""
        fi
    else
        logger -t "$LOG_TAG" "Self-update repo not found at ${self_dir}; skipping self pull"
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
            logger -t "$LOG_TAG" "No GIT_REMOTE in ${folder_name}/antscihub.manifest, skipping pull"
            continue
        fi

        if [[ ! -d "${dir}.git" ]]; then
            logger -t "$LOG_TAG" "${folder_name} has GIT_REMOTE but is not a git repo, skipping"
            continue
        fi

        local old_head new_head
        old_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

        if git -C "$dir" pull --ff-only 2>&1 | logger -t "$LOG_TAG"; then
            new_head=$(git -C "$dir" rev-parse HEAD 2>/dev/null || echo "unknown")

            if [[ "$old_head" != "$new_head" ]]; then
                report "repo_updated" "\"service\":\"${folder_name}\",\"old\":\"${old_head:0:8}\",\"new\":\"${new_head:0:8}\""

                if [[ -n "$install_cmd" && "$install_cmd" != "none" ]]; then
                    logger -t "$LOG_TAG" "Running install for ${folder_name}: ${install_cmd}"
                    if (cd "$dir" && bash -c "$install_cmd") 2>&1 | logger -t "$LOG_TAG"; then
                        report "install_ok" "\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\""
                    else
                        report "install_failed" "\"service\":\"${folder_name}\",\"cmd\":\"${install_cmd}\",\"exit_code\":$?"
                    fi
                fi

                # Restart the service if it has one
                if [[ -n "$svc" && "$svc" != "none" ]]; then
                    systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG" || true
                fi
            else
                logger -t "$LOG_TAG" "${folder_name}: already up to date (${old_head:0:8})"
            fi
        else
            report "pull_failed" "\"service\":\"${folder_name}\",\"remote\":\"${remote}\""
        fi
    done

    report "boot_update_done" "\"status\":\"complete\""
}

# --- Main loop: monitor services ----------------------------------------------

check_services() {
    local dirs
    dirs=$(discover_services)

    local managed_count=0
    local healthy_count=0
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

        managed_count=$((managed_count + 1))

        # Check if active
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            healthy_count=$((healthy_count + 1))
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
            # Already gave up, just keep reporting
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

            report "service_restarting" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts},\"consecutive_failures\":${fails}"

            if systemctl restart "$svc" 2>&1 | logger -t "$LOG_TAG"; then
                FAIL_COUNTS["$svc"]=0
                # Wait grace period before checking again
                sleep "$grace"

                if systemctl is-active --quiet "$svc" 2>/dev/null; then
                    report "service_recovered" "\"service\":\"${svc}\",\"folder\":\"${folder_name}\",\"attempt\":${attempts}"
                    RESTART_ATTEMPTS["$svc"]=0
                    healthy_count=$((healthy_count + 1))
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
            # Below threshold, just note it
            logger -t "$LOG_TAG" "${svc} not active (failure ${fails}/${RESTART_THRESHOLD})"
            unhealthy+=("$svc")
        fi
    done

    # Periodic summary
    local unhealthy_json="[]"
    if [[ ${#unhealthy[@]} -gt 0 ]]; then
        unhealthy_json=$(printf '"%s",' "${unhealthy[@]}")
        unhealthy_json="[${unhealthy_json%,}]"
    fi

    report "status" "\"managed\":${managed_count},\"healthy\":${healthy_count},\"unhealthy\":${unhealthy_json}"
}

# --- Entrypoint ---------------------------------------------------------------

logger -t "$LOG_TAG" "Starting meta-service (pid $$)"
report "started" "\"services_dir\":\"${SERVICES_DIR}\",\"check_interval\":${CHECK_INTERVAL}"

# Wait for network and fleet-publish to be available
sleep 5

# Boot phase
boot_update

# Monitor loop
while true; do
    check_services
    sleep "$CHECK_INTERVAL"
done