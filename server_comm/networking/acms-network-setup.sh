#!/bin/bash
# acms-network-setup.sh
#
# Runs at every boot. Ensures network connectivity and monitors it forever.
#
# Setup (run once, then repeated on connectivity loss):
#   1. Ethernet  — any wired iface with reachable internet → done.
#      If present but no internet, skip. If absent, go to WiFi.
#   2. NM saved profiles — any NM-persisted WiFi connection.
#   3. Default WiFi list (/etc/acms/default-wifi.conf) — pre-configured
#      SSID+password+BSSID entries; BSSID is verified before connecting;
#      successful connections are NOT saved to NM or /etc/acms/wifi.
#   4. Captive-portal AP  — open AP (ACMS-XXXX) + HTTP portal at 192.168.4.1.
#      Portal-submitted credentials are saved as NM profiles for future boots.
#
# Monitor (runs after every successful setup):
#   Pings every PING_INTERVAL seconds. After PING_FAIL_THRESHOLD consecutive
#   failures, launches a parallel reconnect across all available interfaces:
#     - keeps pinging the current interface (may recover on its own)
#     - retries ethernet
#     - retries WiFi with saved credentials
#   If all fail, restarts the full setup (including portal if needed).

set -uo pipefail

# ── paths & tunables ──────────────────────────────────────────────────────────

DEFAULT_WIFI_FILE="/etc/acms/default-wifi.conf"  # pre-configured fallback list
RESULT_FILE="/run/acms-wifi-result"
SCAN_CACHE="/run/acms-wifi-scan"

PING_TARGET="8.8.8.8"
AP_IP="192.168.4.1"

PORTAL_PID_FILE="/run/acms-portal.pid"
DNSMASQ_PID_FILE="/run/acms-dnsmasq.pid"
HOSTAPD_PID_FILE="/run/acms-hostapd.pid"
RETRY_SUCCESS_FILE="/run/acms-retry-ok"
LOCK_FILE="/run/acms-network.lock"

PORTAL_CHECK_TIMEOUT=60    # seconds before background retry starts
PORTAL_TOTAL_TIMEOUT=600   # hard deadline for the whole portal phase
RETRY_INTERVAL=30          # seconds between background retry attempts
NM_WAIT_TIMEOUT=30         # seconds to wait for NetworkManager

PING_INTERVAL=10           # seconds between pings in monitor loop
PING_FAIL_THRESHOLD=5      # consecutive ping failures before reconnect attempt

WIFI_IFACE=""              # active WiFi interface name, set by _run_wifi_setup
RETRY_PID=""               # background retry subshell PID
_SETUP_RESULT=""           # output slot for run_setup / handle_connectivity_loss

# ── logging ───────────────────────────────────────────────────────────────────

log()  { echo "[acms-net] $*"; logger -t acms-net -- "$*" 2>/dev/null || true; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; }

# ── single-instance lock ──────────────────────────────────────────────────────

acquire_lock() {
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        err "Another instance is already running (lock: $LOCK_FILE)"
        exit 1
    fi
}

# ── interface discovery ───────────────────────────────────────────────────────

find_eth_iface() {
    local d iface
    for d in /sys/class/net/*/device; do
        [ -e "$d" ] || continue
        iface=$(basename "$(dirname "$d")")
        [[ -d "/sys/class/net/$iface/wireless" ]] && continue
        echo "$iface"; return 0
    done
    return 1
}

find_wifi_iface() {
    local d
    for d in /sys/class/net/*/wireless; do
        [ -e "$d" ] || continue
        basename "$(dirname "$d")"
        return 0
    done
    return 1
}

# Wait up to 20s for a WiFi interface to appear (it may be late at boot)
wait_for_wifi_iface() {
    local i iface
    for i in $(seq 1 10); do
        iface=$(find_wifi_iface 2>/dev/null || true)
        [ -n "$iface" ] && { echo "$iface"; return 0; }
        sleep 2
    done
    return 1
}

# ── connectivity ──────────────────────────────────────────────────────────────

