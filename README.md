# Service Manager

Manages Linux services with scheduled restarts, health checks, memory tracking, failure notifications, and a JSON dashboard. Designed for programs with memory leaks running on a Raspberry Pi.

## Features

- **Arbitrary service count** — manage 1 to N services from a single config file
- **Scheduled restarts** — graceful shutdown on a configurable cycle (default: every 3 days) with a configurable delay before restart (default: 5 minutes)
- **Staggered restarts** — per-service hour offset so services don't all restart simultaneously
- **Custom health checks** — optional command per service (HTTP probe, file check, etc); unhealthy services are restarted
- **Memory trend logging** — RSS and CPU recorded to CSV at every health check for graphing leak rates
- **CPU monitoring** — flags services exceeding a configurable CPU threshold
- **Failure notifications** — webhook (Slack/Discord/ntfy) and/or email (msmtp/sendmail)
- **Log rotation** — per-service logrotate configs plus rotation of the memory CSV
- **Pre-shutdown commands** — optional cleanup command per service before SIGTERM
- **Startup ordering** — `AFTER` field for dependency chains between services
- **Memory caps** — systemd `MemoryMax` per service
- **Dry run mode** — preview all generated files and commands without touching the system
- **Update mode** — regenerate files, checksum-diff against previous install, restart only changed services
- **Config backup** — automatic timestamped copy of `services.conf` on install/update
- **JSON dashboard** — lightweight HTTP endpoint serving live status, memory history

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
| `sudo bash setup.sh --install` | Generate all files, enable and start everything |
| `sudo bash setup.sh --uninstall` | Stop, disable, and remove all generated files |
| `sudo bash setup.sh --update` | Regenerate files, restart only services that changed |
| `bash setup.sh --status` | Show state, memory, CPU, uptime, restart countdown |
| `sudo bash setup.sh --dry-run` | Preview install without making changes |
| `sudo bash setup.sh --dry-run --verbose` | Same, but print generated file contents |

## Config Reference

See `services.conf.example` for all fields with descriptions. Key fields per service:

| Field | Required | Description |
|-------|----------|-------------|
| `SERVICE_N_NAME` | Yes | systemd unit name |
| `SERVICE_N_PATH` | Yes | Executable path |
| `SERVICE_N_ARGS` | No | Command-line arguments |
| `SERVICE_N_USER` | No | Run-as user (default: root) |
| `SERVICE_N_WORKDIR` | No | Working directory (default: /) |
| `SERVICE_N_PRE_SHUTDOWN` | No | Command to run before SIGTERM |
| `SERVICE_N_LOG_FILE` | No | Log file path for logrotate |
| `SERVICE_N_MEMORY_MAX` | No | Memory cap (e.g., "512M") |
| `SERVICE_N_HEALTH_CMD` | No | Health check command (exit 0 = healthy) |
| `SERVICE_N_AFTER` | No | Name of service this depends on |
| `SERVICE_N_STAGGER_HOURS` | No | Hours offset from base restart cycle |

## Generated Files

| File | Location |
|------|----------|
| Service units | `/etc/systemd/system/<name>.service` |
| Health check script | `/usr/local/bin/svc-manager-health-check.sh` |
| Health check timer | `/etc/systemd/system/svc-manager-health-check.timer` |
| Notify script | `/usr/local/bin/svc-manager-notify-failure.sh` |
| Notify template | `/etc/systemd/system/svc-manager-notify@.service` |
| Dashboard script | `/usr/local/bin/svc-manager-dashboard.py` |
| Dashboard unit | `/etc/systemd/system/svc-manager-dashboard.service` |
| Logrotate configs | `/etc/logrotate.d/svc-manager-*` |
| Memory CSV | `/var/log/svc-manager/memory.csv` |
| Checksums | `/var/lib/svc-manager/checksums` |

`--uninstall` removes all generated files. Memory CSV and checksums are preserved (printed path to delete manually).

## Dashboard

Set `DASHBOARD_PORT` to a non-zero value in your config. Endpoints:

- `GET /status` — JSON with current state, PID, RSS, CPU, uptime, and seconds until next restart for each service
- `GET /memory` — last 100 rows from the memory trend CSV

The response includes `Access-Control-Allow-Origin: *` so it can be consumed by Home Assistant REST sensors or any frontend.

## Useful Commands

```bash
# View logs for a service
journalctl -u myapp1 -f

# View last health check output
journalctl -u svc-manager-health-check.service --since "2 hours ago"

# Manually trigger a health check
sudo systemctl start svc-manager-health-check.service

# Check timer schedule
systemctl list-timers svc-manager-health-check.timer

# View memory trend
column -t -s',' /var/log/svc-manager/memory.csv | tail -20
```

## Adding a Service

1. Increment `SERVICE_COUNT` in `services.conf`
2. Add the `SERVICE_N_*` block with the new index
3. Run `sudo bash setup.sh --update`

Only the new service will be started. Existing unchanged services are not restarted.

## Notes

- **Back up `services.conf` separately.** It is gitignored. Use `CONFIG_BACKUP_DIR` for automatic copies, and also store it in a password manager or encrypted note.
- **SD card wear.** If either program does heavy writes, point its working directory to a USB drive or tmpfs.
- **RuntimeMaxSec** counts from service start, not wall clock. The restart cycle resets after any restart (scheduled, health check, crash). Stagger offsets are additive to the base interval.
- **Re-running `--install`** overwrites all generated files and restarts everything. Use `--update` to avoid unnecessary restarts.
- **CPU threshold** is informational only — it logs and flags but does not restart. Adjust `CPU_THRESHOLD` in config if needed.
- **Webhook payload** sends `{"text": "..."}`. Works with Slack, Discord (`/slack` endpoint), ntfy. Edit the generated notify script for other formats.
