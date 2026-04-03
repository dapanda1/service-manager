# Service Manager (v2.0.0)

Monitors Linux programs with scheduled restarts, health checks, memory tracking, failure notifications, and a JSON dashboard. Designed for programs with memory leaks running on a Raspberry Pi.

## How it works

**This is a monitor, not a service manager.** Programs are started and stopped normally — click the icon, use the taskbar, right-click to close. The health check timer runs every 2 hours (configurable) and:

1. If a program isn't running, it starts it.
2. If a program has been running longer than the restart interval (default: 3 days), it gracefully stops it, waits 5 minutes, and starts it again.
3. Logs memory (RSS) and CPU for each program to a CSV file for trend analysis.
4. Sends a webhook/email notification if a program fails to start.

You stay in full control. Close a program from the GUI at 2pm — the health check at 3pm brings it back. That's the intended behavior.

## Features

- **Arbitrary program count** — manage 1 to N programs from a single config
- **Scheduled restarts** — graceful shutdown on a configurable cycle with configurable delay
- **Staggered restarts** — per-program hour offset so they don't all restart at once
- **Custom health checks** — optional command per program (HTTP probe, file check, etc)
- **Memory trend logging** — RSS and CPU recorded to CSV every health check
- **Memory caps** — restarts a program if RSS exceeds a configured limit
- **CPU monitoring** — flags programs exceeding a configurable CPU threshold
- **Failure notifications** — webhook (Slack/Discord/ntfy) and/or email (msmtp/sendmail)
- **Log rotation** — per-program logrotate configs plus rotation of the memory CSV
- **Pre-shutdown commands** — optional cleanup command before SIGTERM
- **Dry run mode** — preview all generated files without touching the system
- **Update mode** — regenerate files with checksum diffing, no program restarts
- **Config backup** — automatic timestamped copy of services.conf on install/update
- **JSON dashboard** — lightweight HTTP endpoint serving live status and memory history
- **GUI compatible** — works with programs running in X11/VNC desktop sessions

## Quick Start

```bash
# Clone and configure
git clone <your-repo-url>
cd service-manager
cp services.conf.example services.conf
nano services.conf

# Preview what will be created
sudo bash setup.sh --dry-run --verbose

# Install
sudo bash setup.sh --install
```

## Commands

| Command | Description |
|---------|-------------|
| `sudo bash setup.sh --install` | Generate all files, enable health check timer and dashboard |
| `sudo bash setup.sh --uninstall` | Remove all generated files (running programs are not touched) |
| `sudo bash setup.sh --update` | Regenerate files, restart only components that changed |
| `bash setup.sh --status` | Show state, PID, memory, CPU, uptime, restart countdown |
| `sudo bash setup.sh --dry-run` | Preview install without making changes |
| `sudo bash setup.sh --dry-run --verbose` | Same, but print generated file contents |

## Config Reference

See `services.conf.example` for all fields with descriptions.

| Field | Required | Description |
|-------|----------|-------------|
| `SERVICE_N_NAME` | Yes | Display name for logging and data files |
| `SERVICE_N_PATH` | Yes | Full path to the executable |
| `SERVICE_N_ARGS` | No | Command-line arguments |
| `SERVICE_N_USER` | No | User to run as (default: root) |
| `SERVICE_N_ENV` | No | Environment variables, semicolon-separated (e.g., "DISPLAY=:0") |
| `SERVICE_N_PGREP` | No | Pattern for pgrep detection (default: basename of PATH) |
| `SERVICE_N_PRE_SHUTDOWN` | No | Command to run before SIGTERM |
| `SERVICE_N_LOG_FILE` | No | Log file path for logrotate |
| `SERVICE_N_MEMORY_MAX` | No | Memory cap — restart if exceeded (e.g., "512M") |
| `SERVICE_N_HEALTH_CMD` | No | Health check command (exit 0 = healthy) |
| `SERVICE_N_STAGGER_HOURS` | No | Hours offset from base restart cycle |

## Generated Files

| File | Location |
|------|----------|
| Health check script | `/usr/local/bin/svc-manager-health-check.sh` |
| Health check service | `/etc/systemd/system/svc-manager-health-check.service` |
| Health check timer | `/etc/systemd/system/svc-manager-health-check.timer` |
| Notify script | `/usr/local/bin/svc-manager-notify-failure.sh` |
| Dashboard script | `/usr/local/bin/svc-manager-dashboard.py` |
| Dashboard unit | `/etc/systemd/system/svc-manager-dashboard.service` |
| Logrotate configs | `/etc/logrotate.d/svc-manager-*` |
| Memory CSV | `/var/log/svc-manager/memory.csv` |
| Restart timestamps | `/var/lib/svc-manager/<name>.last_restart` |
| Checksums | `/var/lib/svc-manager/checksums` |