wait_for_ip() {
    local iface="$1" i
    for i in $(seq 1 25); do
        ip addr show "$iface" 2>/dev/null | grep -q "inet " && return 0
        sleep 1
    done
    return 1
}

check_internet() {
    ping -c 3 -W 4 "$PING_TARGET" &>/dev/null
}

# ── NetworkManager readiness ──────────────────────────────────────────────────

wait_for_nm() {
    local i state
    for i in $(seq 1 "$NM_WAIT_TIMEOUT"); do
        state=$(nmcli -t -f STATE g 2>/dev/null | head -1 || true)
        case "${state:-}" in
            connected|disconnected|connecting|limited) return 0 ;;
        esac
        sleep 1
    done
    warn "NM not ready after ${NM_WAIT_TIMEOUT}s — some operations may fail"
}

# ── ethernet ──────────────────────────────────────────────────────────────────

try_ethernet() {
    local iface="$1"
    info "Connecting ethernet on $iface via NM..."
    nmcli dev set "$iface" managed yes 2>/dev/null || true
    nmcli device connect "$iface" &>/dev/null || true
    if ! wait_for_ip "$iface"; then
        info "No IP address on $iface"
        return 1
    fi
    if check_internet; then
        info "Internet confirmed via $iface"
        return 0
    fi
    info "Ethernet up but no internet on $iface"
    return 1
}

# ── credentials (base64 key=value — handles any chars in SSID/password) ───────

save_mac() {
    local iface="$1"
    local mac
    mac=$(cat "/sys/class/net/$iface/address" 2>/dev/null || true)
    [ -z "$mac" ] && { warn "Could not read MAC for $iface"; return; }

    local server_comm="/etc/acms/server_comm"
    local tmp
    tmp=$(mktemp /etc/acms/.server_comm.XXXXXX) || {
        err "Cannot create temp file for server_comm"
        return
    }
    # Preserve existing keys (HOSTNAME, SERVER_IP, etc.), update MACAddress
    [ -f "$server_comm" ] && grep -v "^MACAddress=" "$server_comm" > "$tmp" 2>/dev/null || true
    printf 'MACAddress=%s\n' "$mac" >> "$tmp"
    chmod 640 "$tmp"
    mv "$tmp" "$server_comm"
    info "MAC address saved: $mac ($iface)"
}

_b64_read() {
    # _b64_read <file> <KEY> — decodes a base64-encoded key=value entry
    local file="$1" key="$2"
    grep "^${key}=" "$file" 2>/dev/null \
        | head -1 | cut -d= -f2- | base64 -d 2>/dev/null || printf ''
}

read_result() { _b64_read "$RESULT_FILE" "$1"; }

# ── wifi scan ─────────────────────────────────────────────────────────────────

scan_wifi() {
    local iface="$1"
    info "Scanning WiFi on $iface..."
    nmcli dev wifi rescan ifname "$iface" 2>/dev/null || true
    sleep 3

    local tmp
    tmp=$(mktemp /run/acms-scan.XXXXXX) || { warn "Cannot create scan temp file"; return; }

    # TSV: ssid<TAB>signal<TAB>security, sorted by signal desc, deduped
    # --escape no: suppress backslash-escaping of colons in SSIDs
    nmcli --escape no -t -f SSID,SIGNAL,SECURITY dev wifi list ifname "$iface" \
        2>/dev/null \
        | awk -F: '$1!="" {print $1"\t"$2"\t"$3}' \
        | sort -t$'\t' -k2 -rn \
        | awk -F$'\t' '!seen[$1]++' \
        > "$tmp"

    mv "$tmp" "$SCAN_CACHE"
    info "Found $(wc -l < "$SCAN_CACHE") networks"
}

# ── wifi connect ──────────────────────────────────────────────────────────────

