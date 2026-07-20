#!/bin/bash
# maravento.com
#
################################################################################
#
# uwatch -- UniFi Hotspot Services Watchdog (optional)
#
# DESCRIPTION:
# Runs every 5 minutes via cron. Watches every service uhotspot depends on
# and restarts whichever one is down. Each service check is fully
# independent -- one check's failure/fix never skips or blocks the others
# in the same run (unlike a naive watchdog that exits after the first fix).
#
# Checks performed, every run:
# 1. uhotspotd.service -- always.
# 2. ualert.service -- only if installed (optional component of uhotspot;
# silently skipped if its unit file isn't present).
# 3. UniFi backend -- branches on UNIFI_TYPE from uhotspot.conf. Both branches
# first require systemctl is-active (start it if not), then run a
# functional check: a real login against the API (same mechanism
# uhotspotd.sh itself uses -- credentials via jq env, payload via curl
# stdin, never in argv), using UNIFI_USERNAME/UNIFI_PASSWORD from
# uhotspot.conf. HTTP 200 = healthy. HTTP 000 or 5xx = unresponsive,
# restarts the service. Any 4xx = credentials rejected but the service
# itself is up and answering -- logged as a warning, no restart (a
# restart wouldn't fix a wrong password in uhotspot.conf anyway).
# If those credentials are not set in uhotspot.conf, falls back to a
# process/port-only check instead of skipping the check entirely.
# - "unifi-os": uosserver.service. UOS Server is an all-in-one container
# that bundles its own MongoDB internally -- no host-level mongod.service
# is part of this architecture. A broken internal Mongo is exactly the
# failure mode the login check catches that a plain process check
# cannot. A standalone mongod.service found running alongside UOS
# Server is very likely a leftover from a previous classic install and
# is not monitored here.
# - "classic": unifi.service. Ships with UNIFI_MONGODB_SERVICE_ENABLED=false
# by default, so it manages its own embedded MongoDB subprocess
# (127.0.0.1:27117) end-to-end, including its own shutdown logic -- the
# mongodb-org-server package's own mongod.service unit is never started
# and its data directory stays empty. Same all-in-one shape as unifi-os
# above, so restarting unifi.service already covers a Mongo failure
# too. Credentials-absent fallback checks ports 8443/8080 instead.
#
# Standalone -- never reads or modifies uhotspotd.sh, only manages services
# via systemctl. Independent of the user's own system-wide service
# watchdog (if any); this one only knows about uhotspot's own dependencies.
#
# USAGE:
# sudo ./uwatch.sh install Deploy to /etc/uhotspot/tools/uwatch.sh,
# register cron entry (*/5 * * * *)
# sudo ./uwatch.sh uninstall Remove the cron entry
# uwatch.sh Run the checks directly (what cron invokes)
# uwatch.sh -h, --help Show this help
#
# CONFIG: /etc/uhotspot/uhotspot.conf (reads UNIFI_TYPE, UNIFI_CONTROLLER_URL,
# UNIFI_USERNAME, UNIFI_PASSWORD)
# LOG: /var/log/uhotspot.log (shared with the rest of uhotspot). Silent on
# a healthy run -- nothing is written unless a check finds a problem
# or takes a fix action (WARNING/FIX/ERROR only).
#
################################################################################

set -uo pipefail

# PATH for cron
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# logging
log_file="/var/log/uhotspot.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

usage() {
    sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'
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
(umask 077; : >> "$SCRIPT_LOCK")
exec 200>"$SCRIPT_LOCK"
if ! flock -n 200; then
    log "Script $(basename "$0") is already running"
    exit 1
fi

TARGET="/etc/uhotspot/tools/uwatch.sh"

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
    if echo "$current" | grep -vE '^\s*#' | grep -qF "$TARGET"; then
        echo "Cron entry already present -- leaving it untouched."
    else
        { printf '%s\n%s\n' "$current" "$cron_entry"; } | crontab -
        echo "Cron entry registered: $cron_entry"
    fi

    echo ""
    echo "Installed. First run happens on the next 5-minute mark."
    echo "Check the log with: tail -f $log_file"
    echo ""
}

