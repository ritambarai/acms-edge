#!/bin/bash
# acms-http-handler.sh
#
# Per-connection HTTP handler called by socat for each client.
# Reads HTTP request from stdin, writes HTTP response to stdout.
#
# Security limits:
#   - POST body capped at MAX_BODY_BYTES
#   - SSID capped at 32 bytes (WiFi spec)
#   - Control characters stripped from all inputs

RESULT_FILE="/run/acms-wifi-result"
SCAN_CACHE="/run/acms-wifi-scan"
AP_IP="192.168.4.1"
MAX_BODY_BYTES=4096   # cap POST body to prevent DoS hangs

# ── helpers ───────────────────────────────────────────────────────────────────

urldecode() {
    local v="${1//+/ }"
    # Replace %XX with \xXX, then let printf expand them.
    # Invalid sequences are left as-is (printf -b is forgiving).
    printf '%b' "${v//%/\\x}" 2>/dev/null || printf '%s' "$v"
}

html_esc() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    s="${s//\"/&quot;}"
    printf '%s' "$s"
}

strip_ctrl() {
    # Remove ASCII control characters (0x00-0x1f, 0x7f) except space
    printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177'
}

b64enc() { printf '%s' "$1" | base64 -w0; }

# ── HTTP response helpers ─────────────────────────────────────────────────────

send_redirect() {
    printf 'HTTP/1.0 302 Found\r\nLocation: http://%s/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n' \
        "$AP_IP"
}

send_html() {
    local body="$1"
    local len
    len=$(printf '%s' "$body" | wc -c)
    printf 'HTTP/1.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: %d\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n' \
        "$len"
    printf '%s' "$body"
}

# ── SSID option list ──────────────────────────────────────────────────────────

ssid_options() {
    # Read SCAN_CACHE into memory first to avoid TOCTOU issues
    local cache_content=""
    [ -f "$SCAN_CACHE" ] && cache_content=$(cat "$SCAN_CACHE" 2>/dev/null || true)
    [ -z "$cache_content" ] && return

    while IFS=$'\t' read -r ssid signal security; do
        [ -z "$ssid" ] && continue
        local esc info=""
        esc=$(html_esc "$ssid")
        [ -n "$signal"   ] && info="${signal}%"
        [ -n "$security" ] && info="${info:+$info, }${security}"
        [ -n "$info"     ] && info=" ($info)"
        printf '      <option value="%s">%s%s</option>\n' "$esc" "$esc" "$info"
    done <<< "$cache_content"
}

# ── portal page ───────────────────────────────────────────────────────────────

