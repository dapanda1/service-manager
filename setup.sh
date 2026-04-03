#!/bin/bash
set -euo pipefail

# ============================================================================
# Service Manager Setup Script
# Version: 2.0.1
#
# Monitor-based approach: programs are started/stopped by the user normally
# (taskbar, icon, right-click close). A health check runs on a timer to:
#   - Restart programs that aren't running
#   - Perform scheduled restarts for memory leak mitigation
#   - Log memory and CPU trends to CSV
#   - Flag high CPU usage
#   - Send notifications on failure
#
# No systemd .service units are created for the managed programs.
# Systemd is only used for the health check timer, dashboard, and notify.
# ============================================================================

VERSION="2.0.1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/services.conf"
SYSTEMD_DIR="/etc/systemd/system"
BIN_DIR="/usr/local/bin"
LOGROTATE_DIR="/etc/logrotate.d"
DATA_DIR="/var/lib/svc-manager"
LOG_DIR="/var/log/svc-manager"
MEMORY_CSV="${LOG_DIR}/memory.csv"
CHECKSUM_FILE="${DATA_DIR}/checksums"

DRY_RUN=false
VERBOSE=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_dry()   { echo -e "${CYAN}[DRY]${NC}  $1"; }

usage() {
    cat << EOF
Service Manager v${VERSION}

Usage: $0 [OPTION]

Options:
  --install       Install and enable health check, dashboard, notifications
  --uninstall     Stop, disable, and remove all generated files
  --update        Regenerate files, restart only components that changed
  --status        Show program status, memory, CPU, restart countdown
  --dry-run       Show what --install would do without making changes
  --verbose       With --dry-run, print generated file contents
  --help          Show this help message
EOF
    exit 0
}

# ---------- Utility ----------

write_file() {
    local path="$1"
    local content="$2"
    local mode="${3:-644}"

    if $DRY_RUN; then
        log_dry "Would create ${path} (mode ${mode})"
        if $VERBOSE; then
            echo "--- begin ${path} ---"
            echo "$content"
            echo "--- end ${path} ---"
        fi
        return
    fi

    echo "$content" > "$path"
    chmod "$mode" "$path"
    log_info "Created ${path}"
}

format_duration() {
    local secs="$1"
    if [[ "$secs" -lt 0 ]]; then
        echo "overdue"
        return
    fi
    local days=$(( secs / 86400 ))
    local hours=$(( (secs % 86400) / 3600 ))
    local mins=$(( (secs % 3600) / 60 ))
    echo "${days}d ${hours}h ${mins}m"
}

# ---------- Config loading ----------

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        log_error "Config file not found: ${CONFIG_FILE}"
        log_error "Copy services.conf.example to services.conf and fill in your values."
        exit 1
    fi
    source "$CONFIG_FILE"
}

get_svc_var() {
    local index="$1"
    local field="$2"
    local default="${3:-}"
    local varname="SERVICE_${index}_${field}"
    echo "${!varname:-$default}"
}

validate_config() {
    local errors=0
    local count="${SERVICE_COUNT:-0}"

    if [[ "$count" -lt 1 ]]; then
        log_error "SERVICE_COUNT must be at least 1."
        exit 1
    fi

    local seen_names=()
    for i in $(seq 1 "$count"); do
        local name=$(get_svc_var "$i" "NAME")
        local path=$(get_svc_var "$i" "PATH")

        if [[ -z "$name" ]]; then
            log_error "SERVICE_${i}_NAME is required."
            errors=1
        fi
        if [[ -z "$path" ]]; then
            log_error "SERVICE_${i}_PATH is required."
            errors=1
        fi

        for seen in "${seen_names[@]+"${seen_names[@]}"}"; do
            if [[ "$seen" == "$name" ]]; then
                log_error "Duplicate service name: ${name}"
                errors=1
            fi
        done
        seen_names+=("$name")

        if [[ -n "$path" ]]; then
            if [[ ! -e "$path" ]]; then
                log_warn "SERVICE_${i}_PATH does not exist yet: ${path}"
            elif [[ ! -x "$path" ]]; then
                log_warn "SERVICE_${i}_PATH is not executable: ${path}"
            fi
        fi
    done

    if [[ "$errors" -eq 1 ]]; then
        exit 1
    fi

    RESTART_INTERVAL_DAYS="${RESTART_INTERVAL_DAYS:-3}"
    RESTART_DELAY_SECS="${RESTART_DELAY_SECS:-300}"
    HEALTH_CHECK_INTERVAL="${HEALTH_CHECK_INTERVAL:-2h}"
    NOTIFY_WEBHOOK_URL="${NOTIFY_WEBHOOK_URL:-}"
    NOTIFY_EMAIL="${NOTIFY_EMAIL:-}"
    NOTIFY_EMAIL_FROM="${NOTIFY_EMAIL_FROM:-svc-manager@$(hostname)}"
    CONFIG_BACKUP_DIR="${CONFIG_BACKUP_DIR:-}"
    DASHBOARD_PORT="${DASHBOARD_PORT:-0}"
    CPU_THRESHOLD="${CPU_THRESHOLD:-90}"
}

