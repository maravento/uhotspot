#!/bin/bash
# ─────────────────────────────────────────────────────────────────────────────
#  usetup.sh — uhotspot installer / updater
#  https://github.com/maravento/uhotspot
#
#  Modes:
#    sudo bash usetup.sh             Install (default; aborts if already
#                                     installed — use --update or --remove)
#    sudo bash usetup.sh --update    Update scripts only (preserves config/ACLs)
#    sudo bash usetup.sh --remove    Uninstall
#    sudo bash usetup.sh --help      Usage
#
#  Run from inside the cloned repo. The script expects to find:
#    ./core/uhotspotd.sh
#    ./core/uhotspotd.service
#    ./core/ureload.sh
#    ./core/uleases.sh
#    ./tools/uaudit.sh
#    ./tools/ucheck.sh
#    ./tools/uhotspotmon.sh
#    ./tools/ualert.sh
#    ./tools/uwatch.sh
#    ./tools/uiptables_example.sh   (reference template only -- see below,
#                                    not required, not deployed)
#    ./acl/umacauth.txt
#    ./acl/umacbak.txt
#    ./acl/uqueue.txt
#    ./acl/ugrace.txt
#
#  core/ holds the reload mechanism itself (uleases.sh reconciles ACLs/leases,
#  ureload.sh invokes it, uhotspotd.sh/.service run the daemon that calls
#  ureload.sh) — uhotspot cannot function without any of these. tools/ holds
#  independent, optional utilities (auditing, monitoring, alerting) that
#  uhotspot runs fine without. acl/ holds uhotspot's own data files (empty
#  templates in the repo, deployed once and never overwritten afterward) —
#  not to be confused with /etc/acl, which belongs to pydhcp/iptables.
#
#  tools/uiptables_example.sh is a reference template, not a functional
#  script — the administrator copies it to /etc/uhotspot/tools/uiptables.sh
#  and adapts it manually. deploy_scripts() below explicitly excludes it
#  from the tools/*.sh deploy loop; it is never installed automatically.
#
#  Hard dependencies (checked before anything else; aborts if any is missing —
#  none of these are auto-installed):
#    bash, curl, jq, iptables, ipset, cron, python3
#
#  Hard dependency NOT an apt package (aborts if missing):
#    pydhcpd must be installed and running.
#    pydhcp is not an apt package; install it from
#    https://github.com/maravento/pydhcp before running this script.
# ─────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# ─── Paths ───────────────────────────────────────────────────────────────────
HOTSPOT_DIR="/etc/uhotspot"
CORE_DIR="${HOTSPOT_DIR}/core"
TOOLS_DIR="${HOTSPOT_DIR}/tools"
ACL_DIR="${HOTSPOT_DIR}/acl"
CONFIG_FILE="${HOTSPOT_DIR}/uhotspot.conf"
LOG_FILE="/var/log/uhotspot.log"
LOGROTATE_FILE="/etc/logrotate.d/uhotspot"
UIPTABLES_STUB="${TOOLS_DIR}/uiptables.sh"
SERVICE_DEST="/etc/systemd/system/uhotspotd.service"

# ─── Repo file expectations (relative to this script) ────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_CORE="${SCRIPT_DIR}/core"
REPO_TOOLS="${SCRIPT_DIR}/tools"
REPO_ACL="${SCRIPT_DIR}/acl"
REPO_UHOTSPOTD="${REPO_CORE}/uhotspotd.sh"
REPO_SERVICE="${REPO_CORE}/uhotspotd.service"

# ─── Required apt packages ────────────────────────────────────────────────────
APT_DEPS=(curl jq iptables ipset cron python3)

# ─── Discovered runtime values (filled during install) ───────────────────────
DHCP_BACKEND=""    # "pydhcpd"
LOCAL_USER=""

# ─── Output helpers ──────────────────────────────────────────────────────────
info()  { printf '  \e[32m✔\e[0m %s\n'   "$*"; }
warn()  { printf '  \e[33m!\e[0m %s\n'   "$*"; }
err()   { printf '  \e[31m✗\e[0m %s\n'   "$*" >&2; }
step()  { printf '\n── %s ─────────────────────────────────────────────\n' "$*"; }
abort() { err "$*"; exit 1; }

version_ge() {
    # version_ge A B — returns 0 if version A >= version B
    [[ "$1" == "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n1)" ]]
}

dq_escape() {
    # dq_escape STRING — escape \ " $ ` for safe reuse inside double quotes
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\$/\\\$}"
    s="${s//\`/\\\`}"
    printf '%s' "$s"
}

confirm() {
    # confirm "prompt" [default y|n]  — returns 0 on yes, 1 on no
    local prompt="$1" default="${2:-n}" answer hint
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    read -rp "  ${prompt} ${hint}: " answer
    answer="${answer:-$default}"
    [[ "${answer,,}" =~ ^y(es)?$ ]]
}

# ─── Preflight checks ────────────────────────────────────────────────────────
check_distro() {
    local id="" ver=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        . /etc/os-release
        id="${ID:-}"
        ver="${VERSION_ID:-}"
    fi
    if [[ "$id" != "ubuntu" || "$ver" != "24.04" ]]; then
        warn "Tested only on Ubuntu 24.04. Detected: ${id:-unknown} ${ver:-unknown}"
        warn "Continuing at your own risk."
    else
        info "Ubuntu ${ver} detected"
    fi
}