No systemd service units are created for the managed programs.

## Dashboard

Set `DASHBOARD_PORT` to a non-zero value. Endpoints:

- `GET /status` — JSON with state, PID, RSS, CPU, uptime, seconds until next restart
- `GET /memory` — last 100 rows from the memory trend CSV

CORS enabled. Can be consumed by Home Assistant REST sensors or any HTTP client.

## Useful Commands

```bash
# View last health check output
journalctl -u svc-manager-health-check.service --since "2 hours ago"

# Manually trigger a health check now
sudo systemctl start svc-manager-health-check.service

# Check timer schedule
systemctl list-timers svc-manager-health-check.timer

# View memory trend
column -t -s',' /var/log/svc-manager/memory.csv | tail -20

# Reset a program's restart timer (delays next scheduled restart)
echo $(date +%s) | sudo tee /var/lib/svc-manager/<name>.last_restart
```

## Adding a Program

1. Increment `SERVICE_COUNT` in `services.conf`
2. Add the `SERVICE_N_*` block
3. Run `sudo bash setup.sh --update`

The new program will be picked up at the next health check.

## Home Assistant Integration

The dashboard and notification system can integrate with a Home Assistant instance on a separate machine. Two directions: HA pulls status from the Pi, and the Pi pushes failure alerts to HA.

### REST Sensors (HA pulls from Pi)

Set `DASHBOARD_PORT` to a non-zero value in `services.conf` (e.g., `8099`). Then add the following to HA's `configuration.yaml`, replacing `<pi-ip>` with the Pi's IP address and adjusting the service array indices for your setup:

```yaml
rest:
  - resource: http://<pi-ip>:8099/status
    scan_interval: 120
    sensor:
      - name: "Service 1 State"
        value_template: "{{ value_json.services[0].state }}"
      - name: "Service 1 Memory MB"
        value_template: "{{ (value_json.services[0].rss_kb / 1024) | round(1) }}"
        unit_of_measurement: "MB"
      - name: "Service 1 CPU"
        value_template: "{{ value_json.services[0].cpu_pct }}"
        unit_of_measurement: "%"
      - name: "Service 1 Restart In"
        value_template: "{{ (value_json.services[0].restart_in_secs / 3600) | round(1) }}"
        unit_of_measurement: "hours"
      - name: "Service 2 State"
        value_template: "{{ value_json.services[1].state }}"
      - name: "Service 2 Memory MB"
        value_template: "{{ (value_json.services[1].rss_kb / 1024) | round(1) }}"
        unit_of_measurement: "MB"
      - name: "Service 2 CPU"
        value_template: "{{ value_json.services[1].cpu_pct }}"
        unit_of_measurement: "%"
      - name: "Service 2 Restart In"
        value_template: "{{ (value_json.services[1].restart_in_secs / 3600) | round(1) }}"
        unit_of_measurement: "hours"
```

This creates sensor entities in HA that update every 2 minutes. Use them in dashboard cards, history graphs, or automations (e.g., notify if state != "running").

Additional fields available per service: `restart_interval_days`, `restart_delay_secs`, `stagger_hours`, `effective_interval_secs`, `uptime_secs`, `pid`.

### Failure Notifications (Pi pushes to HA)

Create a webhook automation in HA:

1. In HA, go to **Settings → Automations → Create Automation**
2. Trigger type: **Webhook**
3. Set a webhook ID (e.g., `svc-manager-failure`)
4. Action: send a push notification, turn on a light, whatever you want

Then set `NOTIFY_WEBHOOK_URL` in `services.conf` on the Pi:

```
NOTIFY_WEBHOOK_URL="http://<ha-ip>:8123/api/webhook/svc-manager-failure"
```

Run `sudo bash setup.sh --update`. The Pi will POST to that URL whenever a program fails to start after a health check.

### Memory History

The `/memory` endpoint returns the last 100 rows of the memory trend CSV as JSON. This can be used with HA's REST sensor or polled by an external tool to build long-term memory graphs.

## Notes

- **Back up `services.conf` separately.** It is gitignored. Use `CONFIG_BACKUP_DIR` for automatic copies.
- **SD card wear.** If a program does heavy writes, point its working directory to a USB drive or tmpfs.
- **Restart timer** counts from the last restart timestamp in `/var/lib/svc-manager/<name>.last_restart`. Manually closing and reopening a program does NOT reset this timer — only a scheduled restart or a health-check-triggered restart does.
- **Manually closed programs** come back at the next health check (within 2 hours by default). This is intentional.
- **The 5-minute delay** only applies to scheduled restarts (memory leak cycle). If a program is found down during a regular health check, it is restarted immediately.
- **PGREP pattern** defaults to the basename of PATH. Override it if the running process name differs from the binary name (e.g., Java apps where the process shows as `java` not `myapp`).