# ---------- Checksum tracking ----------

compute_checksum() {
    local content="$1"
    echo "$content" | sha256sum | awk '{print $1}'
}

load_checksums() {
    declare -gA SAVED_CHECKSUMS
    if [[ -f "$CHECKSUM_FILE" ]]; then
        while IFS='=' read -r key val; do
            SAVED_CHECKSUMS["$key"]="$val"
        done < "$CHECKSUM_FILE"
    fi
}

save_checksums() {
    if $DRY_RUN; then return; fi
    mkdir -p "$DATA_DIR"
    : > "$CHECKSUM_FILE"
    for key in "${!NEW_CHECKSUMS[@]}"; do
        echo "${key}=${NEW_CHECKSUMS[$key]}" >> "$CHECKSUM_FILE"
    done
}

declare -A NEW_CHECKSUMS

# ---------- Generators ----------

generate_health_check_script() {
    local count="${SERVICE_COUNT}"
    local script_path="${BIN_DIR}/svc-manager-health-check.sh"
    local restart_interval_secs=$(( RESTART_INTERVAL_DAYS * 86400 ))

    # Build config arrays for the health check script
    local names_arr="" paths_arr="" args_arr="" users_arr=""
    local env_arr="" pgrep_arr="" health_cmds_arr=""
    local pre_shutdown_arr="" stagger_arr="" memory_max_arr=""

    for i in $(seq 1 "$count"); do
        names_arr+="\"$(get_svc_var "$i" "NAME")\" "
        paths_arr+="\"$(get_svc_var "$i" "PATH")\" "
        args_arr+="\"$(get_svc_var "$i" "ARGS")\" "
        users_arr+="\"$(get_svc_var "$i" "USER" "root")\" "
        env_arr+="\"$(get_svc_var "$i" "ENV")\" "
        pgrep_arr+="\"$(get_svc_var "$i" "PGREP" "$(basename "$(get_svc_var "$i" "PATH")")")\" "
        health_cmds_arr+="\"$(get_svc_var "$i" "HEALTH_CMD")\" "
        pre_shutdown_arr+="\"$(get_svc_var "$i" "PRE_SHUTDOWN")\" "
        stagger_arr+="\"$(get_svc_var "$i" "STAGGER_HOURS" "0")\" "
        memory_max_arr+="\"$(get_svc_var "$i" "MEMORY_MAX")\" "
    done

    local content='#!/bin/bash
set -euo pipefail

LOCK_FILE="/tmp/svc-manager-health-check.lock"
DATA_DIR="'"${DATA_DIR}"'"
MEMORY_CSV="'"${MEMORY_CSV}"'"
CPU_THRESHOLD="'"${CPU_THRESHOLD}"'"
RESTART_INTERVAL_SECS="'"${restart_interval_secs}"'"
RESTART_DELAY_SECS="'"${RESTART_DELAY_SECS}"'"
NOTIFY_SCRIPT="'"${BIN_DIR}/svc-manager-notify-failure.sh"'"

NAMES=('"${names_arr}"')
PATHS=('"${paths_arr}"')
ARGS=('"${args_arr}"')
USERS=('"${users_arr}"')
ENVS=('"${env_arr}"')
PGREPS=('"${pgrep_arr}"')
HEALTH_CMDS=('"${health_cmds_arr}"')
PRE_SHUTDOWNS=('"${pre_shutdown_arr}"')
STAGGERS=('"${stagger_arr}"')
MEMORY_MAXES=('"${memory_max_arr}"')

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"') Health check already running, skipping."
    exit 0
fi

mkdir -p "$DATA_DIR" "$(dirname "$MEMORY_CSV")"

if [[ ! -f "$MEMORY_CSV" ]]; then
    echo "timestamp,service,pid,rss_kb,cpu_pct,status" > "$MEMORY_CSV"
fi

TS="$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')"
NOW=$(date +%s)

is_running() {
    local pattern="$1"
    local user="$2"
    pgrep -u "$user" -f "$pattern" >/dev/null 2>&1
}

get_pid() {
    local pattern="$1"
    local user="$2"
    pgrep -u "$user" -f "$pattern" -n 2>/dev/null || echo "0"
}

start_program() {
    local idx="$1"
    local path="${PATHS[$idx]}"
    local args="${ARGS[$idx]}"
    local user="${USERS[$idx]}"
    local env="${ENVS[$idx]}"
    local name="${NAMES[$idx]}"
    local pgrep_pat="${PGREPS[$idx]}"

    # Build environment exports
    local env_exports=""
    if [[ -n "$env" ]]; then
        IFS='"'"';'"'"' read -ra envs <<< "$env"
        for ev in "${envs[@]}"; do
            ev=$(echo "$ev" | xargs)
            if [[ -n "$ev" ]]; then
                env_exports+="export ${ev}; "
            fi
        done
    fi

    echo "${TS} Starting ${name} as ${user}..."
    sudo -u "$user" bash -c "${env_exports}nohup ${path}${args:+ ${args}} >/dev/null 2>&1 &"

    # Wait briefly and verify it started
    sleep 5
    if is_running "${pgrep_pat}" "$user"; then
        echo "${TS} ${name} started successfully."
        return 0
    else
        echo "${TS} ${name} failed to start."
        if [[ -x "$NOTIFY_SCRIPT" ]]; then
            "$NOTIFY_SCRIPT" "${name}" 2>/dev/null || true
        fi
        return 1
    fi
}

stop_program() {
    local idx="$1"
    local user="${USERS[$idx]}"
    local name="${NAMES[$idx]}"
    local pre_shutdown="${PRE_SHUTDOWNS[$idx]}"
    local pgrep_pat="${PGREPS[$idx]}"
    local pid

    pid=$(get_pid "$pgrep_pat" "$user")
    if [[ "$pid" -eq 0 ]]; then
        return 0
    fi

    echo "${TS} Stopping ${name} (PID ${pid})..."

    # Run pre-shutdown command if configured
    if [[ -n "$pre_shutdown" ]]; then
        echo "${TS} Running pre-shutdown for ${name}..."
        sudo -u "$user" bash -c "$pre_shutdown" 2>/dev/null || true
    fi

    # Graceful shutdown
    kill -TERM "$pid" 2>/dev/null || true

    # Wait up to 30 seconds for clean exit
    local waited=0
    while [[ $waited -lt 30 ]]; do
        if ! kill -0 "$pid" 2>/dev/null; then
            echo "${TS} ${name} stopped cleanly."
            return 0
        fi
        sleep 1
        waited=$(( waited + 1 ))
    done

    # Force kill
    echo "${TS} ${name} did not stop in 30s, sending SIGKILL..."
    kill -KILL "$pid" 2>/dev/null || true
    sleep 1
}

get_last_restart() {
    local name="$1"
    local file="${DATA_DIR}/${name}.last_restart"
    if [[ -f "$file" ]]; then
        cat "$file"
    else
        echo "0"
    fi
}

set_last_restart() {
    local name="$1"
    local ts="$2"
    echo "$ts" > "${DATA_DIR}/${name}.last_restart"
}

# Convert memory max string (e.g., "256M", "1G") to KB
parse_memory_max_kb() {
    local val="$1"
    if [[ -z "$val" ]]; then
        echo "0"
        return
    fi
    local num="${val%[A-Za-z]*}"
    local unit="${val##*[0-9]}"
    case "${unit^^}" in
        K) echo "$num" ;;
        M) echo $(( num * 1024 )) ;;
        G) echo $(( num * 1024 * 1024 )) ;;
        *) echo "0" ;;
    esac
}

