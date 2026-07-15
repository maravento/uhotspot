#!/bin/bash
# maravento.com
#
################################################################################
#
# uwatch — UniFi Hotspot Services Watchdog (optional)
#
# DESCRIPTION:
#   Runs every 5 minutes via cron. Watches every service uhotspot depends on
#   and restarts whichever one is down. Each service check is fully
#   independent — one check's failure/fix never skips or blocks the others
#   in the same run (unlike a naive watchdog that exits after the first fix).
#
#   Checks performed, every run:
#   1. uhotspotd.service — always.
#   2. ualert.service — only if installed (optional component of uhotspot;
#      silently skipped if its unit file isn't present).
#   3. UniFi backend — branches on UNIFI_TYPE from uhotspot.conf:
#      - "unifi-os": uosserver.service only (process/PID alive). UOS Server
#        is an all-in-one container that bundles its own MongoDB internally
#        (confirmed 2026-07-12 by inspecting the running container: no host
#        -level mongod.service is part of this architecture). A standalone
#        mongod.service found running alongside UOS Server is very likely a
#        leftover from a previous classic install and is not monitored here.
#      - "classic": unifi.service only (ports 8443/8080 alive), no separate
#        Mongo check. Confirmed 2026-07-13 on a real classic install (UniFi
#        Network 10.5.54): unifi.service ships with
#        UNIFI_MONGODB_SERVICE_ENABLED=false by default, so it manages its
#        own embedded MongoDB subprocess (127.0.0.1:27117) end-to-end,
#        including its own shutdown logic — the mongodb-org-server
#        package's own mongod.service unit is never started and its data
#        directory stays empty. Same all-in-one shape as unifi-os above,
#        so restarting unifi.service already covers a Mongo failure too.
#
#   Standalone — never reads or modifies uhotspotd.sh, only manages services
#   via systemctl. Independent of the user's own system-wide service
#   watchdog (if any); this one only knows about uhotspot's own dependencies.
#
# USAGE:
#   sudo ./uwatch.sh install      Deploy to /etc/uhotspot/tools/uwatch.sh,
#                                  register cron entry (*/5 * * * *)
#   sudo ./uwatch.sh uninstall    Remove the cron entry
#   uwatch.sh                     Run the checks directly (what cron invokes)
#   uwatch.sh -h, --help          Show this help
#
# CONFIG:  /etc/uhotspot/uhotspot.conf   (reads UNIFI_TYPE)
# LOG:     /var/log/uwatch.log
#
################################################################################

TARGET="/etc/uhotspot/tools/uwatch.sh"
log_file="/var/log/uwatch.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

usage() {
    sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
}

case "${1:-}" in
    -h|--help)
        usage
        ;;
esac

## root check
if [ "$(id -u)" != "0" ]; then
    log "ERROR: This script must be run as root"
    exit 1
fi

# prevent overlapping runs
SCRIPT_LOCK="/var/lock/$(basename "$0" .sh).lock"
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "Script $(basename "$0") is already running"
    exit 1
fi

install_module() {
    echo ""
    echo "=================================="
    echo "Installing uwatch (uhotspot services watchdog)"
    echo "=================================="
    echo ""

    SELF="$(readlink -f "$0")"
    if [[ "$SELF" != "$TARGET" ]]; then
        echo "Deploying script to $TARGET..."
        mkdir -p "$(dirname "$TARGET")"
        install -m 755 -o root -g root "$SELF" "$TARGET"
    fi

    local cron_entry="*/5 * * * * $TARGET"
    local current
    current=$(crontab -l 2>/dev/null || true)
    if echo "$current" | grep -qF "$TARGET"; then
        echo "Cron entry already present — leaving it untouched."
    else
        { printf '%s\n%s\n' "$current" "$cron_entry"; } | crontab -
        echo "Cron entry registered: $cron_entry"
    fi

    echo ""
    echo "✓ Installed. First run happens on the next 5-minute mark."
    echo "  Check the log with: tail -f $log_file"
    echo ""
}