uninstall_module() {
    echo "Removing uwatch cron entry..."
    if crontab -l 2>/dev/null | grep -qF "$TARGET"; then
        crontab -l 2>/dev/null | grep -vF "$TARGET" | crontab -
        echo "Cron entry removed. $TARGET was left in place -- delete it manually if desired."
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

# -- Checks (default action -- this is what cron runs) --------------------------

# Load UNIFI_TYPE from uhotspot.conf. Safe key=value parsing - file is never
# sourced to prevent code execution.
_UHOTSPOT_CONF="/etc/uhotspot/uhotspot.conf"
_load_conf() {
    local file="$1" key value
    [[ ! -f "$file" ]] && { log "WARNING: $file not found - using built-in defaults"; return 1; }
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*[#] ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        value="${value%\"}"
        value="${value#\"}"
        value="${value//\\\"/\"}"
        value="${value//\\\$/\$}"
        value="${value//\\\`/\`}"
        value="${value//\\\\/\\}"
        case "$key" in
            UNIFI_TYPE|UNIFI_CONTROLLER_URL|UNIFI_USERNAME|UNIFI_PASSWORD)
                printf -v "$key" '%s' "$value"
                ;;
        esac
    done < "$file"
}
_load_conf "$_UHOTSPOT_CONF"
UNIFI_TYPE="${UNIFI_TYPE:-unifi-os}"
if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
    UNIFI_CONTROLLER_URL="${UNIFI_CONTROLLER_URL:-https://127.0.0.1:11443}"
else
    UNIFI_CONTROLLER_URL="${UNIFI_CONTROLLER_URL:-https://127.0.0.1:8443}"
fi

check_uhotspotd() {
    if systemctl is-active --quiet uhotspotd.service; then
        :
    else
        log "WARNING: uhotspotd OFFLINE"
        if systemctl restart uhotspotd.service; then
            log "uhotspotd FIX (restarted)"
        else
            log "ERROR: uhotspotd restart FAILED"
        fi
    fi
}

check_ualert() {
    # Optional component -- if it was never installed, there's nothing to
    # watch and nothing to fix. Not a failure, just skip silently.
    if [[ ! -f /etc/systemd/system/ualert.service ]]; then
        return
    fi
    if systemctl is-active --quiet ualert.service; then
        :
    else
        log "WARNING: ualert OFFLINE"
        if systemctl restart ualert.service; then
            log "ualert FIX (restarted)"
        else
            log "ERROR: ualert restart FAILED"
        fi
    fi
}

check_uosserver() {
    # All-in-one container -- its internal MongoDB is bundled and managed by
    # the container itself, never a host-level service. Do not check/restart
    # any standalone mongod.service here; it is not part of this
    # architecture, and restarting uosserver.service would not fix an
    # unrelated host-level Mongo issue.
    if ! systemctl is-active --quiet uosserver.service; then
        log "WARNING: UOS OFFLINE"
        if systemctl start uosserver.service; then
            log "UOS FIX (start)"
        else
            log "ERROR: uosserver start FAILED"
        fi
        return
    fi

    # Functional check: systemctl is-active only proves the unit/process is
    # up, not that the app itself is healthy -- the container's embedded
    # MongoDB can fail to come up while the process keeps running, leaving
    # every real API call broken (a login attempt hangs or errors even though
    # systemctl sees it as fine). A real login is the same proof uhotspotd.sh
    # itself relies on. Username/password go via jq env (not --arg) and the
    # payload via curl stdin (not -d), so neither ever appears in this
    # process's argv (/proc/<pid>/cmdline).
    if [[ -z "${UNIFI_USERNAME:-}" || -z "${UNIFI_PASSWORD:-}" ]]; then
        log "WARNING: UNIFI_USERNAME/UNIFI_PASSWORD not set"
        log "Skipping functional login check"
        return
    fi

    local login_url payload http_code
    login_url="${UNIFI_CONTROLLER_URL}/api/auth/login"
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
        -X POST "$login_url" -H "Content-Type: application/json" \
        --data-binary @- <<< "$payload" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [[ "$http_code" == "200" ]]; then
        :
    elif [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
        log "WARNING: UniFi login attempt failed (HTTP $http_code)"
        if systemctl restart uosserver.service; then
            log "UOS FIX (login failed)"
        else
            log "ERROR: uosserver restart FAILED"
        fi
    else
        log "WARNING: credentials rejected (HTTP $http_code)"
        log "Check uhotspot.conf - UOS itself is responding"
    fi
}

check_unifi_classic() {
    if ! systemctl is-active --quiet unifi.service; then
        log "WARNING: UniFi (classic) OFFLINE"
        if systemctl start unifi.service; then
            log "UniFi (classic) FIX (start)"
        else
            log "ERROR: unifi.service start FAILED"
        fi
        return
    fi

    # Functional check: same reasoning as check_uosserver() -- systemctl
    # is-active only proves the process is up, not that the app (and its
    # embedded Mongo subprocess, see header) is actually healthy. Same login
    # mechanism as uhotspotd.sh, but against the classic endpoint (/api/login).
    if [[ -z "${UNIFI_USERNAME:-}" || -z "${UNIFI_PASSWORD:-}" ]]; then
        log "WARNING: UNIFI_USERNAME/UNIFI_PASSWORD not set"
        log "Skipping functional login check"
        # Fall back to a port check so this isn't a total no-op.
        if ! ss -lnt | grep -qE ':(8443|8080)\b'; then
            log "WARNING: UniFi (classic) BROKEN_PORTS"
            if systemctl restart unifi.service; then
                log "UniFi (classic) FIX (restarted)"
            else
                log "ERROR: unifi.service restart FAILED"
            fi
        fi
        return
    fi

    local login_url payload http_code
    login_url="${UNIFI_CONTROLLER_URL}/api/login"
    payload=$(UH_JQ_USER="$UNIFI_USERNAME" UH_JQ_PASS="$UNIFI_PASSWORD" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')
    http_code=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 \
        -X POST "$login_url" -H "Content-Type: application/json" \
        --data-binary @- <<< "$payload" 2>/dev/null || true)
    http_code="${http_code:-000}"
    if [[ "$http_code" == "200" ]]; then
        :
    elif [[ "$http_code" == "000" || "$http_code" =~ ^5 ]]; then
        log "WARNING: UniFi login attempt failed (HTTP $http_code)"
        if systemctl restart unifi.service; then
            log "UniFi (classic) FIX (login failed)"
        else
            log "ERROR: unifi.service restart FAILED"
        fi
    else
        log "WARNING: credentials rejected (HTTP $http_code)"
        log "Check uhotspot.conf - unifi.service is responding"
    fi
}

check_uhotspotd
check_ualert
if [[ "$UNIFI_TYPE" == "unifi-os" ]]; then
    check_uosserver
else
    # No separate Mongo check -- unifi.service ships with
    # UNIFI_MONGODB_SERVICE_ENABLED=false by default, so it manages its own
    # embedded MongoDB subprocess (127.0.0.1:27117) end-to-end, same as
    # uosserver above. check_unifi_classic already covers it.
    check_unifi_classic
fi
