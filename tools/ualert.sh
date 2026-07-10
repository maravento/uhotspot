#!/bin/bash
# maravento.com
#
################################################################################
#
# ualert — UniFi Hotspot Alert Watcher (optional)
#
# DESCRIPTION:
#   Watches /var/log/uhotspot.log in real time and sends a push
#   notification via ntfy.sh on two kinds of events:
#
#   1. Connectivity loss to the UniFi controller — anchors on the
#      "Could not load vouchers" line, which uhotspotd.sh's
#      load_all_vouchers() logs exactly once per cycle when the controller
#      is unreachable. Successful cycles are silent, so consecutive
#      failures are identified by comparing timestamps: a gap larger than
#      POLL_INTERVAL (+ margin) between two failure lines means cycles
#      succeeded silently in between, and the streak resets. Alerts once
#      API_FAIL_THRESHOLD consecutive cycles fail, and again once recovered.
#
#   2. Any other ERROR or WARNING line — the log already classifies every
#      line's severity ("TIMESTAMP LEVEL: message"), shared by
#      uhotspotd.sh and the ureload.sh/uleases.sh/uiptables.sh chain.
#      Fires immediately, no streak — one occurrence is already worth
#      knowing about. Excludes lines already covered by #1 (so
#      connectivity still waits for the threshold, not the first failure)
#      and "cycle lock held unexpectedly" (expected/already handled, see
#      uhotspotd.sh run_cycle() — not a bug).
#
#   Standalone — never reads or modifies uhotspotd.sh, only tails its log
#   file. Runs as its own systemd service (ualert.service), independent of
#   uhotspotd, so the daemon stays byte-identical to upstream. Optional:
#   uhotspotd.sh runs fine with or without ualert installed.
#
# DEPENDENCIES:
#   - bash, curl, GNU coreutils (date -d, tail -F) — standard on Ubuntu/Debian
#   - systemd (systemctl) — only needed for `install`/`uninstall`
#   - uhotspotd.sh already installed and running (this reads its log; it
#     does not start or manage the daemon itself)
#   - An ntfy.sh account is not required. Install the free "ntfy" app
#     (Android/iOS) and subscribe to a topic name of your choice — treat
#     the topic name as a shared secret, since anyone who knows it can
#     publish to it. https://ntfy.sh
#
# CONFIGURATION:
#   `install` appends NTFY_TOPIC (auto-generated, unpredictable) and
#   API_FAIL_THRESHOLD=3 to /etc/uhotspot/uhotspot.conf on first run, and
#   prints the generated topic name so you can subscribe the ntfy app to
#   it. Never overwrites either value if already present (safe to re-run).
#   To change them later, edit uhotspot.conf directly and restart the
#   service: systemctl restart ualert
#   POLL_INTERVAL is read from the same file (falls back to 20 if unset),
#   matching uhotspotd.sh's own cycle interval.
#
# USAGE:
#   sudo ./ualert.sh install      Deploy to /etc/uhotspot/tools/ualert.sh,
#                                  create+enable+start ualert.service
#                                  (creates the systemd unit if missing)
#   sudo ./ualert.sh uninstall    Stop+disable the service, remove the unit
#   ualert.sh                     Run the watch loop directly (this is what
#                                  ualert.service's ExecStart invokes)
#   ualert.sh -h, --help          Show this help
#
# CONFIG:  /etc/uhotspot/uhotspot.conf   (reads NTFY_TOPIC, API_FAIL_THRESHOLD, POLL_INTERVAL)
# LOG:     /var/log/uhotspot.log         (reads only — shared with uhotspotd.sh)
# SERVICE: systemctl status ualert
#
################################################################################

TARGET="/etc/uhotspot/tools/ualert.sh"
UNIT_PATH="/etc/systemd/system/ualert.service"
CONFIG_FILE="/etc/uhotspot/uhotspot.conf"
log_file="/var/log/uhotspot.log"

log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