detect_local_user() {
    # Multi-strategy detection: falls through session/login sources until
    # one resolves to a valid local user.
    LOCAL_USER=""
    LOCAL_USER=$(who | awk '/\(:0\)/{print $1; exit}')
    [[ -z "$LOCAL_USER" ]] && LOCAL_USER=$(logname 2>/dev/null || true)
    [[ -z "$LOCAL_USER" ]] && LOCAL_USER="${SUDO_USER:-}"
    [[ -z "$LOCAL_USER" ]] && LOCAL_USER=$(who | awk 'NR==1{print $1}')
    [[ -z "$LOCAL_USER" ]] && LOCAL_USER=$(ls -l /home 2>/dev/null | awk '/^d/{print $3; exit}')
    if [[ -z "$LOCAL_USER" ]] || ! id "$LOCAL_USER" &>/dev/null; then
        abort "Cannot determine a valid local user"
    fi
    info "Local user: $LOCAL_USER"
}

check_repo_files() {
    [[ -r "$REPO_UHOTSPOTD"          ]] || abort "Missing $(basename "$REPO_UHOTSPOTD"). Run usetup.sh from inside the cloned uhotspot repository."
    [[ -r "$REPO_SERVICE"            ]] || abort "Missing $(basename "$REPO_SERVICE"). Run usetup.sh from inside the cloned uhotspot repository."
    [[ -r "${REPO_CORE}/ureload.sh"  ]] || abort "Missing core/ureload.sh. Run usetup.sh from inside the cloned uhotspot repository."
    [[ -r "${REPO_CORE}/uleases.sh"  ]] || abort "Missing core/uleases.sh. Run usetup.sh from inside the cloned uhotspot repository."
    [[ -d "$REPO_TOOLS"              ]] || abort "Missing tools/ directory. Run usetup.sh from inside the cloned uhotspot repository."
    [[ -d "$REPO_ACL"                ]] || abort "Missing acl/ directory. Run usetup.sh from inside the cloned uhotspot repository."
    info "Repo files located"
}

