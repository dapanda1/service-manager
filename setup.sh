#!/bin/bash
set -euo pipefail

# ============================================================================
# Service Manager Setup Script (v2)
#
# Features:
#   - Arbitrary number of managed services
#   - Scheduled graceful restarts via RuntimeMaxSec
#   - Staggered restart offsets per service
#   - Health checks with optional custom commands per service
#   - Memory trend logging to CSV
#   - CPU usage monitoring
#   - Failure notifications (webhook + optional email)
#   - Log rotation for service log files
#   - Pre-shutdown commands per service
#   - Startup ordering dependencies
#   - Dry run mode
#   - Update mode with checksum diffing
#   - Automatic config backup on install
#   - Lightweight JSON dashboard endpoint
#   - flock-based overlap prevention
# ============================================================================

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
Usage: $0 [OPTION]

Options:
  --install       Install and enable all services (default)
  --uninstall     Stop, disable, and remove all generated files
  --update        Regenerate files, only restart services that changed
  --status        Show service status, memory, and restart countdown
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

run_cmd() {
    local desc="$1"
    shift
    if $DRY_RUN; then
        log_dry "Would run: $*"
        return
    fi
    "$@"
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
        local name
        name=$(get_svc_var "$i" "NAME")
        local path
        path=$(get_svc_var "$i" "PATH")

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

        local after
        after=$(get_svc_var "$i" "AFTER")
        if [[ -n "$after" ]]; then
            local dep_found=false
            for j in $(seq 1 "$count"); do
                if [[ "$(get_svc_var "$j" "NAME")" == "$after" ]]; then
                    dep_found=true
                    break
                fi
            done
            if ! $dep_found; then
                log_error "SERVICE_${i}_AFTER references unknown service: ${after}"
                errors=1
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

generate_service_unit() {
    local index="$1"
    local name=$(get_svc_var "$index" "NAME")
    local path=$(get_svc_var "$index" "PATH")
    local args=$(get_svc_var "$index" "ARGS")
    local user=$(get_svc_var "$index" "USER" "root")
    local workdir=$(get_svc_var "$index" "WORKDIR" "/")
    local pre_shutdown=$(get_svc_var "$index" "PRE_SHUTDOWN")
    local memory_max=$(get_svc_var "$index" "MEMORY_MAX")
    local after=$(get_svc_var "$index" "AFTER")
    local stagger_hours=$(get_svc_var "$index" "STAGGER_HOURS" "0")

    local base_secs=$(( RESTART_INTERVAL_DAYS * 86400 ))
    local offset_secs=$(( stagger_hours * 3600 ))
    local runtime_max=$(( base_secs + offset_secs ))
    local unit_file="${SYSTEMD_DIR}/${name}.service"

    local content="[Unit]
Description=Managed service: ${name}"

    if [[ -n "$after" ]]; then
        content+="
After=network.target ${after}.service
Requires=${after}.service"
    else
        content+="
After=network.target"
    fi

    content+="
OnFailure=svc-manager-notify@%n.service

[Service]
Type=simple
User=${user}
WorkingDirectory=${workdir}
ExecStart=${path}${args:+ ${args}}"

    if [[ -n "$pre_shutdown" ]]; then
        content+="
ExecStop=/bin/bash -c '${pre_shutdown}; kill -TERM \$MAINPID'"
    fi

    content+="
Restart=always
RestartSec=${RESTART_DELAY_SECS}
RuntimeMaxSec=${runtime_max}
TimeoutStopSec=30
KillMode=mixed
KillSignal=SIGTERM"

    if [[ -n "$memory_max" ]]; then
        content+="
MemoryMax=${memory_max}"
    fi

    content+="

[Install]
WantedBy=multi-user.target"

    NEW_CHECKSUMS["$name"]=$(compute_checksum "$content")
    write_file "$unit_file" "$content"
}

generate_health_check_script() {
    local count="${SERVICE_COUNT}"
    local script_path="${BIN_DIR}/svc-manager-health-check.sh"

    local names_arr=""
    local health_cmds_arr=""
    for i in $(seq 1 "$count"); do
        local name=$(get_svc_var "$i" "NAME")
        local hcmd=$(get_svc_var "$i" "HEALTH_CMD")
        names_arr+="\"${name}\" "
        health_cmds_arr+="\"${hcmd}\" "
    done

    local content='#!/bin/bash
set -euo pipefail

LOCK_FILE="/tmp/svc-manager-health-check.lock"
MEMORY_CSV="'"${MEMORY_CSV}"'"
CPU_THRESHOLD="'"${CPU_THRESHOLD}"'"

SERVICES=('"${names_arr}"')
HEALTH_CMDS=('"${health_cmds_arr}"')

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo "$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"') Health check already running, skipping."
    exit 0
fi

mkdir -p "$(dirname "$MEMORY_CSV")"

if [[ ! -f "$MEMORY_CSV" ]]; then
    echo "timestamp,service,pid,rss_kb,cpu_pct,status" > "$MEMORY_CSV"
fi

TS="$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')"

for idx in "${!SERVICES[@]}"; do
    svc="${SERVICES[$idx]}"
    hcmd="${HEALTH_CMDS[$idx]}"
    pid="0"
    rss="0"
    cpu="0.0"
    status="unknown"

    if systemctl is-active --quiet "$svc"; then
        pid=$(systemctl show -p MainPID --value "$svc" 2>/dev/null || echo "0")

        if [[ "$pid" -gt 0 ]] && [[ -d "/proc/${pid}" ]]; then
            rss=$(awk '"'"'/VmRSS/ {print $2}'"'"' "/proc/${pid}/status" 2>/dev/null || echo "0")
            cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d '"'"' '"'"' || echo "0.0")
        fi

        # Custom health check
        if [[ -n "$hcmd" ]]; then
            if eval "$hcmd" >/dev/null 2>&1; then
                status="healthy"
            else
                status="unhealthy"
                echo "${TS} ${svc} health command failed. Restarting..."
                systemctl restart "$svc"
                status="restarted_health_fail"
            fi
        else
            status="running"
        fi

        # CPU threshold check
        cpu_int=${cpu%%.*}
        if [[ "${cpu_int:-0}" -ge "$CPU_THRESHOLD" ]]; then
            echo "${TS} ${svc} CPU at ${cpu}% (threshold: ${CPU_THRESHOLD}%). Flagging."
            status="high_cpu"
            logger -t svc-manager "${svc} CPU usage at ${cpu}% exceeds threshold ${CPU_THRESHOLD}%"
        fi
    else
        status="down"
        echo "${TS} ${svc} is not running. Restarting..."
        systemctl restart "$svc"
        if systemctl is-active --quiet "$svc"; then
            echo "${TS} ${svc} restarted successfully."
            status="restarted"
        else
            echo "${TS} ${svc} failed to restart."
            status="restart_failed"
        fi
    fi

    echo "${TS},${svc},${pid},${rss},${cpu},${status}" >> "$MEMORY_CSV"
    echo "${TS} ${svc}: pid=${pid} rss=${rss}KB cpu=${cpu}% status=${status}"
done'

    NEW_CHECKSUMS["health-check"]=$(compute_checksum "$content")
    write_file "$script_path" "$content" "755"
}