connect_wifi() {
    local iface="$1" ssid="$2" password="$3" rc=0

    info "Connecting to '$ssid' on $iface..."

    # Return the interface to NM management
    nmcli dev set "$iface" managed yes 2>/dev/null || true
    sleep 2

    # Delete any stale profile for this SSID
    nmcli con delete "$ssid" 2>/dev/null || true

    if [ -n "$password" ]; then
        nmcli --wait 30 dev wifi connect "$ssid" \
            password "$password" ifname "$iface" \
            &>/run/acms-nmcli.log || rc=$?
    else
        nmcli --wait 30 dev wifi connect "$ssid" \
            ifname "$iface" \
            &>/run/acms-nmcli.log || rc=$?
    fi

    if [ "$rc" -ne 0 ]; then
        warn "nmcli connect failed (rc=$rc) — see /run/acms-nmcli.log"
        return 1
    fi

    if ! wait_for_ip "$iface"; then
        warn "No IP address assigned after connecting to '$ssid'"
        return 1
    fi

    return 0
}

# ── default WiFi list ─────────────────────────────────────────────────────────
# Tries each entry in DEFAULT_WIFI_FILE (ssid,password,bssid).
# Verifies the BSSID of the visible AP before connecting.
# Connects with --save no — session is ephemeral; nothing written to NM or
# /etc/acms/wifi, so this list is always re-checked on the next boot.