check_apt_deps() {
    local missing=()
    for pkg in "${APT_DEPS[@]}"; do
        dpkg -s "$pkg" &>/dev/null || missing+=("$pkg")
    done
    if (( ${#missing[@]} > 0 )); then
        abort "Missing required package(s): ${missing[*]}. Install them first (e.g. apt-get install ${missing[*]}), then re-run."
    fi
    info "All apt dependencies present: ${APT_DEPS[*]}"
}

detect_dhcp_backend() {
    local pydhcp_active=false
    systemctl is-active --quiet pydhcpd 2>/dev/null && pydhcp_active=true

    if $pydhcp_active; then
        DHCP_BACKEND="pydhcpd"
        info "DHCP backend detected: pydhcpd"
    else
        err "pydhcpd is not active."
        err "Install and start pydhcpd from https://github.com/maravento/pydhcp"
        abort "Aborting: DHCP backend required."
    fi
}

# ─── Interactive prompts ──────────────────────────────────────────────────────
ask() {
    local prompt="$1" default="$2" var="$3" answer
    if [[ -n "$default" ]]; then
        read -rp "  ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
    else
        while true; do
            read -rp "  ${prompt}: " answer
            [[ -n "$answer" ]] && break
            err "This field is required."
        done
    fi
    printf -v "$var" '%s' "$answer"
}

ask_interface() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp "  ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
        if ip link show "$answer" &>/dev/null; then
            printf -v "$var" '%s' "$answer"
            break
        fi
        err "Interface '$answer' not found. Available: $(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || true)"
    done
}

ask_ip() {
    local prompt="$1" var="$2" answer
    while true; do
        read -rp "  ${prompt}: " answer
        if [[ "$answer" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            local valid=1
            IFS='.' read -ra octs <<< "$answer"
            for o in "${octs[@]}"; do
                if [[ "$o" =~ ^0[0-9]+$ ]] || (( 10#$o > 255 )); then valid=0; break; fi
            done
            [[ $valid -eq 1 ]] && printf -v "$var" '%s' "$answer" && break
        fi
        err "'$answer' is not a valid IPv4 address (e.g. 192.168.0.1)."
    done
}

ask_number() {
    local prompt="$1" default="$2" var="$3" answer
    while true; do
        read -rp "  ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 )); then
            printf -v "$var" '%s' "$answer"
            break
        fi
        err "'$answer' is not valid. Enter a positive integer."
    done
}

ask_octet() {
    local prompt="$1" default="$2" var="$3" ref_start="${4:-0}" answer
    while true; do
        read -rp "  ${prompt} [${default}]: " answer
        answer="${answer:-$default}"
        if [[ "$answer" =~ ^[0-9]+$ ]] && (( answer >= 1 && answer <= 254 )); then
            if [[ -n "$ref_start" ]] && (( answer <= ref_start )); then
                err "End octet must be greater than start octet (${ref_start})."
                continue
            fi
            printf -v "$var" '%s' "$answer"
            break
        fi
        err "'$answer' is not valid. Enter a number between 1 and 254."
    done
}

# Returns 0 (true) if octet ranges [s1,e1] and [s2,e2] intersect.
ranges_overlap() {
    local s1="$1" e1="$2" s2="$3" e2="$4"
    (( s1 <= e2 && s2 <= e1 ))
}

# ─── UniFi controller discovery ──────────────────────────────────────────────
DISCOVERED_URL=""
DISCOVERED_TYPE=""

discover_unifi_controller() {
    local user="$1" pass="$2" server_ip="$3"
    local ports=(8443 11443)
    local test_url http_code payload

    info "Probing ${server_ip} on ports ${ports[*]} ..."
    # Pass username/password to jq via environment, not --arg, so the
    # plaintext password never appears in jq's own argv (readable by any
    # local user via /proc/<pid>/cmdline).
    payload=$(UH_JQ_USER="$user" UH_JQ_PASS="$pass" jq -n \
        '{username: env.UH_JQ_USER, password: env.UH_JQ_PASS}')

    for port in "${ports[@]}"; do
        test_url="https://${server_ip}:${port}"

        # Body goes to curl via stdin (--data-binary @-), not -d, for the
        # same reason: -d "$payload" would put the password in curl's argv.
        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "${test_url}/api/auth/login" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            --connect-timeout 3 <<< "$payload" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            info "Found UniFi OS controller at ${test_url}"
            DISCOVERED_URL="$test_url"
            DISCOVERED_TYPE="unifi-os"
            return 0
        fi

        http_code=$(curl -sk -o /dev/null -w "%{http_code}" \
            -X POST "${test_url}/api/login" \
            -H "Content-Type: application/json" \
            --data-binary @- \
            --connect-timeout 3 <<< "$payload" || echo "000")
        if [[ "$http_code" == "200" ]]; then
            info "Found classic UniFi controller at ${test_url}"
            DISCOVERED_URL="$test_url"
            DISCOVERED_TYPE="classic"
            return 0
        fi
    done

    return 1
}

# ─── Setup wizard ────────────────────────────────────────────────────────────
run_setup_wizard() {
    local CFG_WAN_IF CFG_LAN_IF CFG_SERVER_IP CFG_IP_RANGE
    local CFG_RANGE_START CFG_RANGE_END CFG_ESSID
    local CFG_UNIFI_USER CFG_UNIFI_PASS CFG_RELOAD_SCRIPT
    local found_url found_type

    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  uhotspot — Interactive Setup"
    echo "══════════════════════════════════════════════════════"

    step "Network"
    local ifaces
    ifaces=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | tr '\n' ' ' || true)
    echo "  Available interfaces: $ifaces"
    ask_interface "WAN interface" "eth0" CFG_WAN_IF
    ask_interface "LAN interface" "eth1" CFG_LAN_IF
    ask_ip        "Server IP (this machine)" CFG_SERVER_IP

    step "Hotspot IP range"
    CFG_IP_RANGE=$(echo "$CFG_SERVER_IP" | cut -d'.' -f1-3)
    echo "  Hotspot IP range base (auto-detected): $CFG_IP_RANGE"
    local server_octet="${CFG_SERVER_IP##*.}"
    while true; do
        ask_octet "Range start (last octet)" "160" CFG_RANGE_START
        ask_octet "Range end   (last octet)" "199" CFG_RANGE_END "$CFG_RANGE_START"
        if (( server_octet >= CFG_RANGE_START && server_octet <= CFG_RANGE_END )); then
            err "Range ${CFG_RANGE_START}-${CFG_RANGE_END} includes the server's own IP (.${server_octet}). Choose a different range."
            continue
        fi
        break
    done

    step "Hotspot SSID"
    ask "Guest SSID name (must match exactly in UniFi)" "" CFG_ESSID

    step "UniFi credentials"
    ask "UniFi admin username" "admin" CFG_UNIFI_USER
    while true; do
        read -rsp "  UniFi admin password: " CFG_UNIFI_PASS; echo ""
        [[ -n "$CFG_UNIFI_PASS" ]] && break
        err "Password cannot be empty."
    done

    step "UniFi controller discovery"
    DISCOVERED_URL=""
    DISCOVERED_TYPE=""
    if discover_unifi_controller "$CFG_UNIFI_USER" "$CFG_UNIFI_PASS" "$CFG_SERVER_IP"; then
        found_url="$DISCOVERED_URL"
        found_type="$DISCOVERED_TYPE"
    else
        warn "No UniFi controller detected automatically."
        ask "Enter controller URL manually (e.g. https://192.168.0.1:8443)" "" found_url
        echo "  Enter controller type:"
        select found_type in "unifi-os" "classic"; do
            [[ -n "$found_type" ]] && break
        done
    fi

    step "Dependency check"
    # Same "unifi" package (Network app / ace.jar) in both types — classic has
    # it directly on the host, unifi-os has it inside the uosserver container.
    local MIN_VERSION_UNIFI="10.4.57"
    local detected_version min_version="$MIN_VERSION_UNIFI"
    case "$found_type" in
        classic)
            detected_version=$(dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d'-' -f1)
            ;;
        unifi-os)
            detected_version=$(sudo -u uosserver podman exec uosserver \
                dpkg-query -W -f='${Version}' unifi 2>/dev/null | cut -d'-' -f1)
            ;;
    esac
    if [[ -z "$detected_version" ]]; then
        abort "Could not detect the installed UniFi version (type: ${found_type}). uhotspot only supports versions tested to date — install aborted. Files were already deployed to ${HOTSPOT_DIR}; run 'usetup.sh --remove' before retrying."
    fi
    if ! version_ge "$detected_version" "$min_version"; then
        abort "Detected UniFi version ${detected_version} (${found_type}) is below the minimum tested version ${min_version}. uhotspot only supports ${min_version} and above for this type — install aborted. Files were already deployed to ${HOTSPOT_DIR}; run 'usetup.sh --remove' before retrying."
    fi
    info "UniFi version ${detected_version} (${found_type}) meets the minimum tested version (${min_version})"

    step "Reload script"
    echo "  Script invoked after every ACL change (must exist and be executable)."
    ask "Path to reload script" "${CORE_DIR}/ureload.sh" CFG_RELOAD_SCRIPT

    step "DHCP network"
    ask_mask() {
        local var="$1" default="${2:-255.255.255.0}" answer
        while true; do
            read -rp "  Subnet mask [$default]: " answer
            answer="${answer:-$default}"
            if echo "$answer" | grep -qE '^(255|254|252|248|240|224|192|128|0)(\.(255|254|252|248|240|224|192|128|0)){3}$' \
                && python3 -c "import ipaddress; ipaddress.IPv4Network('0.0.0.0/${answer}')" 2>/dev/null; then
                printf -v "$var" '%s' "$answer"; break
            fi
            err "Invalid mask, try again"
        done
    }
    ask_mask CFG_SERV_MASK "255.255.255.0"
    CFG_SERV_SUBNET=$(python3 -c "import ipaddress; net=ipaddress.IPv4Network('${CFG_SERVER_IP}/${CFG_SERV_MASK}', strict=False); print(net.network_address)")
    CFG_SERV_BROADCAST=$(python3 -c "import ipaddress; net=ipaddress.IPv4Network('${CFG_SERVER_IP}/${CFG_SERV_MASK}', strict=False); print(net.broadcast_address)")
    info "Subnet: $CFG_SERV_SUBNET  Broadcast: $CFG_SERV_BROADCAST"

    step "DNS servers"
    ask "DNS servers (comma-separated)" "8.8.8.8,1.1.1.1" CFG_SERV_DNS

    step "DHCP pool (for new/unknown clients)"
    local NET_BASE
    NET_BASE="${CFG_SERVER_IP%.*}"
    echo "  These IPs are assigned temporarily to clients not yet in any ACL list."
    while true; do
        ask_octet "Pool start (last octet)" "230" CFG_POOL_START
        ask_octet "Pool end   (last octet)" "239" CFG_POOL_END "$CFG_POOL_START"
        if ranges_overlap "$CFG_POOL_START" "$CFG_POOL_END" "$CFG_RANGE_START" "$CFG_RANGE_END"; then
            err "Pool ${CFG_POOL_START}-${CFG_POOL_END} overlaps the hotspot range (${CFG_RANGE_START}-${CFG_RANGE_END}). Choose a different pool."
            continue
        fi
        if (( server_octet >= CFG_POOL_START && server_octet <= CFG_POOL_END )); then
            err "Pool ${CFG_POOL_START}-${CFG_POOL_END} includes the server's own IP (.${server_octet}). Choose a different pool."
            continue
        fi
        break
    done
    CFG_SERV_INI_RANGE_BLOCK="${NET_BASE}.${CFG_POOL_START}"
    CFG_SERV_END_RANGE_BLOCK="${NET_BASE}.${CFG_POOL_END}"

    step "Timers"
    ask_number "Daemon poll interval in seconds (POLL_INTERVAL)" "20" CFG_POLL_INTERVAL
    ask_number "DHCP pool lease cleanup interval in seconds (CLEANUP_INTERVAL)" "60" CFG_CLEANUP_INTERVAL
    ask_number "Grace period before blocking unknown MACs in seconds (BLOCKDHCP_GRACE_SECONDS)" "86400" CFG_GRACE_SECONDS

    step "Optional features"
    local CFG_WPAD_ENABLED="false"
    confirm "Enable WPAD/PAC proxy auto-configuration? (requires Apache2 on port 18100)" "n" && CFG_WPAD_ENABLED="true"
    local CFG_PING_CHECK="true"
    confirm "Enable pydhcpd ping-check before OFFER? (disable if strict ICMP rules)" "y" && CFG_PING_CHECK="true" || CFG_PING_CHECK="false"

    step "Managed MAC lists (optional)"
    echo "  mac-*.txt files allow specific devices to bypass the captive portal"
    echo "  automatically (corporate laptops, APs, printers, switches, etc.)."
    echo "  The daemon authorizes those MACs in UniFi each cycle if present."
    echo "  Files are stored in /etc/acl/acl_mac/ and managed manually."
    mkdir -p /etc/acl/acl_mac /etc/acl/acl_dhcp /etc/acl/acl_ipt
    chmod 700 /etc/acl/acl_mac /etc/acl/acl_dhcp /etc/acl/acl_ipt
    info "Directory /etc/acl/acl_mac created — add your mac-*.txt files there"

    step "Writing $CONFIG_FILE"
    (
        umask 077
        local ESSID_Q USER_Q PASS_Q URL_Q
        ESSID_Q=$(dq_escape "$CFG_ESSID")
        USER_Q=$(dq_escape "$CFG_UNIFI_USER")
        PASS_Q=$(dq_escape "$CFG_UNIFI_PASS")
        URL_Q=$(dq_escape "$found_url")
        cat > "$CONFIG_FILE" <<EOF
# uhotspot — auto-generated by usetup.sh on $(date '+%Y-%m-%d %H:%M:%S')
# Edit this file to adjust any value.

# ── Network ──────────────────────────────────────────────────────────────────
WAN_IF="${CFG_WAN_IF}"
LAN_IF="${CFG_LAN_IF}"
SERVER_IP="${CFG_SERVER_IP}"
LOCAL_USER="${LOCAL_USER}"

# ── Hotspot IP range ─────────────────────────────────────────────────────────
HOTSPOT_IP_RANGE="${CFG_IP_RANGE}"
HOTSPOT_RANGE_START=${CFG_RANGE_START}
HOTSPOT_RANGE_END=${CFG_RANGE_END}

# ── Guest SSID ───────────────────────────────────────────────────────────────
HOTSPOT_ESSID="${ESSID_Q}"

# ── UniFi Controller ─────────────────────────────────────────────────────────
UNIFI_CONTROLLER_URL="${URL_Q}"
UNIFI_USERNAME="${USER_Q}"
UNIFI_PASSWORD="${PASS_Q}"
# UniFi always creates a site named "default". If the administrator renamed it,
# edit this value to match the exact site name shown in the UniFi controller.
UNIFI_SITE="default"
UNIFI_TYPE="${found_type}"


# ── Reload script (required) ─────────────────────────────────────────────────
SERVER_RELOAD_SCRIPT="${CFG_RELOAD_SCRIPT}"


# ── DHCP network (read by uleases.sh and uiptables.sh) ───────────────────────
SERV_DHCP="${CFG_SERVER_IP}"
SERV_MASK="${CFG_SERV_MASK}"
SERV_SUBNET="${CFG_SERV_SUBNET}"
SERV_BROADCAST="${CFG_SERV_BROADCAST}"
SERV_DNS="${CFG_SERV_DNS}"

# ── DHCP pool (temporary IPs for new/unknown clients) ────────────────────────
SERV_INI_RANGE_BLOCK="${CFG_SERV_INI_RANGE_BLOCK}"
SERV_END_RANGE_BLOCK="${CFG_SERV_END_RANGE_BLOCK}"

# ── Paths (read by uleases.sh) ───────────────────────────────────────────────
ACL_PATH=/etc/acl
ACL_MAC_PATH=/etc/acl/acl_mac
ACL_DHCP_PATH=/etc/acl/acl_dhcp
ACL_MAC_PROXY=/etc/acl/acl_mac/mac-proxy.txt
ACL_MAC_UNLIMITED=/etc/acl/acl_mac/mac-unlimited.txt
ACL_BLOCK_FILE=/etc/acl/acl_dhcp/blockdhcp.txt
ACL_GRACE_FILE=/etc/uhotspot/acl/ugrace.txt
ACL_MAC_HOTSPOT=/etc/uhotspot/acl/umacauth.txt

# ── Daemon & DHCP timers ─────────────────────────────────────────────────────
POLL_INTERVAL=${CFG_POLL_INTERVAL}
CLEANUP_INTERVAL=${CFG_CLEANUP_INTERVAL}
AUTHORIZED_LEASE_TIME=2592000
BLOCKDHCP_GRACE_SECONDS=${CFG_GRACE_SECONDS}

# ── Optional features ─────────────────────────────────────────────────────────
UNIFI_HOTSPOT_ENABLED=true
WPAD_ENABLED="${CFG_WPAD_ENABLED}"
PING_CHECK_ENABLED="${CFG_PING_CHECK}"
EOF
    )
    chown root:root "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    info "Config saved to $CONFIG_FILE (mode 600)"
}

# ─── Filesystem layout ───────────────────────────────────────────────────────
deploy_directories() {
    mkdir -p "$HOTSPOT_DIR" "$CORE_DIR" "$TOOLS_DIR" "$ACL_DIR"
    chmod 700 "$HOTSPOT_DIR"
    chmod 700 "$CORE_DIR"
    chmod 700 "$TOOLS_DIR"
    chmod 700 "$ACL_DIR"
    info "Directories created"
}

deploy_acl_files() {
    # Own data files (umacauth.txt, umacbak.txt, uqueue.txt, ugrace.txt) —
    # repo ships them as empty templates. Copy once and never overwrite an
    # existing one, on install or update, so real ACL/voucher/queue data
    # already on disk is never touched.
    #
    # $1: "warn" logs a WARNING per missing file before creating it empty
    # (used by --update, where a missing ACL file means a partial/broken
    # install and is worth flagging); default is quiet (used by a fresh
    # install, where creating them is the expected, normal case).
    local report_mode="${1:-quiet}"
    local f dest
    for f in "${REPO_ACL}/"*.txt; do
        dest="${ACL_DIR}/$(basename "$f")"
        if [[ -f "$dest" ]]; then
            continue
        fi
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$dest") missing — creating empty"
        install -m 600 -o root -g root "$f" "$dest"
    done
    info "ACL data files present in ${ACL_DIR}"
}

deploy_scripts() {
    install -m 755 -o root -g root "$REPO_UHOTSPOTD" "${CORE_DIR}/uhotspotd.sh"
    install -m 755 -o root -g root "${REPO_CORE}/ureload.sh" "${CORE_DIR}/ureload.sh"
    install -m 755 -o root -g root "${REPO_CORE}/uleases.sh" "${CORE_DIR}/uleases.sh"
    local f
    for f in "${REPO_TOOLS}/"*.sh; do
        # uiptables_example.sh is a reference template for the administrator
        # to adapt manually into tools/uiptables.sh (see deploy_uiptables_stub)
        # — never deployed as-is.
        [[ "$(basename "$f")" == "uiptables_example.sh" ]] && continue
        install -m 755 -o root -g root "$f" "${TOOLS_DIR}/"
    done
    # Remove any copy left at the pre-restructure locations (directly under
    # $HOTSPOT_DIR / $TOOLS_DIR instead of core/), so at most one copy of
    # each script exists on disk.
    rm -f "${HOTSPOT_DIR}/uhotspotd.sh" "${TOOLS_DIR}/ureload.sh" "${TOOLS_DIR}/uleases.sh"
    info "Scripts deployed to ${HOTSPOT_DIR}"
}

deploy_uiptables_stub() {
    if [[ -f "$UIPTABLES_STUB" ]]; then
        info "uiptables.sh already exists — leaving untouched"
        return 0
    fi
    cat > "$UIPTABLES_STUB" <<'STUB'
#!/bin/bash
# /etc/uhotspot/tools/uiptables.sh
# UHOTSPOT_STUB_MARKER — do not remove this line while the script is
# unconfigured; ureload.sh looks for it to skip the reload gracefully
# instead of treating this stub's exit 1 as a real failure. It is removed
# automatically once you replace this file's content with real rules.
#
# Firewall rules for uhotspot. Invoked by ureload.sh after every ACL change.
#
# This file is a STUB. Copy the reference rules from the uhotspot README into
# this file and adapt the variables (wan, lan, wan_ip) to your network.
#
# The script must do two things:
#   1. Flush and repopulate the ipsets `macgrace` and `machotspot` from the
#      ACL files at /etc/uhotspot/acl/ugrace.txt and /etc/uhotspot/acl/umacauth.txt
#   2. Apply (idempotently) the iptables rules that consume those ipsets.
#
# Without this script populated, ACL changes will not reach the firewall and
# the captive portal will not work.

echo "uiptables.sh: not configured. Edit /etc/uhotspot/tools/uiptables.sh." >&2
exit 1
STUB
    chown root:root "$UIPTABLES_STUB"
    chmod 750 "$UIPTABLES_STUB"
    warn "Stub created at $UIPTABLES_STUB — YOU MUST EDIT IT (see README)"
}

install_logrotate() {
    # $1: "warn" logs a WARNING before creating a missing logrotate config
    # (used by --update, where this should already exist); default is quiet
    # (used by a fresh install, where creating it is the expected case).
    local report_mode="${1:-quiet}"
    if [[ -f "$LOGROTATE_FILE" ]]; then
        info "logrotate config already present at $LOGROTATE_FILE"
    else
        [[ "$report_mode" == "warn" ]] && warn "$(basename "$LOGROTATE_FILE") missing — creating it"
        cat > "$LOGROTATE_FILE" <<EOF
${LOG_FILE} {
    daily
    rotate 7
    compress
    missingok
    notifempty
    create 640 root adm
}
EOF
        chown root:root "$LOGROTATE_FILE"
        chmod 644 "$LOGROTATE_FILE"
        info "logrotate config installed at $LOGROTATE_FILE"
    fi
}

deregister_cron() {
    # uhotspotd triggers its own safety-net reload internally (see
    # RELOAD_SAFETY_INTERVAL_SECONDS in uhotspotd.sh) — no external cron
    # entry should exist. Removes a leftover @hourly ureload.sh entry if
    # found, matching both the current core/ureload.sh path and the
    # pre-restructure tools/ureload.sh path.
    local ureload_path_new="${HOTSPOT_DIR}/core/ureload.sh"
    local ureload_path_old="${HOTSPOT_DIR}/tools/ureload.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$ureload_path_new" -e "$ureload_path_old"; then
        crontab -l 2>/dev/null | grep -vF -e "$ureload_path_new" -e "$ureload_path_old" | crontab - || true
        info "Removed stale @hourly ureload.sh cron entry (now handled by uhotspotd.sh internally)"
    fi
}

final_sanity_check() {
    step "Sanity check"
    local issues=0

    if [[ ! -x "$UIPTABLES_STUB" ]] || grep -qF "UHOTSPOT_STUB_MARKER" "$UIPTABLES_STUB" 2>/dev/null; then
        warn "uiptables.sh is not configured — ACL changes will not reach the firewall"
        (( issues++ )) || true
    fi

    if (( issues == 0 )); then
        info "All checks passed."
    else
        warn "${issues} issue(s) need attention before uhotspot is fully functional."
    fi
}

install_systemd_service() {
    install -m 644 -o root -g root "$REPO_SERVICE" "$SERVICE_DEST"
    systemctl daemon-reload
    systemctl enable uhotspotd
    systemctl restart uhotspotd \
        && info "uhotspotd enabled and started" \
        || warn "Could not start uhotspotd — check: systemctl status uhotspotd"
}

# ─── Install mode ────────────────────────────────────────────────────────────
do_install() {
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  uhotspot — installer"
    echo "══════════════════════════════════════════════════════"

    if [[ -f "${CORE_DIR}/uhotspotd.sh" ]]; then
        abort "uhotspot is already installed at ${HOTSPOT_DIR}.
  Use --update to upgrade (keeps config), or --remove to remove first."
    fi

    step "Preflight"
    check_distro
    check_repo_files

    step "Filesystem layout"
    deploy_directories
    deploy_scripts
    deploy_acl_files
    deploy_uiptables_stub

    run_setup_wizard

    step "Logrotate"
    install_logrotate

    step "Systemd service"
    install_systemd_service

    step "Cron"
    deregister_cron

    final_sanity_check

    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  uhotspot installed."
    echo ""
    echo "  Next steps:"
    echo "    1. Edit ${UIPTABLES_STUB} with the firewall rules from the README."
    echo "    2. Check service: systemctl status uhotspotd"
    echo "    3. Check logs: tail -f ${LOG_FILE}"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# ─── Update mode ─────────────────────────────────────────────────────────────
do_update() {
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  uhotspot — update"
    echo "══════════════════════════════════════════════════════"

    step "Preflight"
    check_distro
    check_repo_files

    # Accepts either the current core/ layout or the pre-restructure layout
    # (uhotspotd.sh directly under $HOTSPOT_DIR, ureload.sh/uleases.sh under
    # $TOOLS_DIR), so an update from an old install isn't mistaken for a
    # fresh one.
    if [[ ! -d "$HOTSPOT_DIR" ]] || { [[ ! -f "${CORE_DIR}/uhotspotd.sh" ]] && [[ ! -f "${HOTSPOT_DIR}/uhotspotd.sh" ]]; }; then
        abort "uhotspot not installed. Run without --update first."
    fi

    step "Backup"
    local backup_dir
    backup_dir="/etc/uhotspot.bak/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$backup_dir"
    cp -p "${CORE_DIR}/"*.sh "$backup_dir/" 2>/dev/null || true
    cp -p "${HOTSPOT_DIR}/uhotspotd.sh" "$backup_dir/" 2>/dev/null || true
    cp -p "${TOOLS_DIR}/"*.sh "$backup_dir/" 2>/dev/null || true
    info "Current scripts backed up to $backup_dir"

    step "Pause services"
    # Stop whatever is actively running its own script file before that file
    # gets overwritten below — avoids replacing a script out from under a
    # process that may still be mid-cycle. pydhcpd is deliberately left
    # alone: it is a separate project this update never modifies, and
    # stopping it would cut DHCP for the whole LAN, not just the hotspot.
    local uwatch_path="${TOOLS_DIR}/uwatch.sh"
    local _uhotspotd_was_active=0 _ualert_was_active=0 _uwatch_was_active=0
    systemctl is-active --quiet uhotspotd 2>/dev/null && _uhotspotd_was_active=1
    if [[ -f /etc/systemd/system/ualert.service ]]; then
        systemctl is-active --quiet ualert 2>/dev/null && _ualert_was_active=1
    fi
    if crontab -l 2>/dev/null | awk -v p="$uwatch_path" '(index($0,p)>0 && substr($0,1,1)!="#"){f=1} END{exit !f}'; then
        _uwatch_was_active=1
    fi

    if (( _uhotspotd_was_active )); then
        systemctl stop uhotspotd && info "uhotspotd stopped for update" || warn "Could not stop uhotspotd — continuing anyway"
    fi
    if (( _ualert_was_active )); then
        systemctl stop ualert && info "ualert stopped for update" || warn "Could not stop ualert — continuing anyway"
    fi
    if (( _uwatch_was_active )); then
        crontab -l 2>/dev/null | awk -v p="$uwatch_path" '(index($0,p)>0 && substr($0,1,1)!="#"){print "#" $0; next} {print}' | crontab -
        info "uwatch cron entry commented out for update"
    fi

    step "Deploy updated scripts"
    deploy_scripts

    step "ACL data files"
    # ACL_DIR (umacauth.txt, umacbak.txt, uqueue.txt, ugrace.txt), CONFIG_FILE
    # and UIPTABLES_STUB are the administrator's own live/customized data.
    # --update never renames, moves or overwrites anything already present —
    # deploy_acl_files()/deploy_uiptables_stub() below only create what's
    # missing (e.g. a partial/broken install, warning about it since that
    # should not normally happen) and leave every existing file untouched.
    # No unconditional mkdir/chmod on an already-existing ACL_DIR either;
    # only created (and chmod 700) here if it doesn't exist yet.
    [[ -d "$ACL_DIR" ]] || { mkdir -p "$ACL_DIR"; chmod 700 "$ACL_DIR"; }
    deploy_acl_files warn
    deploy_uiptables_stub

    step "Logrotate"
    install_logrotate warn

    step "Systemd service"
    install -m 644 -o root -g root "$REPO_SERVICE" "$SERVICE_DEST"
    systemctl daemon-reload
    if (( _uhotspotd_was_active )); then
        systemctl restart uhotspotd && info "uhotspotd restarted" || warn "Could not restart uhotspotd — check: systemctl status uhotspotd"
    else
        info "uhotspotd was not active before the update — leaving it stopped"
    fi

    step "Resume services"
    # Only restore what this update itself paused above — never start
    # something the administrator had deliberately left stopped/disabled.
    if (( _ualert_was_active )); then
        systemctl start ualert && info "ualert restarted" || warn "Could not restart ualert — check: systemctl status ualert"
    fi
    if (( _uwatch_was_active )); then
        crontab -l 2>/dev/null | awk -v p="$uwatch_path" '(substr($0,1,1)=="#" && index($0,p)>0){print substr($0,2); next} {print}' | crontab -
        info "uwatch cron entry restored"
    fi

    step "Cron"
    deregister_cron

    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  Update complete."
    echo ""
    echo "  Preserved (never renamed/moved/overwritten if already present):"
    echo "    - ${CONFIG_FILE}"
    echo "    - ${UIPTABLES_STUB}"
    echo "    - ACL data files (*.txt)"
    echo "    - Logrotate config"
    echo ""
    echo "  Paused for the update, then resumed to their prior state:"
    echo "    - uhotspotd.service, ualert.service (if it was active)"
    echo "    - uwatch cron entry (if it was active)"
    echo ""
    echo "  Stale @hourly ureload.sh cron entry removed if present"
    echo ""

    echo "  Backup: $backup_dir"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# ─── Remove mode ─────────────────────────────────────────────────────────────
do_remove() {
    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  uhotspot — uninstaller"
    echo "══════════════════════════════════════════════════════"

    echo ""
    echo "  The following actions will be offered (each with confirmation):"
    echo "    • Remove cron entries pointing to ${HOTSPOT_DIR}/core/ureload.sh"
    echo "    • Stop and remove ualert.service and the uwatch cron entry (if installed)"
    echo "    • Remove ${LOGROTATE_FILE}"
    echo "    • Remove ${HOTSPOT_DIR} (includes uhotspot.conf, ACLs, uiptables.sh)"
    echo "    • Remove ${LOG_FILE} and rotated logs"
    echo ""
    confirm "Proceed with uninstall?" "n" || { info "Aborted by user."; exit 0; }

    # Systemd service
    step "Systemd service"
    if systemctl is-active --quiet uhotspotd 2>/dev/null || systemctl is-enabled --quiet uhotspotd 2>/dev/null; then
        if confirm "Stop and disable uhotspotd.service?" "y"; then
            systemctl disable --now uhotspotd 2>/dev/null || true
            info "uhotspotd.service disabled and stopped"
        else
            warn "uhotspotd.service preserved"
        fi
    fi
    if [[ -f "$SERVICE_DEST" ]]; then
        if confirm "Remove $SERVICE_DEST?" "y"; then
            rm -f "$SERVICE_DEST"
            systemctl daemon-reload
            info "Service file removed"
        else
            warn "Service file preserved"
        fi
    fi

    # Cron entries
    step "Cron"
    # Matches both the current core/ureload.sh path and the pre-restructure
    # tools/ureload.sh path.
    local ureload_path="${HOTSPOT_DIR}/core/ureload.sh"
    local ureload_path_old="${HOTSPOT_DIR}/tools/ureload.sh"
    if crontab -l 2>/dev/null | grep -qF -e "$ureload_path" -e "$ureload_path_old"; then
        if confirm "Remove cron entries for $ureload_path?" "y"; then
            crontab -l 2>/dev/null | grep -vF -e "$ureload_path" -e "$ureload_path_old" | crontab - || true
            info "Cron entries removed"
        else
            warn "Cron entries preserved"
        fi
    else
        info "No cron entries found"
    fi

    # ualert (optional component)
    step "ualert"
    if [[ -f /etc/systemd/system/ualert.service ]]; then
        if confirm "Stop, disable and remove ualert.service?" "y"; then
            systemctl disable --now ualert 2>/dev/null || true
            rm -f /etc/systemd/system/ualert.service
            systemctl daemon-reload
            info "ualert.service removed"
        else
            warn "ualert.service preserved"
        fi
    else
        info "ualert.service not installed"
    fi

    # uwatch (optional component)
    step "uwatch"
    local uwatch_path="${TOOLS_DIR}/uwatch.sh"
    if crontab -l 2>/dev/null | grep -qF "$uwatch_path"; then
        if confirm "Remove uwatch cron entry?" "y"; then
            crontab -l 2>/dev/null | grep -vF "$uwatch_path" | crontab - || true
            info "uwatch cron entry removed"
        else
            warn "uwatch cron entry preserved"
        fi
    else
        info "No uwatch cron entry found"
    fi

    # Logrotate
    step "Logrotate"
    if confirm "Remove logrotate config (${LOGROTATE_FILE})?" "y"; then
        [[ -f "$LOGROTATE_FILE" ]] && rm -f "$LOGROTATE_FILE" && info "Removed $LOGROTATE_FILE" || true
        info "Logrotate config removed"
    else
        warn "Logrotate configs preserved"
    fi

    # /etc/uhotspot
    step "$HOTSPOT_DIR"
    if [[ -d "$HOTSPOT_DIR" ]]; then
        echo "  This will delete:"
        echo "    - $CONFIG_FILE (credentials)"
        echo "    - ${ACL_DIR}/ (umacauth.txt, umacbak.txt, uqueue.txt, ugrace.txt)"
        echo "    - $UIPTABLES_STUB (YOUR firewall script — back it up first if needed)"
        echo "    - All other contents of $HOTSPOT_DIR"
        if confirm "Remove $HOTSPOT_DIR entirely?" "n"; then
            rm -rf -- "$HOTSPOT_DIR"
            info "Removed $HOTSPOT_DIR"
        else
            warn "$HOTSPOT_DIR preserved"
        fi
    else
        info "$HOTSPOT_DIR does not exist"
    fi

    # Logs
    step "Logs"
    if compgen -G "${LOG_FILE}*" >/dev/null; then
        if confirm "Remove ${LOG_FILE} and rotated archives?" "n"; then
            rm -f -- "${LOG_FILE}" "${LOG_FILE}".*
            info "Logs removed"
        else
            warn "Logs preserved"
        fi
    else
        info "No log files found"
    fi

    echo ""
    echo "══════════════════════════════════════════════════════"
    echo "  Uninstall complete."
    echo ""
    echo "  IMPORTANT: Firewall rules and ipsets (macgrace, machotspot)"
    echo "  were NOT touched. Flush them manually if needed:"
    echo "    sudo ipset destroy macgrace 2>/dev/null"
    echo "    sudo ipset destroy machotspot 2>/dev/null"
    echo "    # then flush related iptables rules"
    echo "══════════════════════════════════════════════════════"
    echo ""
}

# ─── Usage ───────────────────────────────────────────────────────────────────
usage() {
    cat <<EOF
Usage: sudo bash $(basename "$0") [OPTION]

Modes:
  (none)         Install uhotspot (default). Aborts if already installed —
                 use --update or --remove instead. Also aborts if the
                 detected UniFi Network version (package "unifi", classic
                 or embedded in unifi-os) is below the minimum tested
                 (>= 10.4.57).
  --update       Update scripts only (preserves config, ACLs, firewall).
  --remove       Uninstall uhotspot (interactive, with confirmations).
  --help, -h     Show this help.

Run from inside the cloned uhotspot repository. See the README for details.
EOF
}

# ─── Preflight (runs unconditionally, before any mode is dispatched) ─────────
preflight() {
    # root check
    if [[ "$(id -u)" != "0" ]]; then
        echo "ERROR: This script must be run as root"
        exit 1
    fi

    # prevent overlapping runs
    local script_lock="/var/lock/$(basename "$0" .sh).lock"
    exec 200>"$script_lock"
    if ! flock -n 200; then
        echo "Script $(basename "$0") is already running"
        exit 1
    fi

}

# ─── Dispatch ────────────────────────────────────────────────────────────────
main() {
    case "${1:-}" in
        --help|-h|help)
            usage
            exit 0
            ;;
    esac

    preflight

    case "${1:-}" in
        ""|install)
            detect_local_user
            check_apt_deps
            detect_dhcp_backend
            do_install
            ;;
        --update|update)
            detect_local_user
            check_apt_deps
            detect_dhcp_backend
            do_update
            ;;
        --remove|remove|--uninstall|uninstall)
            do_remove
            ;;
        *)
            err "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
}

main "$@"