generate_health_check_units() {
    local svc_file="${SYSTEMD_DIR}/svc-manager-health-check.service"
    local timer_file="${SYSTEMD_DIR}/svc-manager-health-check.timer"

    local svc_content="[Unit]
Description=Health check for managed services

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/svc-manager-health-check.sh"

    local timer_content="[Unit]
Description=Health check timer for managed services

[Timer]
OnBootSec=5min
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

FAILED_UNIT="${1:-unknown}"
TIMESTAMP="$(date '"'"'+%Y-%m-%d %H:%M:%S'"'"')"
HOSTNAME="$(hostname)"
MESSAGE="[svc-manager] ${FAILED_UNIT} failed on ${HOSTNAME} at ${TIMESTAMP}"

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

generate_notify_unit() {
    local unit_file="${SYSTEMD_DIR}/svc-manager-notify@.service"

    local content="[Unit]
Description=Failure notification for %i

[Service]
Type=oneshot
ExecStart=${BIN_DIR}/svc-manager-notify-failure.sh %i"

    NEW_CHECKSUMS["notify-unit"]=$(compute_checksum "$content")
    write_file "$unit_file" "$content"
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

    local py_names="["
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        if [[ "$i" -gt 1 ]]; then py_names+=", "; fi
        py_names+="\"${name}\""
    done
    py_names+="]"

    local restart_base_secs=$(( RESTART_INTERVAL_DAYS * 86400 ))

    local py_staggers="{"
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local stagger=$(get_svc_var "$i" "STAGGER_HOURS" "0")
        if [[ "$i" -gt 1 ]]; then py_staggers+=", "; fi
        py_staggers+="\"${name}\": ${stagger}"
    done
    py_staggers+="}"

    local py_content="#!/usr/bin/env python3
\"\"\"Lightweight JSON status dashboard for svc-manager.\"\"\"

import http.server
import json
import subprocess
import os
import time
from datetime import datetime

PORT = ${port}
SERVICES = ${py_names}
RESTART_BASE_SECS = ${restart_base_secs}
STAGGER_HOURS = ${py_staggers}
MEMORY_CSV = \"${MEMORY_CSV}\"


def get_service_info(name):
    info = {
        \"name\": name, \"state\": \"unknown\", \"pid\": 0,
        \"rss_kb\": 0, \"cpu_pct\": 0.0, \"uptime_secs\": 0,
        \"restart_in_secs\": 0
    }

    try:
        r = subprocess.run([\"systemctl\", \"is-active\", name],
                           capture_output=True, text=True, timeout=5)
        info[\"state\"] = r.stdout.strip()
    except Exception:
        return info

    if info[\"state\"] != \"active\":
        return info

    try:
        r = subprocess.run([\"systemctl\", \"show\", \"-p\", \"MainPID\", \"--value\", name],
                           capture_output=True, text=True, timeout=5)
        pid = int(r.stdout.strip())
        info[\"pid\"] = pid

        if pid > 0 and os.path.isfile(f\"/proc/{pid}/status\"):
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

    try:
        r = subprocess.run([\"systemctl\", \"show\", \"-p\", \"ActiveEnterTimestamp\",
                            \"--value\", name],
                           capture_output=True, text=True, timeout=5)
        ts_str = r.stdout.strip()
        if ts_str:
            # Parse systemd timestamp format
            for fmt in (\"%a %Y-%m-%d %H:%M:%S %Z\", \"%Y-%m-%d %H:%M:%S %Z\"):
                try:
                    start = datetime.strptime(ts_str, fmt)
                    break
                except ValueError:
                    continue
            else:
                start = None

            if start:
                uptime = int(time.time() - start.timestamp())
                info[\"uptime_secs\"] = uptime
                stagger_secs = STAGGER_HOURS.get(name, 0) * 3600
                runtime_max = RESTART_BASE_SECS + stagger_secs
                info[\"restart_in_secs\"] = max(0, runtime_max - uptime)
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
                \"timestamp\": datetime.now().isoformat(),
                \"services\": [get_service_info(s) for s in SERVICES],
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

    log_info "Generating service units..."
    for i in $(seq 1 "$SERVICE_COUNT"); do
        generate_service_unit "$i"
    done

    log_info "Generating health check..."
    generate_health_check_script
    generate_health_check_units

    log_info "Generating failure notification..."
    generate_notify_script
    generate_notify_unit

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

    log_info "Enabling and starting services..."
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        systemctl enable --now "${name}.service"
    done
    systemctl enable --now svc-manager-health-check.timer

    if [[ "${DASHBOARD_PORT:-0}" -gt 0 ]]; then
        systemctl enable --now svc-manager-dashboard.service
    fi

    echo ""
    log_info "Installation complete."
    echo ""
    local svc_list=""
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local n=$(get_svc_var "$i" "NAME")
        svc_list+="${n} "
    done
    log_info "Services:        ${svc_list}"
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

    for i in $(seq 1 "$SERVICE_COUNT"); do
        generate_service_unit "$i"
    done
    generate_health_check_script
    generate_health_check_units
    generate_notify_script
    generate_notify_unit
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local log_file=$(get_svc_var "$i" "LOG_FILE")
        generate_logrotate "$name" "$log_file"
    done
    generate_memory_csv_logrotate
    generate_dashboard

    save_checksums

    systemctl daemon-reload

    local restarted=0
    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        local old="${SAVED_CHECKSUMS[$name]:-}"
        local new="${NEW_CHECKSUMS[$name]:-}"

        if [[ "$old" != "$new" ]]; then
            log_info "${name}: unit changed, restarting..."
            systemctl enable --now "${name}.service"
            systemctl restart "${name}.service"
            restarted=$(( restarted + 1 ))
        else
            log_info "${name}: unchanged, skipping restart."
        fi
    done

    local hc_old="${SAVED_CHECKSUMS[health-check-timer]:-}"
    local hc_new="${NEW_CHECKSUMS[health-check-timer]:-}"
    if [[ "$hc_old" != "$hc_new" ]]; then
        log_info "Health check timer changed, restarting..."
        systemctl enable --now svc-manager-health-check.timer
        systemctl restart svc-manager-health-check.timer
    fi

    if [[ "${DASHBOARD_PORT:-0}" -gt 0 ]]; then
        local db_old="${SAVED_CHECKSUMS[dashboard]:-}"
        local db_new="${NEW_CHECKSUMS[dashboard]:-}"
        if [[ "$db_old" != "$db_new" ]]; then
            log_info "Dashboard changed, restarting..."
            systemctl enable --now svc-manager-dashboard.service
            systemctl restart svc-manager-dashboard.service
        fi
    fi

    echo ""
    log_info "Update complete. ${restarted} service(s) restarted."
}

# ---------- Uninstall ----------

do_uninstall() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "Uninstall requires root. Run with sudo."
        exit 1
    fi

    load_config
    validate_config

    echo -e "${YELLOW}This will stop and remove all managed services and generated files.${NC}"
    read -r -p "Continue? [y/N] " confirm
    if [[ "${confirm,,}" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi

    log_info "Stopping and disabling services..."

    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        if systemctl is-active --quiet "${name}.service" 2>/dev/null; then
            systemctl stop "${name}.service"
        fi
        if systemctl is-enabled --quiet "${name}.service" 2>/dev/null; then
            systemctl disable "${name}.service"
        fi
    done

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

    for i in $(seq 1 "$SERVICE_COUNT"); do
        local name=$(get_svc_var "$i" "NAME")
        for f in "${SYSTEMD_DIR}/${name}.service" "${LOGROTATE_DIR}/svc-manager-${name}"; do
            if [[ -f "$f" ]]; then rm -f "$f"; log_info "Removed ${f}"; fi
        done
    done

    local infra_files=(
        "${SYSTEMD_DIR}/svc-manager-health-check.service"
        "${SYSTEMD_DIR}/svc-manager-health-check.timer"
        "${SYSTEMD_DIR}/svc-manager-notify@.service"
        "${SYSTEMD_DIR}/svc-manager-dashboard.service"
        "${BIN_DIR}/svc-manager-health-check.sh"
        "${BIN_DIR}/svc-manager-notify-failure.sh"
        "${BIN_DIR}/svc-manager-dashboard.py"
        "${LOGROTATE_DIR}/svc-manager-memory-csv"
    )

    for f in "${infra_files[@]}"; do
        if [[ -f "$f" ]]; then rm -f "$f"; log_info "Removed ${f}"; fi
    done

    systemctl daemon-reload

    echo ""
    log_info "Uninstall complete."
    log_info "Preserved: ${CONFIG_FILE}"
    log_info "Preserved: ${LOG_DIR}/ (memory history)"
    log_info "Preserved: ${DATA_DIR}/ (checksums)"
    echo -e "${YELLOW}To remove all data: sudo rm -rf ${LOG_DIR} ${DATA_DIR}${NC}"
}

# ---------- Status ----------

print_service_status() {
    local index="$1"
    local name=$(get_svc_var "$index" "NAME")
    local stagger=$(get_svc_var "$index" "STAGGER_HOURS" "0")
    local base_secs=$(( RESTART_INTERVAL_DAYS * 86400 ))
    local offset_secs=$(( stagger * 3600 ))
    local runtime_max=$(( base_secs + offset_secs ))

    echo -e "${CYAN}── ${name} ──${NC}"

    local state
    state=$(systemctl is-active "$name" 2>/dev/null || true)

    if [[ "$state" == "active" ]]; then
        echo -e "  State:          ${GREEN}${state}${NC}"
    elif [[ "$state" == "failed" ]]; then
        echo -e "  State:          ${RED}${state}${NC}"
    else
        echo -e "  State:          ${YELLOW}${state}${NC}"
    fi

    local pid
    pid=$(systemctl show -p MainPID --value "$name" 2>/dev/null || echo "0")
    if [[ "$pid" -gt 0 ]] && [[ -f "/proc/${pid}/status" ]]; then
        local rss_kb
        rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/${pid}/status" 2>/dev/null || echo "0")
        local rss_mb=$(( rss_kb / 1024 ))
        echo "  PID:            ${pid}"
        echo "  Memory (RSS):   ${rss_mb} MB (${rss_kb} KB)"

        local cpu
        cpu=$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ' || echo "0.0")
        echo "  CPU:            ${cpu}%"
    else
        echo "  Memory (RSS):   n/a"
        echo "  CPU:            n/a"
    fi

    if [[ "$state" == "active" ]]; then
        local start_str
        start_str=$(systemctl show -p ActiveEnterTimestamp --value "$name" 2>/dev/null || echo "")
        if [[ -n "$start_str" ]]; then
            local start_ts
            start_ts=$(date -d "$start_str" +%s 2>/dev/null || echo "0")
            local now_ts
            now_ts=$(date +%s)
            local uptime_secs=$(( now_ts - start_ts ))
            local remaining=$(( runtime_max - uptime_secs ))
            echo "  Uptime:         $(format_duration $uptime_secs)"
            echo "  Next restart:   $(format_duration $remaining)"
            if [[ "$stagger" -gt 0 ]]; then
                echo "  Stagger:        +${stagger}h offset"
            fi
        fi
    fi

    echo ""
}

do_status() {
    load_config
    validate_config

    echo ""
    for i in $(seq 1 "$SERVICE_COUNT"); do
        print_service_status "$i"
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