uninstall_module() {
    echo "Removing uwatch cron entry..."
    if crontab -l 2>/dev/null | grep -qF "$TARGET"; then
        crontab -l 2>/dev/null | grep -vF "$TARGET" | crontab -
        echo "✓ Cron entry removed. $TARGET was left in place — delete it manually if desired."
    else
        echo "No cron entry found for $TARGET."
    fi
}

case "${1:-}" in
    install)
        install_module
        exit 0
        ;;
    uninstall)
        uninstall_module
        exit 0
        ;;
esac

# ── Checks (default action — this is what cron runs) ──────────────────────────

# Load UNIFI_TYPE from uhotspot.conf. Safe key=value parsing - file is never
# sourced to prevent code execution.
_UHOTSPOT_CONF="/etc/uhotspot/uhotspot.conf"
_load_conf() {
    local file="$1" key value
    [[ ! -f "$file" ]] && { log "WARNING: $file not found - using built-in defaults"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$line" =~ ^[[:space:]]*$    ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            UNIFI_TYPE)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}
_load_conf "$_UHOTSPOT_CONF"
UNIFI_TYPE="${UNIFI_TYPE:-unifi-os}"

log "uwatch start..."

check_uhotspotd() {
    if systemctl is-active --quiet uhotspotd.service; then
        log "ONLINE: uhotspotd"
    else
        log "WARNING: uhotspotd OFFLINE"
        systemctl restart uhotspotd.service
        log "uhotspotd FIX (restarted)"
    fi
}

check_ualert() {
    # Optional component — if it was never installed, there's nothing to
    # watch and nothing to fix. Not a failure, just skip silently.
    if [[ ! -f /etc/systemd/system/ualert.service ]]; then
        return
    fi
    if systemctl is-active --quiet ualert.service; then
        log "ONLINE: ualert"
    else
        log "WARNING: ualert OFFLINE"
        systemctl restart ualert.service
        log "ualert FIX (restarted)"
    fi
}

check_uosserver() {
    # All-in-one container — its internal MongoDB is bundled and managed by
    # the container itself, never a host-level service. Do not check/restart
    # any standalone mongod.service here; it is not part of this
    # architecture and restarting uosserver.service for an unrelated host
    # Mongo issue is exactly what caused a real outage on 2026-07-12.
    if ! systemctl is-active --quiet uosserver.service; then
        log "WARNING: UOS OFFLINE"
        systemctl start uosserver.service
        log "UOS FIX (start)"
        return
    fi

    local pid
    pid=$(pgrep -of "uosserver-service" || true)
    if [[ -z "$pid" ]]; then
        log "WARNING: UOS BROKEN_NO_PROCESS"
        systemctl restart uosserver.service
        log "UOS FIX (no process)"
        return
    fi
    if ! ps -p "$pid" > /dev/null 2>&1; then
        log "WARNING: UOS BROKEN_DEAD_PID"
        systemctl restart uosserver.service
        log "UOS FIX (dead pid)"
        return
    fi

    log "ONLINE: UOS"
}

check_unifi_classic() {
    if ! systemctl is-active --quiet unifi.service; then
        log "WARNING: UniFi (classic) OFFLINE"
        systemctl start unifi.service
        log "UniFi (classic) FIX (start)"
        return
    fi

    # Port check only: 8443 (GUI/API), 8080 (device inform).
    if ! ss -lnt | grep -qE ':(8443|8080)\b'; then
        log "WARNING: UniFi (classic) BROKEN_PORTS"
        systemctl restart unifi.service
        log "UniFi (classic) FIX (restarted)"
    else
        log "ONLINE: UniFi (classic)"
    fi
}

check_uhotspotd
check_ualert
if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
    check_uosserver
else
    # No separate Mongo check — confirmed on a real classic install (UniFi
    # Network 10.5.54) that unifi.service ships with
    # UNIFI_MONGODB_SERVICE_ENABLED=false by default, so it manages its own
    # embedded MongoDB subprocess (127.0.0.1:27117) end-to-end, same as
    # uosserver above. check_unifi_classic already covers it.
    check_unifi_classic
fi

log "uwatch done at: $(date)"