# ---------- Main loop ----------

for idx in "${!NAMES[@]}"; do
    name="${NAMES[$idx]}"
    path="${PATHS[$idx]}"
    user="${USERS[$idx]}"
    pgrep_pat="${PGREPS[$idx]}"
    hcmd="${HEALTH_CMDS[$idx]}"
    stagger="${STAGGERS[$idx]}"
    mem_max="${MEMORY_MAXES[$idx]}"

    pid="0"
    rss="0"
    cpu="0.0"
    status="unknown"

    stagger_secs=$(( stagger * 3600 ))
    effective_interval=$(( RESTART_INTERVAL_SECS + stagger_secs ))

    running=false
    if is_running "$pgrep_pat" "$user"; then
        running=true
        pid=$(get_pid "$pgrep_pat" "$user")
    fi

    if $running; then
        # Gather metrics
        if [[ "$pid" -gt 0 ]] && [[ -d "/proc/${pid}" ]]; then
            rss=$(awk '"'"'/VmRSS/ {print $2}'"'"' "/proc/${pid}/status" 2>/dev/null || echo "0")
            cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"' || echo "0.0")
        fi

        status="running"

        # Check if scheduled restart is due
        last_restart=$(get_last_restart "$name")
        if [[ "$last_restart" -eq 0 ]]; then
            # First run — record current time as baseline, no restart yet
            set_last_restart "$name" "$NOW"
        else
            elapsed=$(( NOW - last_restart ))
            if [[ "$elapsed" -ge "$effective_interval" ]]; then
                echo "${TS} ${name} scheduled restart (${elapsed}s since last restart, interval ${effective_interval}s)."
                stop_program "$idx"
                status="scheduled_restart"

                echo "${TS} Waiting ${RESTART_DELAY_SECS}s before restarting ${name}..."
                sleep "$RESTART_DELAY_SECS"

                if start_program "$idx"; then
                    set_last_restart "$name" "$(date +%s)"
                    status="restarted_scheduled"
                    pid=$(get_pid "$pgrep_pat" "$user")
                    if [[ "$pid" -gt 0 ]] && [[ -d "/proc/${pid}" ]]; then
                        rss=$(awk '"'"'/VmRSS/ {print $2}'"'"' "/proc/${pid}/status" 2>/dev/null || echo "0")
                        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"' || echo "0.0")
                    fi
                else
                    status="restart_failed"
                fi

                # Skip further checks after a scheduled restart
                echo "${TS},${name},${pid},${rss},${cpu},${status}" >> "$MEMORY_CSV"
                echo "${TS} ${name}: pid=${pid} rss=${rss}KB cpu=${cpu}% status=${status}"
                continue
            fi
        fi

        # Memory cap check
        if [[ -n "$mem_max" ]]; then
            max_kb=$(parse_memory_max_kb "$mem_max")
            if [[ "$max_kb" -gt 0 ]] && [[ "$rss" -gt "$max_kb" ]]; then
                echo "${TS} ${name} memory ${rss}KB exceeds cap ${max_kb}KB. Restarting..."
                stop_program "$idx"
                sleep "$RESTART_DELAY_SECS"
                if start_program "$idx"; then
                    set_last_restart "$name" "$(date +%s)"
                    status="restarted_memory_cap"
                else
                    status="restart_failed"
                fi
                pid=$(get_pid "$pgrep_pat" "$user")
                echo "${TS},${name},${pid},${rss},${cpu},${status}" >> "$MEMORY_CSV"
                echo "${TS} ${name}: pid=${pid} rss=${rss}KB cpu=${cpu}% status=${status}"
                continue
            fi
        fi

        # Custom health check
        if [[ -n "$hcmd" ]]; then
            if sudo -u "$user" bash -c "$hcmd" >/dev/null 2>&1; then
                status="healthy"
            else
                echo "${TS} ${name} health command failed. Restarting..."
                stop_program "$idx"
                sleep 5
                if start_program "$idx"; then
                    set_last_restart "$name" "$(date +%s)"
                    status="restarted_health_fail"
                else
                    status="restart_failed"
                fi
                pid=$(get_pid "$pgrep_pat" "$user")
                echo "${TS},${name},${pid},${rss},${cpu},${status}" >> "$MEMORY_CSV"
                echo "${TS} ${name}: pid=${pid} rss=${rss}KB cpu=${cpu}% status=${status}"
                continue
            fi
        fi

        # CPU threshold check (informational only)
        cpu_int=${cpu%%.*}
        if [[ "${cpu_int:-0}" -ge "$CPU_THRESHOLD" ]]; then
            echo "${TS} ${name} CPU at ${cpu}% (threshold: ${CPU_THRESHOLD}%)."
            status="high_cpu"
            logger -t svc-manager "${name} CPU at ${cpu}% exceeds threshold ${CPU_THRESHOLD}%"
        fi

    else
        # Not running — start it
        echo "${TS} ${name} is not running."
        if start_program "$idx"; then
            # Only reset the restart timer if there was no previous baseline
            last_restart=$(get_last_restart "$name")
            if [[ "$last_restart" -eq 0 ]]; then
                set_last_restart "$name" "$(date +%s)"
            fi
            pid=$(get_pid "$pgrep_pat" "$user")
            status="started"
        else
            status="start_failed"
        fi
    fi

    echo "${TS},${name},${pid},${rss},${cpu},${status}" >> "$MEMORY_CSV"
    echo "${TS} ${name}: pid=${pid} rss=${rss}KB cpu=${cpu}% status=${status}"