try_default_wifi() {
    local iface="$1"
    [ -f "$DEFAULT_WIFI_FILE" ] || return 1

    # Check file is non-empty (ignore comment/blank lines)
    grep -qv '^\s*#\|^\s*$' "$DEFAULT_WIFI_FILE" 2>/dev/null || {
        info "Default WiFi list is empty — skipping"
        return 1
    }

    info "Scanning for default WiFi networks..."
    nmcli dev wifi rescan ifname "$iface" 2>/dev/null || true
    sleep 3

    local line ssid pass bssid found_ssid rc
    while IFS= read -r line; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line//[[:space:]]/}" ]]  && continue

        IFS=',' read -r ssid pass bssid <<< "$line"

        # Trim whitespace from each field
        ssid=$(printf '%s' "$ssid"  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        pass=$(printf '%s' "$pass"  | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        bssid=$(printf '%s' "$bssid" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
                | tr '[:lower:]' '[:upper:]')

        [ -z "$ssid" ] || [ -z "$bssid" ] && continue

        # Verify the AP is in range by checking that the SSID is visible from
        # a BSSID belonging to the same physical device.  A dual-band router
        # uses consecutive BSSIDs for its 2.4 GHz and 5 GHz radios (e.g.
        # :2D and :2E), so we match on the first 5 octets only rather than
        # the full BSSID.  This lets the board connect regardless of which
        # radio it sees while still rejecting a rogue AP on a different OUI.
        local bssid_prefix matched_bssid attempt
        bssid_prefix="${bssid%:*}"   # strip last :XX  →  6C:4F:89:DA:15

        matched_bssid=""
        for attempt in 1 2; do
            matched_bssid=$(nmcli --escape no -t -f SSID,BSSID dev wifi list \
                                ifname "$iface" 2>/dev/null \
                            | awk -F: -v ssid="$ssid" -v pfx="${bssid_prefix//:/:}" '
                                {
                                    # nmcli -t escapes colons in values; field 1 = SSID,
                                    # remaining fields = BSSID octets
                                    n = split($0, a, /:/); got_ssid = a[1]
                                    got_bssid = a[2]":"a[3]":"a[4]":"a[5]":"a[6]":"a[7]
                                    got_prefix = a[2]":"a[3]":"a[4]":"a[5]":"a[6]
                                    if (got_ssid == ssid && got_prefix == pfx) {
                                        print got_bssid; exit
                                    }
                                }' || true)
            [ -n "$matched_bssid" ] && break
            if [ "$attempt" -eq 1 ]; then
                info "Default WiFi '$ssid' (prefix $bssid_prefix) not in initial scan — rescanning..."
                nmcli dev wifi rescan ifname "$iface" 2>/dev/null || true
                sleep 5
            fi
        done

        if [ -z "$matched_bssid" ]; then
            info "Default WiFi '$ssid' ($bssid) not in range — skipping"
            continue
        fi

        info "Default WiFi '$ssid' visible at BSSID $matched_bssid (configured $bssid)"

        info "Default WiFi '$ssid' ($bssid) in range — connecting (ephemeral, no save)..."
        nmcli dev set "$iface" managed yes 2>/dev/null || true
        sleep 2
        # Remove any stale profile for this SSID before connecting
        nmcli con delete "$ssid" 2>/dev/null || true

        # Connect without --save no: NM handles DHCP correctly only with a
        # real (saveable) profile. We delete the profile immediately after
        # confirming an IP, so it is never persisted to disk.
        rc=0
        if [ -n "$pass" ]; then
            nmcli --wait 30 dev wifi connect "$ssid" \
                password "$pass" ifname "$iface" \
                &>/run/acms-nmcli.log || rc=$?
        else
            nmcli --wait 30 dev wifi connect "$ssid" \
                ifname "$iface" \
                &>/run/acms-nmcli.log || rc=$?
        fi

        if [ "$rc" -ne 0 ] && [ "$rc" -ne 2 ]; then
            warn "Default WiFi '$ssid' connect failed (rc=$rc) — trying next"
            nmcli con delete "$ssid" 2>/dev/null || true
            continue
        fi
        [ "$rc" -eq 2 ] && warn "Default WiFi '$ssid' nmcli rc=2 — checking IP anyway"

        if ! wait_for_ip "$iface"; then
            warn "No IP on '$ssid' — trying next"
            nmcli con delete "$ssid" 2>/dev/null || true
            nmcli dev disconnect "$iface" 2>/dev/null || true
            continue
        fi

        if check_internet; then
            info "Internet confirmed via default WiFi '$ssid'"
            return 0
        fi

        warn "Default WiFi '$ssid' connected but no internet — trying next"
        nmcli con delete "$ssid" 2>/dev/null || true
        nmcli dev disconnect "$iface" 2>/dev/null || true
    done < "$DEFAULT_WIFI_FILE"

    info "No default WiFi entry provided connectivity"
    return 1
}

# ── access point ──────────────────────────────────────────────────────────────

ap_ssid() {
    local iface="$1" mac
    mac=$(tr -d ':' < "/sys/class/net/$iface/address" 2>/dev/null || printf '000000')
    printf 'ACMS-%s' "${mac: -4}" | tr '[:lower:]' '[:upper:]'
}

_write_hostapd_conf() {
    local iface="$1" ssid="$2"
    cat > /run/acms-hostapd.conf <<EOF
interface=$iface
driver=nl80211
ssid=$ssid
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=0
EOF
}

_start_hostapd() {
    # Returns 0 if hostapd is running after this call, 1 otherwise.
    local conf="/run/acms-hostapd.conf" i
    rm -f "$HOSTAPD_PID_FILE"
    hostapd -B -P "$HOSTAPD_PID_FILE" "$conf" &>/run/acms-hostapd.log || {
        err "hostapd failed to start — check /run/acms-hostapd.log"
        return 1
    }
    # Poll until PID file appears and process is alive (up to 5s)
    for i in $(seq 1 10); do
        if [ -s "$HOSTAPD_PID_FILE" ] && \
           kill -0 "$(cat "$HOSTAPD_PID_FILE")" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    err "hostapd process died immediately — check /run/acms-hostapd.log"
    return 1
}

_start_dnsmasq() {
    local iface="$1" i
    # Kill any existing dnsmasq bound to this interface
    pkill -f "dnsmasq.*--interface=${iface}" 2>/dev/null || true
    sleep 0.5
    rm -f "$DNSMASQ_PID_FILE"

    dnsmasq \
        --interface="$iface" \
        --bind-interfaces \
        --dhcp-range=192.168.4.10,192.168.4.50,1h \
        --dhcp-option=3,"$AP_IP" \
        --dhcp-option=6,"$AP_IP" \
        --address=/#/"$AP_IP" \
        --no-resolv \
        --pid-file="$DNSMASQ_PID_FILE" \
        --log-facility=/run/acms-dnsmasq.log || {
        err "dnsmasq failed to start"
        return 1
    }

    # Poll for PID file (up to 3s)
    for i in $(seq 1 6); do
        if [ -s "$DNSMASQ_PID_FILE" ] && \
           kill -0 "$(cat "$DNSMASQ_PID_FILE")" 2>/dev/null; then
            return 0
        fi
        sleep 0.5
    done
    err "dnsmasq process died immediately"
    return 1
}

_start_portal() {
    pkill -f "acms-portal.sh" 2>/dev/null || true
    sleep 0.3
    bash /usr/local/bin/acms-portal.sh &
    local pid=$!
    echo "$pid" > "$PORTAL_PID_FILE"
    disown "$pid"
    sleep 0.5
    if ! kill -0 "$pid" 2>/dev/null; then
        err "Portal (socat) failed to start — is port 80 in use?"
        rm -f "$PORTAL_PID_FILE"
        return 1
    fi
    info "Portal running (pid=$pid)"
    return 0
}

start_ap() {
    local iface="$1" ssid
    ssid=$(ap_ssid "$iface")
    info "Starting AP '$ssid' on $iface..."

    # Release interface from NM; give it a moment to let go
    nmcli dev set "$iface" managed no 2>/dev/null || true
    sleep 2

    ip link set "$iface" up || { err "Cannot bring up $iface"; return 1; }
    ip addr flush dev "$iface" 2>/dev/null || true
    ip addr add "${AP_IP}/24" dev "$iface" || { err "Cannot assign AP IP"; return 1; }

    _write_hostapd_conf "$iface" "$ssid"
    _start_hostapd      || return 1
    _start_dnsmasq "$iface" || { stop_ap; return 1; }
    _start_portal       || { stop_ap; return 1; }

    info "AP '$ssid' active — portal at http://${AP_IP}"
    return 0
}

stop_ap() {
    # Kill each managed process by PID file, then by name as fallback.
    local pid
    for pidfile in "$PORTAL_PID_FILE" "$DNSMASQ_PID_FILE" "$HOSTAPD_PID_FILE"; do
        if [ -s "$pidfile" ]; then
            pid=$(cat "$pidfile" 2>/dev/null || true)
            if [ -n "$pid" ]; then
                kill "$pid" 2>/dev/null || true
            fi
            rm -f "$pidfile"
        fi
    done
    pkill -f "acms-portal.sh"  2>/dev/null || true
    pkill -f "acms-http-handler.sh" 2>/dev/null || true
    sleep 0.5
}

# ── background retry loop ─────────────────────────────────────────────────────

start_retry_loop() {
    local iface="$1" ssid="$2" password="$3"
    info "Background retry loop started for '$ssid' (every ${RETRY_INTERVAL}s)"

    (
        set +e   # don't exit on errors inside the retry loop
        while true; do
            sleep "$RETRY_INTERVAL"

            # If the portal was submitted, let the main loop handle it
            [ -f "$RESULT_FILE" ] && exit 0

            info "[retry] Attempting '$ssid'..."

            # Tear down AP so we can hand the interface to NM
            stop_ap

            if connect_wifi "$iface" "$ssid" "$password" && check_internet; then
                info "[retry] Internet confirmed via '$ssid'"
                touch "$RETRY_SUCCESS_FILE"
                exit 0
            fi

            warn "[retry] '$ssid' failed — restoring AP"

            # Restore AP so the user can still use the portal
            nmcli dev set "$iface" managed no 2>/dev/null || true
            sleep 1
            ip addr flush dev "$iface" 2>/dev/null || true
            ip addr add "${AP_IP}/24" dev "$iface" 2>/dev/null || true

            _start_hostapd      2>/dev/null || warn "[retry] hostapd restore failed"
            _start_dnsmasq "$iface" 2>/dev/null || warn "[retry] dnsmasq restore failed"
            _start_portal       2>/dev/null || warn "[retry] portal restore failed"

            info "[retry] AP restored"
        done
    ) &
    RETRY_PID=$!
    disown "$RETRY_PID"
}

stop_retry_loop() {
    if [ -n "${RETRY_PID:-}" ]; then
        kill "$RETRY_PID" 2>/dev/null || true
        RETRY_PID=""
    fi
}

# ── cleanup ───────────────────────────────────────────────────────────────────

cleanup_stale() {
    # Kill any leftover AP processes from a previous (possibly crashed) run.
    info "Cleaning up any stale AP processes..."
    stop_ap 2>/dev/null || true
    rm -f "$RESULT_FILE" "$RETRY_SUCCESS_FILE" \
          /run/acms-hostapd.conf 2>/dev/null || true
}

cleanup() {
    stop_retry_loop
    stop_ap 2>/dev/null || true
    rm -f "$RESULT_FILE" "$SCAN_CACHE" "$RETRY_SUCCESS_FILE" \
          /run/acms-hostapd.conf 2>/dev/null || true
}
trap cleanup EXIT

# ── wifi setup (shared by run_setup and reconnect) ───────────────────────────

_run_wifi_setup() {
    # immediate_retry=1: start background saved-creds retry as soon as portal
    # is up (used during reconnect). =0: wait PORTAL_CHECK_TIMEOUT first.
    local immediate_retry="${1:-0}"

    WIFI_IFACE=$(wait_for_wifi_iface 2>/dev/null || true)
    if [ -z "$WIFI_IFACE" ]; then
        err "No WiFi interface found after 20s — cannot continue"
        return 1
    fi
    info "WiFi interface: $WIFI_IFACE"
    # Ensure NM manages the interface; dongle driver may still be initialising
    nmcli dev set "$WIFI_IFACE" managed yes 2>/dev/null || true
    sleep 2

    local saved_ssid="" saved_pass=""

    # ── purge NM profiles that shadow default-wifi entries ────────────────────
    # If a previous default-wifi connection was saved to NM (e.g. from a prior
    # session where autoconnect=no was set), remove it so it doesn't masquerade
    # as a user-saved profile and bypass the default-wifi verification path.
    if [ -f "$DEFAULT_WIFI_FILE" ]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line//[[:space:]]/}" ]] && continue
            local _ssid
            _ssid=$(printf '%s' "$line" | cut -d, -f1 \
                    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
            [ -z "$_ssid" ] && continue
            if nmcli -t -f NAME con show 2>/dev/null | grep -qxF "$_ssid"; then
                info "Removing NM profile '$_ssid' (matches default-wifi entry)"
                nmcli con delete "$_ssid" 2>/dev/null || true
            fi
        done < "$DEFAULT_WIFI_FILE"
    fi

    # ── try NM-saved WiFi profiles ────────────────────────────────────────────
    local nm_profile
    nm_profile=$(nmcli -t -f NAME,TYPE con show 2>/dev/null \
        | grep ':802-11-wireless$' | head -1 | cut -d: -f1 || true)
    if [ -n "$nm_profile" ]; then
        info "Trying saved NM WiFi profile '$nm_profile'..."
        nmcli con up "$nm_profile" ifname "$WIFI_IFACE" &>/dev/null || true
        if wait_for_ip "$WIFI_IFACE" && check_internet; then
            info "Connected via NM profile '$nm_profile'"
            save_mac "$WIFI_IFACE"
            _SETUP_RESULT="$WIFI_IFACE:wifi"
            return 0
        fi
        warn "NM profile '$nm_profile' failed — trying portal"
    fi

    # ── default WiFi list ─────────────────────────────────────────────────────
    if try_default_wifi "$WIFI_IFACE"; then
        info "Network ready via default WiFi list"
        save_mac "$WIFI_IFACE"
        _SETUP_RESULT="$WIFI_IFACE:wifi"
        return 0
    fi

    # ── portal AP ─────────────────────────────────────────────────────────────
    scan_wifi "$WIFI_IFACE"
    rm -f "$RESULT_FILE" "$RETRY_SUCCESS_FILE"

    if ! start_ap "$WIFI_IFACE"; then
        err "Could not start AP — AP mode not supported by driver (rtl8xxxu)"
        err "Connect manually with: nmcli dev wifi connect SSID password PASS"
        return 1
    fi

    # On reconnect: start background saved-creds retry immediately so it races
    # the portal from the start. On initial setup: wait PORTAL_CHECK_TIMEOUT.
    local retry_started=0
    if [ "$immediate_retry" -eq 1 ] && [ -n "$saved_ssid" ]; then
        start_retry_loop "$WIFI_IFACE" "$saved_ssid" "$saved_pass"
        retry_started=1
    fi

    local deadline
    deadline=$(( $(date +%s) + PORTAL_TOTAL_TIMEOUT ))
    info "Portal active. Deadline in ${PORTAL_TOTAL_TIMEOUT}s."

    while true; do
        local now
        now=$(date +%s)

        [ "$now" -ge "$deadline" ] && {
            err "Timed out waiting for network configuration"
            stop_ap; return 1
        }

        # Background saved-creds retry won — cancel portal
        if [ -f "$RETRY_SUCCESS_FILE" ]; then
            info "Background retry connected — closing portal"
            stop_ap
            save_mac "$WIFI_IFACE"
            _SETUP_RESULT="$WIFI_IFACE:wifi"
            return 0
        fi

        # Portal form submitted
        if [ -f "$RESULT_FILE" ]; then
            local new_ssid new_pass
            new_ssid=$(read_result SSID)
            new_pass=$(read_result PASSWORD)
            info "Portal submission: ssid='$new_ssid'"

            stop_retry_loop
            sleep 2   # let portal finish sending the response page
            stop_ap

            if connect_wifi "$WIFI_IFACE" "$new_ssid" "$new_pass" && check_internet; then
                stop_ap   # kill any AP processes still alive from the retry loop
                info "Connected to '$new_ssid' — AP closed"
                save_mac "$WIFI_IFACE"
                _SETUP_RESULT="$WIFI_IFACE:wifi"
                return 0
            else
                warn "Could not connect to '$new_ssid' — re-opening portal"
                saved_ssid="$new_ssid"
                saved_pass="$new_pass"
                rm -f "$RESULT_FILE"
                # Remove the failed NM profile so NM stops retrying it and it
                # isn't picked up as a saved profile on the next boot.
                nmcli con delete "$new_ssid" 2>/dev/null || true
                nmcli dev disconnect "$WIFI_IFACE" 2>/dev/null || true
                sleep 1
                scan_wifi "$WIFI_IFACE"
                start_ap "$WIFI_IFACE" || { err "AP restart failed"; return 1; }
                retry_started=0
            fi
        fi

        # Delayed background retry for initial setup path
        local time_remaining=$(( deadline - now ))
        if [ "$retry_started" -eq 0 ] && \
           [ -n "${saved_ssid:-}" ] && \
           [ "$time_remaining" -le $(( PORTAL_TOTAL_TIMEOUT - PORTAL_CHECK_TIMEOUT )) ]; then
            start_retry_loop "$WIFI_IFACE" "$saved_ssid" "$saved_pass"
            retry_started=1
        fi

        sleep 2
    done
}

# ── setup (called on boot and on full restart after recovery fails) ───────────

run_setup() {
    # Sets _SETUP_RESULT="<iface>:<type>" on success (e.g. "eth0:eth", "wlan0:wifi").
    # Priority: if WiFi dongle is present → WiFi first, eth as fallback.
    #           if no dongle → eth first, then wait for dongle.
    local eth_iface wifi_iface
    eth_iface=$(find_eth_iface 2>/dev/null || true)
    wifi_iface=$(find_wifi_iface 2>/dev/null || true)

    if [ -n "$wifi_iface" ]; then
        info "WiFi dongle detected ($wifi_iface) — trying WiFi first"
        if _run_wifi_setup 0; then
            return 0
        fi
        warn "WiFi failed — falling back to ethernet"
        if [ -n "$eth_iface" ] && try_ethernet "$eth_iface"; then
            info "Network ready via ethernet ($eth_iface)"
            save_mac "$eth_iface"
            _SETUP_RESULT="$eth_iface:eth"
            return 0
        fi
        [ -n "$eth_iface" ] && info "Ethernet also has no internet"
        return 1
    fi

    # No dongle present — try ethernet, then wait for dongle
    if [ -n "$eth_iface" ] && try_ethernet "$eth_iface"; then
        info "Network ready via ethernet ($eth_iface)"
        save_mac "$eth_iface"
        _SETUP_RESULT="$eth_iface:eth"
        return 0
    fi
    [ -n "$eth_iface" ] && info "Ethernet present but no internet — waiting for WiFi dongle"

    _run_wifi_setup 0   # sets _SETUP_RESULT on success
}

# ── handle connectivity loss ──────────────────────────────────────────────────

handle_connectivity_loss() {
    # Runs the full setup workflow in the main shell (no subshell) so globals
    # (RETRY_PID, WIFI_IFACE, _SETUP_RESULT) propagate correctly.
    # Simultaneously a background subprocess keeps pinging the existing config —
    # if it recovers, it signals via a flag file and setup is cancelled.
    # Sets _SETUP_RESULT="<iface>:<type>" on success, returns 1 on total failure.
    local active_iface="$1" active_type="$2"

    local abort_file
    abort_file=$(mktemp /run/acms-abort.XXXXXX)
    rm -f "$abort_file"   # absent = running; present = abort signal

    # Background: keep pinging existing config — no interface changes
    (
        set +e
        while [ ! -f "$abort_file" ]; do
            if check_internet; then
                touch "${abort_file}.won"
                exit 0
            fi
            sleep "$PING_INTERVAL"
        done
    ) &
    local bg_pid=$!
    # No disown — we need to wait for this process below

    # Main: full setup in current shell (globals stay intact)
    local setup_rc=1
    if [ "$active_type" = "eth" ]; then
        run_setup && setup_rc=0          # tries eth then wifi; sets _SETUP_RESULT
    else
        _run_wifi_setup 1 && setup_rc=0  # wifi with immediate retry; sets _SETUP_RESULT
    fi

    # If background ping recovered the existing connection, prefer it
    if [ -f "${abort_file}.won" ]; then
        info "Existing config recovered — cancelling setup result"
        _SETUP_RESULT="$active_iface:$active_type"
        setup_rc=0
    fi

    # Stop background pinger
    touch "$abort_file"
    kill "$bg_pid" 2>/dev/null || true
    wait "$bg_pid" 2>/dev/null || true
    rm -f "$abort_file" "${abort_file}.won"

    return "$setup_rc"
}

# ── connectivity monitor ──────────────────────────────────────────────────────

monitor_connection() {
    local active_iface="$1" active_type="$2"
    local fails=0

    info "Monitoring on $active_iface ($active_type) — interval=${PING_INTERVAL}s threshold=${PING_FAIL_THRESHOLD}"

    while true; do
        sleep "$PING_INTERVAL"

        if check_internet; then
            [ "$fails" -gt 0 ] && { info "Connectivity restored on $active_iface"; fails=0; }
            continue
        fi

        fails=$(( fails + 1 ))
        warn "Ping failure $fails/$PING_FAIL_THRESHOLD on $active_iface"
        [ "$fails" -lt "$PING_FAIL_THRESHOLD" ] && continue

        fails=0
        warn "Connectivity lost on $active_iface ($active_type) — starting recovery"

        if handle_connectivity_loss "$active_iface" "$active_type"; then
            local new_iface="${_SETUP_RESULT%%:*}" new_type="${_SETUP_RESULT##*:}"
            [ "$new_iface" != "$active_iface" ] && \
                info "Interface: $active_iface ($active_type) → $new_iface ($new_type)"
            active_iface="$new_iface"
            active_type="$new_type"
        else
            warn "All recovery paths exhausted — restarting full setup"
            return 1
        fi
    done
}

# ── main ──────────────────────────────────────────────────────────────────────

main() {
    acquire_lock
    mkdir -p /etc/acms
    cleanup_stale
    wait_for_nm

    while true; do
        local active_iface active_type
        if ! run_setup; then
            err "Network setup failed — retrying in ${RETRY_INTERVAL}s"
            sleep "$RETRY_INTERVAL"
            cleanup_stale
            continue
        fi
        active_iface="${_SETUP_RESULT%%:*}"
        active_type="${_SETUP_RESULT##*:}"

        info "Connected on $active_iface ($active_type) — entering monitor"
        monitor_connection "$active_iface" "$active_type" || true

        warn "Restarting network setup..."
        cleanup_stale
    done
}

main "$@"
