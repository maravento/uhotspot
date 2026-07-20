#!/bin/bash
# maravento.com
#
################################################################################
#
# ureload - Reload wrapper
#
# DESCRIPTION:
# invoked by uhotspotd after ACL changes, or on its own safety-net cadence
# (RELOAD_SAFETY_INTERVAL_SECONDS in uhotspot.conf, default 1h) -- no cron
# entry needed. Can also be run manually for troubleshooting.
# Installed alongside uleases.sh and uhotspotd.sh under /etc/uhotspot/core/ --
# these three plus uhotspotd.service are the reload mechanism itself, not
# auxiliary tools (unlike /etc/uhotspot/tools/, which holds independent
# scripts uhotspot runs fine without: uaudit.sh, ucheck.sh, uhotspotmon.sh,
# uwatch.sh, ualert.sh, plus the admin-provided uiptables.sh).
# Runs uleases.sh (lease/ACL rebuild) then uiptables.sh (firewall rules), in
# that order. The two are not treated the same on failure:
# - uleases.sh: missing, not executable, or a genuine execution failure all
# abort the reload (WARNING + exit 1). It is the core ACL/lease
# reconciliation step -- nothing downstream can be trusted without it.
# - uiptables.sh: missing or not executable only warns and continues (the
# reload still counts as done). It also ships as a stub that
# intentionally exits 1 until configured, detected and skipped the same
# way. A genuine execution failure (script exists, runs, exits non-zero)
# still aborts (WARNING + exit 1) -- only its absence is tolerated.
#
# NOTE on logging:
# - Writes to /var/log/uhotspot.log (shared with uleases.sh). Rotation
# (/etc/logrotate.d/uhotspot) is installed by usetup.sh only.
#
################################################################################

set -euo pipefail

# logging
log_file="/var/log/uhotspot.log"
log() {
    local msg="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" | tee -a "$log_file" 2>/dev/null || true
}

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
    echo "Script $(basename "$0") is already running"
    exit 1
fi

# UHOTSPOT_RELOAD_ACTIVE: not set here. The daemon exports it before calling
# this script (so uleases.sh skips its own guard, since the daemon already
# holds CYCLE_LOCK). If this script is run manually (not by the daemon),
# UHOTSPOT_RELOAD_ACTIVE stays unset, so uleases.sh acquires CYCLE_LOCK
# itself instead, to avoid racing a daemon cycle that might be in progress.

# Start
log "ureload start..."

# Abort if uhotspotd isn't active -- nothing downstream should run blindly.
if ! systemctl is-active --quiet uhotspotd; then
    log "ERROR: uhotspotd is not active -- aborting (uleases.sh/uiptables.sh not invoked)"
    exit 1
fi

# Both scripts log their own output via log(); stdout here is a duplicate
# and is discarded, stderr is kept for uncaught bash errors.
#
# Each step is run under `bash -x` so a failure leaves a full trace behind --
# a bare "$name failed" with no further detail (e.g. a command that fails
# silently, like `sysctl -w ... >/dev/null 2>&1` with no key present) gives
# no way to diagnose after the fact. The trace is discarded on success and
# kept only when the step actually fails, so this adds no normal overhead.
run_step() {
    local script="$1" name="$2"
    if [[ ! -x "$script" ]]; then
        log "WARNING: $name not found or not executable: $script -- aborting"
        exit 1
    fi
    local trace_file
    trace_file=$(mktemp "/tmp/${name%.sh}-trace.XXXXXX")
    bash -x "$script" >/dev/null 2>"$trace_file" &
    local child=$!
    trap 'kill -TERM "$child" 2>/dev/null' TERM
    local exit_code=0
    wait "$child" || exit_code=$?
    if [[ "$exit_code" != "0" ]]; then
        # Fixed name, overwritten on every failure (not one file per
        # timestamp) -- a persistent failure retries every cycle, and an
        # unbounded trace per attempt would fill /var/log over time.
        local trace_dest="/var/log/${name%.sh}-failure.trace"
        mv -f "$trace_file" "$trace_dest" 2>/dev/null || true
        log "WARNING: $name failed (exit $exit_code) -- aborting; trace saved to $trace_dest"
        exit 1
    fi
    rm -f "$trace_file" 2>/dev/null || true
    trap - TERM
}

run_step "/etc/uhotspot/core/uleases.sh" "uleases.sh"

# uiptables.sh ships as a stub that always exits 1 until the admin replaces
# it with real firewall rules (see README) -- that is the normal state right
# after install, not a failure. Only invoke it once it looks configured, so
# an unconfigured stub does not trigger a WARNING/trace file on every reload.
# Unlike uleases.sh above, a missing uiptables.sh warns and continues rather
# than aborting -- uleases.sh is the core ACL/lease reconciliation and its
# absence must stop the reload chain; uiptables.sh only enforces at the
# firewall level, and ACL classification keeps working correctly without it.
UIPTABLES_SCRIPT="/etc/uhotspot/tools/uiptables.sh"
if [[ ! -x "$UIPTABLES_SCRIPT" ]]; then
    log "WARNING: uiptables.sh not found or not executable: $UIPTABLES_SCRIPT -- skipping"
elif grep -qF "UHOTSPOT_STUB_MARKER" "$UIPTABLES_SCRIPT" 2>/dev/null; then
    log "INFO: uiptables.sh not configured yet -- skipping firewall reload (see README)"
else
    run_step "$UIPTABLES_SCRIPT" "uiptables.sh"
fi

# End
log "ureload done at: $(date)"