done'

    NEW_CHECKSUMS["health-check"]=$(compute_checksum "$content")
    write_file "$script_path" "$content" "755"
}

generate_health_check_units() {
    local svc_file="${SYSTEMD_DIR}/svc-manager-health-check.service"
    local timer_file="${SYSTEMD_DIR}/svc-manager-health-check.timer"

    local svc_content="[Unit]
Description=Health check for managed programs

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/svc-manager-health-check.sh"

    local timer_content="[Unit]
Description=Health check timer for managed programs

[Timer]
OnBootSec=2min
OnUnitActiveSec=${HEALTH_CHECK_INTERVAL}
Persistent=true

[Install]
WantedBy=timers.target"

    NEW_CHECKSUMS["health-check-service"]=$(compute_checksum "$svc_content")
    NEW_CHECKSUMS["health-check-timer"]=$(compute_checksum "$timer_content")
    write_file "$svc_file" "$svc_content"
    write_file "$timer_file" "$timer_content"
}

generate_notify_script() {
    local script_path="${BIN_DIR}/svc-manager-notify-failure.sh"

    local content='#!/bin/bash
set -euo pipefail

FAILED="${1:-unknown}"
TIMESTAMP="$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')"
HOSTNAME="$(hostname)"
MESSAGE="[svc-manager] ${FAILED} failed on ${HOSTNAME} at ${TIMESTAMP}"

logger -t svc-manager "${MESSAGE}"

# Webhook
WEBHOOK_URL="'"${NOTIFY_WEBHOOK_URL}"'"
if [[ -n "${WEBHOOK_URL}" ]]; then
    curl -sf -X POST -H "Content-Type: application/json" \
        -d "{\"text\": \"${MESSAGE}\"}" \
        "${WEBHOOK_URL}" >/dev/null 2>&1 || true
fi

# Email
EMAIL_TO="'"${NOTIFY_EMAIL}"'"
EMAIL_FROM="'"${NOTIFY_EMAIL_FROM}"'"
if [[ -n "${EMAIL_TO}" ]]; then
    if command -v msmtp >/dev/null 2>&1; then
        printf "Subject: %s\nFrom: %s\nTo: %s\n\n%s\n" \
            "${MESSAGE}" "${EMAIL_FROM}" "${EMAIL_TO}" "${MESSAGE}" | \
            msmtp "${EMAIL_TO}" 2>/dev/null || true
    elif command -v sendmail >/dev/null 2>&1; then
        printf "Subject: %s\nFrom: %s\nTo: %s\n\n%s\n" \
            "${MESSAGE}" "${EMAIL_FROM}" "${EMAIL_TO}" "${MESSAGE}" | \
            sendmail "${EMAIL_TO}" 2>/dev/null || true
    else
        logger -t svc-manager "Email configured but no msmtp or sendmail found."
    fi
fi'

    NEW_CHECKSUMS["notify"]=$(compute_checksum "$content")
    write_file "$script_path" "$content" "755"
}