portal_page() {
    local status_html="${1:-}"
    local opts
    opts=$(ssid_options)

    cat <<HTML
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>ACMS Gateway Setup</title>
  <style>
    *,*::before,*::after{box-sizing:border-box}
    body{font-family:system-ui,sans-serif;background:#f0f2f5;
         display:flex;justify-content:center;padding:32px 16px}
    .card{background:#fff;border-radius:10px;padding:28px 24px;
          width:100%;max-width:420px;box-shadow:0 2px 12px rgba(0,0,0,.1)}
    h1{margin:0 0 6px;font-size:1.3em;color:#1a1a2e}
    p.sub{margin:0 0 24px;font-size:.85em;color:#666}
    label{display:block;font-size:.85em;font-weight:600;color:#444;margin-bottom:4px}
    input,select{display:block;width:100%;padding:9px 11px;
                 border:1px solid #ccc;border-radius:6px;
                 font-size:1em;margin-bottom:16px}
    input:focus,select:focus{outline:none;border-color:#07c;
                              box-shadow:0 0 0 3px rgba(0,119,204,.15)}
    button{width:100%;padding:11px;background:#0077cc;color:#fff;border:none;
           border-radius:6px;font-size:1em;cursor:pointer;font-weight:600}
    button:hover{background:#005fa3}
    .status{margin-top:16px;padding:11px 14px;border-radius:6px;font-size:.88em;line-height:1.4}
    .ok{background:#d4edda;color:#155724}
    .err{background:#f8d7da;color:#721c24}
    .pw-wrap{position:relative;margin-bottom:16px}
    .pw-wrap input{margin-bottom:0;padding-right:42px}
    .pw-eye{position:absolute;right:10px;top:50%;transform:translateY(-50%);
            background:none;border:none;cursor:pointer;padding:4px;
            color:#888;display:flex;align-items:center;user-select:none}
    .pw-eye:hover{color:#333}
  </style>
</head>
<body>
<div class="card">
  <h1>ACMS Gateway Setup</h1>
  <p class="sub">Connect this device to a WiFi network.</p>
  <form method="POST" action="/connect">
    <label for="ss">WiFi Network</label>
    <select id="ss" name="ssid">
$opts
      <option value="__manual__">— Enter manually —</option>
    </select>

    <label for="sm">Manual SSID <span style="font-weight:400">(if not listed)</span></label>
    <input id="sm" name="ssid_manual" placeholder="Network name" maxlength="32">

    <label for="pw">Password</label>
    <div class="pw-wrap">
      <input id="pw" name="password" type="password"
             placeholder="Leave blank for open networks">
      <button type="button" class="pw-eye" id="eye"
              onmousedown="document.getElementById('pw').type='text'"
              onmouseup="document.getElementById('pw').type='password'"
              onmouseleave="document.getElementById('pw').type='password'"
              ontouchstart="document.getElementById('pw').type='text'"
              ontouchend="document.getElementById('pw').type='password'"
              aria-label="Hold to reveal password">
        <svg id="eye-open" xmlns="http://www.w3.org/2000/svg" width="20" height="20"
             viewBox="0 0 24 24" fill="none" stroke="currentColor"
             stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
          <path d="M1 12s4-8 11-8 11 8 11 8-4 8-11 8-11-8-11-8z"/>
          <circle cx="12" cy="12" r="3"/>
        </svg>
      </button>
    </div>

    <button type="submit">Connect &amp; Save</button>
  </form>
  $status_html
</div>
</body>
</html>
HTML
}

# ── parse request ─────────────────────────────────────────────────────────────

IFS= read -r req_line || exit 0   # exit cleanly on EOF / connection reset
req_line="${req_line%$'\r'}"

METHOD="${req_line%% *}"
tmp="${req_line#* }"
PATH_REQ="${tmp%% *}"
PATH_CLEAN="${PATH_REQ%%\?*}"

CONTENT_LENGTH=0
while IFS= read -r hdr_line; do
    hdr_line="${hdr_line%$'\r'}"
    [ -z "$hdr_line" ] && break
    key="${hdr_line%%:*}"
    val="${hdr_line#*: }"
    case "${key,,}" in
        content-length)
            # Accept only numeric values; ignore otherwise
            [[ "$val" =~ ^[0-9]+$ ]] && CONTENT_LENGTH="$val"
            ;;
    esac
done

# ── captive-portal detection ──────────────────────────────────────────────────

case "$PATH_CLEAN" in
    /hotspot-detect.html|/library/test/success.html|\
    /generate_204|/ncsi.txt|/connecttest.txt|\
    /redirect|/canonical.html|/success.txt)
        send_redirect
        exit 0
        ;;
esac

# ── GET / ─────────────────────────────────────────────────────────────────────

if [ "$METHOD" = "GET" ]; then
    send_html "$(portal_page)"
    exit 0
fi

# ── POST /connect ─────────────────────────────────────────────────────────────

if [ "$METHOD" = "POST" ] && [ "$PATH_CLEAN" = "/connect" ]; then
    # Cap read length to prevent indefinite hang on large/malicious payloads
    local_len=$CONTENT_LENGTH
    [ "$local_len" -gt "$MAX_BODY_BYTES" ] && local_len=$MAX_BODY_BYTES

    raw=""
    if [ "$local_len" -gt 0 ]; then
        raw=$(head -c "$local_len" 2>/dev/null || true)
    fi

    declare -A F
    IFS='&' read -ra pairs <<< "$raw"
    for pair in "${pairs[@]}"; do
        k=$(urldecode "${pair%%=*}")
        v=$(urldecode "${pair#*=}")
        # Only record known keys to prevent memory exhaustion
        case "$k" in
            ssid|ssid_manual|password)
                F["$k"]="$v" ;;
        esac
    done

    ssid=$(strip_ctrl "${F[ssid]:-}")
    ssid_manual=$(strip_ctrl "${F[ssid_manual]:-}")
    ssid_manual="${ssid_manual:0:32}"
    password="${F[password]:-}"

    [ "$ssid" = "__manual__" ] && ssid="$ssid_manual"
    ssid="${ssid:0:32}"

    if [ -z "$ssid" ]; then
        send_html "$(portal_page \
            '<div class="status err">Please select or enter a WiFi network name.</div>')"
        exit 0
    fi

    # Write result atomically (temp file + rename)
    local tmp
    tmp=$(mktemp "${RESULT_FILE}.XXXXXX") || {
        send_html "$(portal_page \
            '<div class="status err">Internal error — please try again.</div>')"
        exit 1
    }
    {
        printf 'SSID=%s\n'     "$(b64enc "$ssid")"
        printf 'PASSWORD=%s\n' "$(b64enc "$password")"
    } > "$tmp" && mv "$tmp" "$RESULT_FILE" || {
        rm -f "$tmp"
        send_html "$(portal_page \
            '<div class="status err">Internal error writing config — please try again.</div>')"
        exit 1
    }

    ssid_esc=$(html_esc "$ssid")
    send_html "$(portal_page \
        "<div class=\"status ok\"><strong>Connecting to ${ssid_esc}…</strong><br>
        The access point will close shortly. Check the device console for status.</div>")"
    exit 0
fi

# ── fallback ──────────────────────────────────────────────────────────────────
send_redirect