usage() {
    sed -n '2,67p' "$0" | sed 's/^# \{0,1\}//'
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
if ! flock -w 60 200; then
    log "Script $(basename "$0") is already running — waited 60s, giving up"
    exit 1
fi

install_module() {
    echo ""
    echo "=================================="
    echo "Installing ualert (uhotspot alert)"
    echo "=================================="
    echo ""

    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: $CONFIG_FILE not found — install/configure uhotspotd.sh first"
        exit 1
    fi

    # Only append if not already configured — never overwrite an existing
    # topic (e.g. on a re-install) or a threshold the user already tuned.
    if grep -q '^NTFY_TOPIC=' "$CONFIG_FILE"; then
        gen_topic=$(grep '^NTFY_TOPIC=' "$CONFIG_FILE" | tail -1 | cut -d'"' -f2)
        echo "NTFY_TOPIC already set in $CONFIG_FILE — leaving it untouched."
    else
        gen_topic="uhotspot-alert-$(tr -dc 'a-z0-9' < /dev/urandom | head -c 10)"
        {
            echo ""
            echo "# ── Alert ─────────────────────────────────────────────────────────────────────"
            echo "NTFY_TOPIC=\"$gen_topic\""
            echo "API_FAIL_THRESHOLD=3"
        } >> "$CONFIG_FILE"
        echo "Added NTFY_TOPIC and API_FAIL_THRESHOLD to $CONFIG_FILE"
    fi
    if ! grep -q '^API_FAIL_THRESHOLD=' "$CONFIG_FILE"; then
        echo "API_FAIL_THRESHOLD=3" >> "$CONFIG_FILE"
    fi

    SELF="$(readlink -f "$0")"
    if [[ "$SELF" != "$TARGET" ]]; then
        echo "Deploying script to $TARGET..."
        mkdir -p "$(dirname "$TARGET")"
        install -m 755 -o root -g root "$SELF" "$TARGET"
    fi

    echo "Writing systemd unit ($UNIT_PATH)..."
    cat > "$UNIT_PATH" <<'UNITEOF'
[Unit]
Description=UniFi Hotspot Connectivity Alert Watcher
After=network.target uhotspotd.service
Wants=uhotspotd.service

[Service]
Type=simple
ExecStart=/etc/uhotspot/tools/ualert.sh
Restart=always
RestartSec=10
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
UNITEOF

    systemctl daemon-reload
    systemctl enable --now ualert.service

    echo ""
    echo "✓ Installed and started. Check with: systemctl status ualert"
    echo ""
    echo "=================================="
    echo " ntfy topic: $gen_topic"
    echo "=================================="
    echo "Install the free 'ntfy' app (Android/iOS) and subscribe to the"
    echo "topic above to start receiving alerts on this device."
    echo ""
}

uninstall_module() {
    echo "Stopping and disabling ualert.service..."
    systemctl stop ualert.service 2>/dev/null || true
    systemctl disable ualert.service 2>/dev/null || true
    rm -f "$UNIT_PATH"
    systemctl daemon-reload
    echo "✓ ualert.service removed. $TARGET was left in place — delete it manually if desired."
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

# ── Watch loop (default action — this is what ualert.service runs) ────────────

set -uo pipefail
# No -e: this is a long-running watch loop, one bad line (e.g. an
# unparseable timestamp) must not kill the whole process.

if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: $CONFIG_FILE not found — aborting"
    exit 1
fi
_owner=$(stat -c '%U' "$CONFIG_FILE" 2>/dev/null)
_perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null)
_gdigit="${_perms: -2:1}"
_odigit="${_perms: -1}"
if [[ "$_owner" != "root" ]] || [[ "$_gdigit" != "0" ]] || [[ "$_odigit" != "0" ]]; then
    log "ERROR: $CONFIG_FILE has unsafe owner/permissions (owner=$_owner perms=$_perms) — must be owned by root with no group/other access (600)"
    exit 1
fi
source "$CONFIG_FILE"

if [[ -z "${NTFY_TOPIC:-}" ]]; then
    log "ERROR: NTFY_TOPIC not set in $CONFIG_FILE — aborting"
    exit 1
fi

FAIL_THRESHOLD="${API_FAIL_THRESHOLD:-3}"
POLL_INTERVAL="${POLL_INTERVAL:-20}"
MARGIN=10   # tolerance added to POLL_INTERVAL so minor cycle jitter doesn't
            # falsely look like a gap with a silent recovery in between
GAP_LIMIT=$(( POLL_INTERVAL + MARGIN ))

streak=0
alerted=0
last_ts_epoch=0

notify() {
    local msg="$1"
    curl -s -d "$msg" "https://ntfy.sh/${NTFY_TOPIC}" >/dev/null 2>&1 &
}

trap 'log "ualert done at: $(date)"; exit 0' TERM INT

# Start
log "ualert start..."

exec 3< <(tail -n0 -F "$log_file" 2>/dev/null)

while true; do
    if IFS= read -r -t "$GAP_LIMIT" -u 3 line; then
        msg="${line:20}"

        # Known-benign — expected/already handled, must never alert.
        [[ "$msg" == *"cycle lock held unexpectedly"* ]] && continue

        # Connectivity-loss lines are ERROR/WARNING too, but they are
        # handled by the streak counter below (waits for
        # API_FAIL_THRESHOLD consecutive cycles) rather than firing on the
        # first occurrence like the generic catch-all does.
        is_connectivity=0
        [[ "$msg" == *"Could not load vouchers"* ]] && is_connectivity=1
        [[ "$msg" == *"API GET"* ]] && is_connectivity=1
        [[ "$msg" == *"no response (timeout or network error)"* ]] && is_connectivity=1

        # Generic catch-all: any other ERROR/WARNING line, from
        # uhotspotd.sh or the ureload.sh/uleases.sh/uiptables.sh chain
        # (shared log) — fires immediately, no streak needed.
        if (( is_connectivity == 0 )) && { [[ "$msg" == ERROR:* ]] || [[ "$msg" == WARNING:* ]]; }; then
            notify "uhotspot: $msg"
            log "ALERT: sent — $msg"
            continue
        fi

        [[ "$msg" != *"Could not load vouchers"* ]] && continue

        ts="${line:0:19}"
        epoch=$(date -d "$ts" +%s 2>/dev/null) || continue

        # Gap since the last matching failure is bigger than one cycle
        # (plus margin) — cycles succeeded silently in between, so this is
        # a fresh outage, not a continuation of the previous one.
        if (( last_ts_epoch != 0 )) && (( epoch - last_ts_epoch > GAP_LIMIT )); then
            streak=0
            alerted=0
        fi
        last_ts_epoch=$epoch
        streak=$(( streak + 1 ))

        if (( streak == FAIL_THRESHOLD )) && (( alerted == 0 )); then
            notify "uhotspot: $streak consecutive failed cycles reaching the controller (since $ts)"
            log "ALERT: sent — $streak consecutive cycle failures, latest at $ts"
            alerted=1
        fi
    else
        # read timed out: no new failure line for a full GAP_LIMIT window.
        if (( alerted == 1 )); then
            notify "uhotspot: recovered — no new failures in the last ${GAP_LIMIT}s"
            log "ALERT: recovery notice sent"
        fi
        streak=0
        alerted=0
    fi
done