generate_logrotate() {
    local name="$1"
    local log_file="$2"

    if [[ -z "$log_file" ]]; then return; fi

    local conf_file="${LOGROTATE_DIR}/svc-manager-${name}"
    local content="${log_file} {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}"

    write_file "$conf_file" "$content"
}

generate_memory_csv_logrotate() {
    local conf_file="${LOGROTATE_DIR}/svc-manager-memory-csv"
    local content="${MEMORY_CSV} {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}"

    write_file "$conf_file" "$content"
}

generate_dashboard() {
    local port="${DASHBOARD_PORT}"
    if [[ "$port" -eq 0 ]]; then return; fi

    local script_path="${BIN_DIR}/svc-manager-dashboard.py"
    local unit_file="${SYSTEMD_DIR}/svc-manager-dashboard.service"

    local restart_base_secs=$(( RESTART_INTERVAL_DAYS * 86400 ))

    # Build Python lists/dicts from config
    local py_names="[" py_paths="[" py_users="[" py_pgreps="[" py_staggers="{"
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local path=$(get_svc_var "$i" "PATH")
        local user=$(get_svc_var "$i" "USER" "root")
        local pgrep_pat=$(get_svc_var "$i" "PGREP" "$(basename "$path")")
        local stagger=$(get_svc_var "$i" "STAGGER_HOURS" "0")
        if [[ "$i" -gt 1 ]]; then
            py_names+=", "; py_paths+=", "; py_users+=", "; py_pgreps+=", "
            py_staggers+=", "
        fi
        py_names+="\"${name}\""
        py_paths+="\"${path}\""
        py_users+="\"${user}\""
        py_pgreps+="\"${pgrep_pat}\""
        py_staggers+="\"${name}\": ${stagger}"
    done
    py_names+="]"; py_paths+="]"; py_users+="]"; py_pgreps+="]"; py_staggers+="}"

    local py_content="#!/usr/bin/env python3
\"\"\"Lightweight JSON status dashboard for svc-manager.\"\"\"

import http.server
import json
import subprocess
import os
import time
from datetime import datetime

PORT = ${port}
VERSION = \"${VERSION}\"
SERVICES = ${py_names}
PATHS = ${py_paths}
USERS = ${py_users}
PGREPS = ${py_pgreps}
RESTART_BASE_SECS = ${restart_base_secs}
RESTART_DELAY_SECS = ${RESTART_DELAY_SECS}
STAGGER_HOURS = ${py_staggers}
DATA_DIR = \"${DATA_DIR}\"
MEMORY_CSV = \"${MEMORY_CSV}\"


def get_service_info(idx):
    name = SERVICES[idx]
    path = PATHS[idx]
    user = USERS[idx]
    pgrep_pat = PGREPS[idx]

    stagger_secs = STAGGER_HOURS.get(name, 0) * 3600

    info = {
        \"name\": name, \"state\": \"stopped\", \"pid\": 0,
        \"rss_kb\": 0, \"cpu_pct\": 0.0, \"uptime_secs\": 0,
        \"restart_in_secs\": 0,
        \"restart_interval_days\": RESTART_BASE_SECS // 86400,
        \"restart_delay_secs\": RESTART_DELAY_SECS,
        \"stagger_hours\": STAGGER_HOURS.get(name, 0),
        \"effective_interval_secs\": RESTART_BASE_SECS + stagger_secs
    }

    try:
        r = subprocess.run([\"pgrep\", \"-u\", user, \"-f\", pgrep_pat, \"-n\"],
                           capture_output=True, text=True, timeout=5)
        pid = int(r.stdout.strip()) if r.returncode == 0 else 0
    except Exception:
        pid = 0

    if pid == 0:
        return info

    info[\"state\"] = \"running\"
    info[\"pid\"] = pid

    try:
        if os.path.isfile(f\"/proc/{pid}/status\"):
            with open(f\"/proc/{pid}/status\") as f:
                for line in f:
                    if line.startswith(\"VmRSS:\"):
                        info[\"rss_kb\"] = int(line.split()[1])
                        break
        r = subprocess.run([\"ps\", \"-o\", \"%cpu=\", \"-p\", str(pid)],
                           capture_output=True, text=True, timeout=5)
        info[\"cpu_pct\"] = float(r.stdout.strip() or \"0\")
    except Exception:
        pass

    # Uptime from /proc/pid
    try:
        stat_start = os.stat(f\"/proc/{pid}\").st_mtime
        info[\"uptime_secs\"] = int(time.time() - stat_start)
    except Exception:
        pass

    # Next restart countdown
    try:
        lr_file = os.path.join(DATA_DIR, f\"{name}.last_restart\")
        if os.path.isfile(lr_file):
            with open(lr_file) as f:
                last_restart = int(f.read().strip())
            stagger_secs = STAGGER_HOURS.get(name, 0) * 3600
            remaining = info[\"effective_interval_secs\"] - (int(time.time()) - last_restart)
            info[\"restart_in_secs\"] = max(0, remaining)
    except Exception:
        pass

    return info


def get_recent_memory(lines=100):
    rows = []
    if not os.path.isfile(MEMORY_CSV):
        return rows
    try:
        r = subprocess.run([\"tail\", \"-n\", str(lines), MEMORY_CSV],
                           capture_output=True, text=True, timeout=5)
        for line in r.stdout.strip().split(\"\\n\"):
            if line and not line.startswith(\"timestamp\"):
                parts = line.split(\",\")
                if len(parts) >= 6:
                    rows.append({
                        \"timestamp\": parts[0], \"service\": parts[1],
                        \"pid\": parts[2], \"rss_kb\": parts[3],
                        \"cpu_pct\": parts[4], \"status\": parts[5]
                    })
    except Exception:
        pass
    return rows


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in (\"/\", \"/status\"):
            data = {
                \"version\": VERSION,
                \"timestamp\": datetime.now().isoformat(),
                \"services\": [get_service_info(i) for i in range(len(SERVICES))],
            }
            self._json_response(data)
        elif self.path == \"/memory\":
            data = {
                \"timestamp\": datetime.now().isoformat(),
                \"history\": get_recent_memory(100),
            }
            self._json_response(data)
        else:
            self.send_response(404)
            self.end_headers()

    def _json_response(self, data):
        self.send_response(200)
        self.send_header(\"Content-Type\", \"application/json\")
        self.send_header(\"Access-Control-Allow-Origin\", \"*\")
        self.end_headers()
        self.wfile.write(json.dumps(data, indent=2).encode())

    def log_message(self, fmt, *args):
        pass


if __name__ == \"__main__\":
    server = http.server.HTTPServer((\"\", PORT), Handler)
    print(f\"svc-manager dashboard on port {PORT}\")
    server.serve_forever()
"

    local unit_content="[Unit]
Description=Service manager JSON dashboard
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 ${script_path}
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target"

    NEW_CHECKSUMS["dashboard"]=$(compute_checksum "$py_content")
    NEW_CHECKSUMS["dashboard-unit"]=$(compute_checksum "$unit_content")
    write_file "$script_path" "$py_content" "755"
    write_file "$unit_file" "$unit_content"
}

# ---------- Config backup ----------

backup_config() {
    local dest="${CONFIG_BACKUP_DIR}"
    if [[ -z "$dest" ]]; then return; fi

    if $DRY_RUN; then
        log_dry "Would back up services.conf to ${dest}/"
        return
    fi

    mkdir -p "$dest"
    local ts
    ts=$(date '+%Y%m%d_%H%M%S')
    cp "$CONFIG_FILE" "${dest}/services.conf.${ts}"
    log_info "Config backed up to ${dest}/services.conf.${ts}"
}

# ---------- Install ----------

do_install() {
    if [[ "$(id -u)" -ne 0 ]] && ! $DRY_RUN; then
        log_error "Install requires root. Run with sudo."
        exit 1
    fi

    log_info "Loading config..."
    load_config
    validate_config

    if ! $DRY_RUN; then
        mkdir -p "$DATA_DIR" "$LOG_DIR"
    fi

    backup_config

    log_info "Generating health check..."
    generate_health_check_script
    generate_health_check_units

    log_info "Generating failure notification..."
    generate_notify_script

    log_info "Generating log rotation configs..."
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local log_file=$(get_svc_var "$i" "LOG_FILE")
        generate_logrotate "$name" "$log_file"
    done
    generate_memory_csv_logrotate

    log_info "Generating dashboard..."
    generate_dashboard

    save_checksums

    if $DRY_RUN; then
        echo ""
        log_info "Dry run complete. No changes were made."
        return
    fi

    log_info "Reloading systemd..."
    systemctl daemon-reload

    log_info "Enabling health check timer..."
    systemctl enable --now svc-manager-health-check.timer

    if [[ "${DASHBOARD_PORT:-0}" -gt 0 ]]; then
        log_info "Enabling dashboard..."
        systemctl enable --now svc-manager-dashboard.service
    fi

    echo ""
    log_info "Installation complete. (v${VERSION})"
    echo ""
    local svc_list=""
    for i in $(seq 1 "$SERVICE_COUNT"); do
        svc_list+="$(get_svc_var "$i" "NAME") "
    done
    log_info "Monitored:       ${svc_list}"
    log_info "Restart cycle:   every ${RESTART_INTERVAL_DAYS} day(s), ${RESTART_DELAY_SECS}s delay"
    log_info "Health check:    every ${HEALTH_CHECK_INTERVAL}"
    log_info "Memory log:      ${MEMORY_CSV}"
    log_info "CPU threshold:   ${CPU_THRESHOLD}%"
    if [[ -n "${NOTIFY_WEBHOOK_URL}" ]]; then
        log_info "Webhook:         configured"
    fi
    if [[ -n "${NOTIFY_EMAIL}" ]]; then
        log_info "Email:           ${NOTIFY_EMAIL}"
    fi
    if [[ "${DASHBOARD_PORT:-0}" -gt 0 ]]; then
        log_info "Dashboard:       http://$(hostname -I | awk '{print $1}'):${DASHBOARD_PORT}/status"
    fi
    echo ""
    log_info "Programs are NOT managed by systemd. Start/stop them normally."
    log_info "The health check will restart them if they are down."
}

# ---------- Update ----------

do_update() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Update requires root. Run with sudo."
        exit 1
    fi

    log_info "Loading config..."
    load_config
    validate_config
    load_checksums

    mkdir -p "$DATA_DIR" "$LOG_DIR"
    backup_config

    log_info "Regenerating files and diffing checksums..."

    generate_health_check_script
    generate_health_check_units
    generate_notify_script
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local log_file=$(get_svc_var "$i" "LOG_FILE")
        generate_logrotate "$name" "$log_file"
    done
    generate_memory_csv_logrotate
    generate_dashboard

    save_checksums

    systemctl daemon-reload

    # Restart timer if changed
    local hc_old="${SAVED_CHECKSUMS[health-check-timer]:-}"
    local hc_new="${NEW_CHECKSUMS[health-check-timer]:-}"
    if [[ "$hc_old" != "$hc_new" ]]; then
        log_info "Health check timer changed, restarting..."
        systemctl enable --now svc-manager-health-check.timer
        systemctl restart svc-manager-health-check.timer
    else
        log_info "Health check timer unchanged."
    fi

    # Restart dashboard if changed
    if [[ "${DASHBOARD_PORT:-0}" -gt 0 ]]; then
        local db_old="${SAVED_CHECKSUMS[dashboard]:-}"
        local db_new="${NEW_CHECKSUMS[dashboard]:-}"
        if [[ "$db_old" != "$db_new" ]]; then
            log_info "Dashboard changed, restarting..."
            systemctl enable --now svc-manager-dashboard.service
            systemctl restart svc-manager-dashboard.service
        else
            log_info "Dashboard unchanged."
        fi
    fi

    echo ""
    log_info "Update complete. Programs were not restarted."
    log_info "Changes take effect at the next health check."
}

# ---------- Uninstall ----------

do_uninstall() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Uninstall requires root. Run with sudo."
        exit 1
    fi

    load_config
    validate_config

    echo -e "${YELLOW}This will remove the health check, dashboard, and all generated files.${NC}"
    echo -e "${YELLOW}Running programs will NOT be stopped.${NC}"
    read -r -p "Continue? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi

    log_info "Stopping and disabling systemd units..."

    for unit in \
        "svc-manager-health-check.timer" \
        "svc-manager-health-check.service" \
        "svc-manager-dashboard.service"; do
        if systemctl is-active --quiet "$unit" 2>/dev/null; then
            systemctl stop "$unit"
        fi
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            systemctl disable "$unit"
        fi
    done

    log_info "Removing generated files..."

    local files=(
        "${SYSTEMD_DIR}/svc-manager-health-check.service"
        "${SYSTEMD_DIR}/svc-manager-health-check.timer"
        "${SYSTEMD_DIR}/svc-manager-dashboard.service"
        "${BIN_DIR}/svc-manager-health-check.sh"
        "${BIN_DIR}/svc-manager-notify-failure.sh"
        "${BIN_DIR}/svc-manager-dashboard.py"
        "${LOGROTATE_DIR}/svc-manager-memory-csv"
    )

    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        files+=("${LOGROTATE_DIR}/svc-manager-${name}")
    done

    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then rm -f "$f"; log_info "Removed ${f}"; fi
    done

    systemctl daemon-reload

    echo ""
    log_info "Uninstall complete. Running programs were not touched."
    log_info "Preserved: ${CONFIG_FILE}"
    log_info "Preserved: ${LOG_DIR}/ (memory history)"
    log_info "Preserved: ${DATA_DIR}/ (restart timestamps)"
    echo -e "${YELLOW}To remove all data: sudo rm -rf ${LOG_DIR} ${DATA_DIR}${NC}"
}

# ---------- Status ----------

do_status() {
    load_config
    validate_config

    local restart_base_secs=$(( RESTART_INTERVAL_DAYS * 86400 ))

    echo ""
    echo -e "${CYAN}Service Manager v${VERSION}${NC}"
    echo ""
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local path=$(get_svc_var "$i" "PATH")
        local user=$(get_svc_var "$i" "USER" "root")
        local pgrep_pat=$(get_svc_var "$i" "PGREP" "$(basename "$path")")
        local stagger=$(get_svc_var "$i" "STAGGER_HOURS" "0")

        local stagger_secs=$(( stagger * 3600 ))
        local effective_interval=$(( restart_base_secs + stagger_secs ))

        echo -e "${CYAN}── ${name} ──${NC}"

        local restart_days="${RESTART_INTERVAL_DAYS}"
        local delay_mins=$(( RESTART_DELAY_SECS / 60 ))
        echo "  Restart every:  ${restart_days} day(s)"
        echo "  Restart delay:  ${delay_mins} min (${RESTART_DELAY_SECS}s)"
        if [[ "$stagger" -gt 0 ]]; then
            echo "  Stagger:        +${stagger}h offset"
        fi

        local pid
        pid=$(pgrep -u "$user" -f "$pgrep_pat" -n 2>/dev/null || echo "0")

        if [[ "$pid" -gt 0 ]]; then
            echo -e "  State:          ${GREEN}running${NC}"
            echo "  PID:            ${pid}"

            # Memory
            local rss_kb=0
            if [[ -f "/proc/${pid}/status" ]]; then
                rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo "0")
            fi
            local rss_mb=$(( rss_kb / 1024 ))
            echo "  Memory (RSS):   ${rss_mb} MB (${rss_kb} KB)"

            # CPU
            local cpu
            cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0.0")
            echo "  CPU:            ${cpu}%"

            # Uptime from /proc
            local proc_start
            proc_start=$(stat -c %Y "/proc/${pid}" 2>/dev/null || echo "0")
            if [[ "$proc_start" -gt 0 ]]; then
                local now_ts=$(date +%s)
                local uptime_secs=$(( now_ts - proc_start ))
                echo "  Uptime:         $(format_duration $uptime_secs)"
            fi
        else
            echo -e "  State:          ${RED}stopped${NC}"
        fi

        # Next scheduled restart
        local lr_file="${DATA_DIR}/${name}.last_restart"
        if [[ -f "$lr_file" ]]; then
            local last_restart
            last_restart=$(cat "$lr_file")
            local now_ts=$(date +%s)
            local elapsed=$(( now_ts - last_restart ))
            local remaining=$(( effective_interval - elapsed ))
            echo "  Next restart:   $(format_duration $remaining)"
        else
            echo "  Next restart:   pending first check"
        fi

        echo ""
    done

    echo -e "${CYAN}── Health Check Timer ──${NC}"
    local timer_state
    timer_state=$(systemctl is-active "svc-manager-health-check.timer" 2>/dev/null || true)
    echo -e "  State:          ${timer_state}"
    local next_run
    next_run=$(systemctl show -p NextElapseUSecRealtime --value "svc-manager-health-check.timer" 2>/dev/null || echo "n/a")
    if [[ -n "$next_run" && "$next_run" != "n/a" ]]; then
        local next_formatted
        next_formatted=$(date -d "$next_run" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$next_run")
        echo "  Next run:       ${next_formatted}"
    fi

    if [[ "${DASHBOARD_PORT:-0}" -gt 0 ]]; then
        echo ""
        echo -e "${CYAN}── Dashboard ──${NC}"
        local dash_state
        dash_state=$(systemctl is-active "svc-manager-dashboard.service" 2>/dev/null || true)
        echo -e "  State:          ${dash_state}"
        echo "  URL:            http://$(hostname -I 2>/dev/null | awk '{print $1}'):${DASHBOARD_PORT}/status"
    fi

    if [[ -f "$MEMORY_CSV" ]]; then
        echo ""
        echo -e "${CYAN}── Recent Memory History (last 10) ──${NC}"
        tail -n 10 "$MEMORY_CSV" | column -t -s',' 2>/dev/null || tail -n 10 "$MEMORY_CSV"
    fi

    echo ""
}

# ---------- Main ----------

main() {
    local action=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --install)   action="install" ;;
            --uninstall) action="uninstall" ;;
            --update)    action="update" ;;
            --status)    action="status" ;;
            --dry-run)   DRY_RUN=true; action="${action:-install}" ;;
            --verbose)   VERBOSE=true ;;
            --help|-h)   usage ;;
            *)
                log_error "Unknown option: $1"
                usage
                ;;
        esac
        shift
    done

    action="${action:-install}"

    case "$action" in
        install)   do_install ;;
        uninstall) do_uninstall ;;
        update)    do_update ;;
        status)    do_status ;;
    esac
}

main "$@"
