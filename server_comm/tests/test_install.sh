#!/bin/sh
#
# test_install.sh — ACMS install-package test suite
#
# Tests build_package and install_package for correctness and error handling.
# Safe to run on the host — system daemons are never touched:
#   - A mock systemctl (no-op) is prepended to PATH so stop/start_daemons
#     iterate an empty daemon list and call nothing real.
#   - ACMS_DIR is redirected to a temp directory.
#   - Full-install packages install files to /tmp paths (no root needed).
#
# Usage:
#   ./tests/test_install.sh
#   ./tests/test_install.sh -v   # verbose: show all script output

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_PKG="$SCRIPT_DIR/../../build_package"
INSTALL_PKG_ORIG="$SCRIPT_DIR/../exec/install_package"
TEST_DIR="/tmp/acms_tests_$$"

PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

pass() { PASS=$((PASS+1)); printf "${GREEN}PASS${NC}  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${RED}FAIL${NC}  %s\n       → %s\n" "$1" "$2"; }

cleanup() { rm -rf "$TEST_DIR"; }
trap cleanup EXIT

mkdir -p "$TEST_DIR"

log() { [ "$VERBOSE" = "1" ] && printf "      %s\n" "$1" || true; }

# ── Patch install_package: redirect ACMS_DIR only (systemctl is mocked via PATH) ──

TEST_ACMS_DIR="$TEST_DIR/acms"
mkdir -p "$TEST_ACMS_DIR"

INSTALL_PKG="$TEST_DIR/install_package"
sed "s|ACMS_DIR=\"/etc/acms\"|ACMS_DIR=\"$TEST_ACMS_DIR\"|" \
    "$INSTALL_PKG_ORIG" > "$INSTALL_PKG"
chmod +x "$INSTALL_PKG"

# ── Mock executables ───────────────────────────────────────────────────────────

MOCK_BIN="$TEST_DIR/mock_bin"
mkdir -p "$MOCK_BIN"

# mock systemctl: always exits 0, prints nothing
# → stop_daemons() gets empty list-units output → DAEMON_LIST stays empty
# → start_daemons() iterates empty DAEMON_LIST → no real calls
cat > "$MOCK_BIN/systemctl" << 'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$MOCK_BIN/systemctl"

# mock wget: real wget may not support file:// on all hosts.
# This wrapper handles file:// by copying the file directly; all other
# protocols are forwarded to the real wget found outside MOCK_BIN.
REAL_WGET="$(PATH="${PATH#"$MOCK_BIN:"}" command -v wget 2>/dev/null || echo wget)"
cat > "$MOCK_BIN/wget" << WEOF
#!/bin/sh
# Parse -q --timeout=N -O <dest> <url>
_out=""; _url=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        -O)          _out="\$2"; shift 2 ;;
        --timeout=*) shift ;;
        -q)          shift ;;
        *)           _url="\$1"; shift ;;
    esac
done
case "\$_url" in
    file://*)
        _path="\${_url#file://}"
        if [ -f "\$_path" ]; then cp "\$_path" "\$_out"; exit 0
        else echo "wget: cannot open '\$_path': No such file" >&2; exit 1; fi ;;
    *)
        $REAL_WGET -q --timeout=60 -O "\$_out" "\$_url" ;;
esac
WEOF
chmod +x "$MOCK_BIN/wget"

run_patched() {
    _rp_out=$(PATH="$MOCK_BIN:$PATH" "$INSTALL_PKG" "$@" 2>&1)
    _rp_rc=$?
    log "$_rp_out"
    printf '%s' "$_rp_out"
    return $_rp_rc
}

# Real state_table for reference (OTA=7)
REAL_STATE_TABLE="$SCRIPT_DIR/../state_table"

# Reset ACMS dir state before each install test.
# Copies the real state_table so install_package can resolve OTA's stateCode by key name.
reset_acms() {
    rm -rf "$TEST_ACMS_DIR"
    mkdir -p "$TEST_ACMS_DIR"
    printf 'stateCode=7\n' > "$TEST_ACMS_DIR/board_state"
    cp "$REAL_STATE_TABLE" "$TEST_ACMS_DIR/state_table"
}

# ── Helper: build a minimal valid .ipk with files going to /tmp/ paths ────────
#
# Files in data.tar.gz are placed under /tmp/acms_test_data_$$/
# so install_package can copy them without root.
#
# make_ipk <output.ipk> <install_sh_content>
make_ipk() {
    _out="$1"; _install_sh="$2"
    _build="$TEST_DIR/ipk_build_$$_$(date +%N)"
    _data_dest="/tmp/acms_test_data_$$"

    mkdir -p "$_build/data$_data_dest"
    printf 'test_key=test_val\n' > "$_build/data$_data_dest/test_config"

    mkdir -p "$_build/control"
    printf '%s\n' "$_install_sh" > "$_build/control/install.sh"
    chmod +x "$_build/control/install.sh"

    _tmp="$TEST_DIR/ipk_tmp_$$_$(date +%N)"
    mkdir -p "$_tmp"
    printf '2.0\n' > "$_tmp/debian-binary"
    ( cd "$_build/data"    && tar -czf "$_tmp/data.tar.gz"    . )
    ( cd "$_build/control" && tar -czf "$_tmp/control.tar.gz" . )
    ( cd "$_tmp" && ar rcs "$(realpath "$_out")" debian-binary control.tar.gz data.tar.gz )

    rm -rf "$_build" "$_tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
printf "${BOLD}=== build_package tests ===${NC}\n"
# ══════════════════════════════════════════════════════════════════════════════

# T01: no args → defaults to packages/ (errors if packages/ absent in CWD)
T="T01 build_package: no args → defaults to packages/ input dir"
T01_WD="$TEST_DIR/t01_wd"; mkdir -p "$T01_WD"   # dir with no packages/ subdir
out=$(cd "$T01_WD" && "$BUILD_PKG" 2>&1); rc=$?
log "$out"
if [ $rc -ne 0 ] && echo "$out" | grep -qi "not found"; then pass "$T"
else fail "$T" "rc=$rc  out=$out"; fi

# T02: non-existent directory → error
T="T02 build_package: non-existent dir → error"
out=$("$BUILD_PKG" /nonexistent_acms_test_xyz 2>&1); rc=$?
log "$out"
if [ $rc -ne 0 ] && echo "$out" | grep -qi "not found"; then pass "$T"
else fail "$T" "rc=$rc  out=$out"; fi

# T03: file classification — ELF→bin, .sh→bin, .service→systemd, plain→acms
T="T03 build_package: file classification"
PKG_DIR="$TEST_DIR/pkg_classify"
mkdir -p "$PKG_DIR"
cp /bin/true "$PKG_DIR/my_tool"                                            # real ELF binary
printf '#!/bin/sh\necho hello\n' > "$PKG_DIR/my_script.sh"                # shell script
printf '[Unit]\nDescription=Test\n[Service]\nExecStart=/bin/true\n' \
    > "$PKG_DIR/my.service"                                                # systemd unit
printf 'KEY=val\n' > "$PKG_DIR/my_config"                                  # plain config

out=$("$BUILD_PKG" "$PKG_DIR" 2>&1); rc=$?
log "$out"
if [ $rc -eq 0 ] \
    && echo "$out" | grep -q "usr/local/bin/my_tool" \
    && echo "$out" | grep -q "usr/local/bin/my_script.sh" \
    && echo "$out" | grep -q "etc/systemd/system/my.service" \
    && echo "$out" | grep -q "etc/acms/my_config"; then
    pass "$T"
else fail "$T" "rc=$rc\n$out"; fi

# T04: generated install.sh has chmod, systemctl enable, and stateCode
T="T04 build_package: generated install.sh content correct"
if [ -f "$PKG_DIR/install.sh" ] \
    && grep -q "chmod +x /usr/local/bin/my_tool"      "$PKG_DIR/install.sh" \
    && grep -q "chmod +x /usr/local/bin/my_script.sh" "$PKG_DIR/install.sh" \
    && grep -q "systemctl enable my.service"           "$PKG_DIR/install.sh" \
    && grep -q "stateCode=%s"                           "$PKG_DIR/install.sh" \
    && grep -q "' 0 >"                                 "$PKG_DIR/install.sh"; then
    pass "$T"
else
    fail "$T" "$(cat "$PKG_DIR/install.sh" 2>/dev/null || echo 'install.sh missing')"
fi

# T05: output .ipk is a valid ar archive with required members
T="T05 build_package: output .ipk is valid ar with debian-binary/data/control"
IPK="$TEST_DIR/test.ipk"
out=$("$BUILD_PKG" "$PKG_DIR" "$IPK" 2>&1); rc=$?
log "$out"
if [ $rc -eq 0 ] && [ -f "$IPK" ]; then
    magic=$(dd if="$IPK" bs=1 count=7 2>/dev/null)
    members=$(ar t "$IPK" 2>/dev/null)
    if printf '%s' "$magic" | grep -q '!<arch>' \
        && echo "$members" | grep -q '^debian-binary$' \
        && echo "$members" | grep -q '^data\.tar' \
        && echo "$members" | grep -q '^control\.tar'; then
        pass "$T"
    else
        fail "$T" "magic or members wrong; members='$members'"
    fi
else fail "$T" "rc=$rc  out=$out"; fi

# T05 cleared PKG_DIR — T06 onwards uses a fresh dir or just install.sh
# T06: existing install.sh is preserved (not overwritten, dry-run so no clear)
T="T06 build_package: existing install.sh preserved (dry-run)"
CUSTOM="# my custom install — do not overwrite"
printf '%s\n' "$CUSTOM" > "$PKG_DIR/install.sh"
out=$("$BUILD_PKG" "$PKG_DIR" 2>&1)   # dry-run: no output arg → no clear
log "$out"
content=$(cat "$PKG_DIR/install.sh")
if echo "$content" | grep -q "custom install" \
    && echo "$out" | grep -qi "preserved\|existing"; then
    pass "$T"
else fail "$T" "install.sh was overwritten; content='$content'"; fi

# T06b: -f flag regenerates install.sh even when one already exists (dry-run)
T="T06b build_package: -f regenerates install.sh, discards manual edits"
out=$("$BUILD_PKG" -f "$PKG_DIR" 2>&1)
log "$out"
content=$(cat "$PKG_DIR/install.sh")
if ! echo "$content" | grep -q "custom install" \
    && echo "$out" | grep -qi "regenerat"; then
    pass "$T"
else fail "$T" "install.sh not regenerated; content='$content'  out=$out"; fi

# T06c: unknown flag → error + exit 1
T="T06c build_package: unknown flag → error+exit1"
out=$("$BUILD_PKG" -z "$PKG_DIR" 2>&1); rc=$?
log "$out"
if [ $rc -ne 0 ] && echo "$out" | grep -qi "unknown option\|usage"; then pass "$T"
else fail "$T" "rc=$rc  out=$out"; fi

# T07: stateCode override (arg 3) reflected in packed install.sh
T="T07 build_package: stateCode=3 override in packed install.sh"
PKG2="$TEST_DIR/pkg_sc3"; mkdir -p "$PKG2"
printf 'KEY=val\n' > "$PKG2/cfg_file"
SC3_IPK="$TEST_DIR/sc3.ipk"
"$BUILD_PKG" "$PKG2" "$SC3_IPK" 3 > /dev/null 2>&1
CHECK="$TEST_DIR/ctrl_sc3_check"; mkdir -p "$CHECK"
( cd "$CHECK" && ar x "$SC3_IPK" control.tar.gz 2>/dev/null \
    && tar -xzf control.tar.gz 2>/dev/null )
if grep -q "' 3 >" "$CHECK/install.sh" 2>/dev/null; then pass "$T"
else fail "$T" "$(cat "$CHECK/install.sh" 2>/dev/null || echo 'no install.sh in package')"; fi

# T07b: input dir is cleared (all files removed) after successful pack
T="T07b build_package: input dir cleared after pack"
PKG_CLR="$TEST_DIR/pkg_clear"; mkdir -p "$PKG_CLR"
printf 'key=val\n' > "$PKG_CLR/cfg"
"$BUILD_PKG" "$PKG_CLR" "$TEST_DIR/clear.ipk" > /dev/null 2>&1
remaining=$(ls "$PKG_CLR" 2>/dev/null | wc -l)
if [ "$remaining" -eq 0 ]; then pass "$T"
else fail "$T" "files still present: $(ls "$PKG_CLR")"; fi

# T07c: -c without output arg → error
T="T07c build_package: -c without output arg → error"
PKG_CE="$TEST_DIR/pkg_ce"; mkdir -p "$PKG_CE"
printf 'cfg=val\n' > "$PKG_CE/cfg"
out=$("$BUILD_PKG" -c "$PKG_CE" 2>&1); rc=$?
log "$out"
if [ $rc -ne 0 ] && echo "$out" | grep -qi "requires"; then pass "$T"
else fail "$T" "rc=$rc  out=$out"; fi

# T07d: -c saves archives/<stem>.sh and <stem>.csv with correct content
T="T07d build_package: -c writes archives/<stem>.sh and <stem>.csv"
PKG_ARC="$TEST_DIR/pkg_arc"; mkdir -p "$PKG_ARC"
cp /bin/true "$PKG_ARC/arc_bin"
printf '#!/bin/sh\necho hi\n' > "$PKG_ARC/arc_svc.sh"
printf 'cfg=val\n' > "$PKG_ARC/arc_cfg"
ARC_IPK="$TEST_DIR/arc_out.ipk"
ARC_DIR="$TEST_DIR/archives"
out=$(ACMS_ARCHIVE_DIR="$ARC_DIR" "$BUILD_PKG" -c "$PKG_ARC" "$ARC_IPK" 2>&1); rc=$?
log "$out"
if [ $rc -eq 0 ] \
    && [ -f "$ARC_DIR/arc_out.sh" ] \
    && [ -f "$ARC_DIR/arc_out.csv" ] \
    && grep -q "^filename,destination$"           "$ARC_DIR/arc_out.csv" \
    && grep -q "^arc_bin,/usr/local/bin/arc_bin$" "$ARC_DIR/arc_out.csv" \
    && grep -q "^arc_svc.sh,/usr/local/bin/arc_svc.sh$" "$ARC_DIR/arc_out.csv" \
    && grep -q "^arc_cfg,/etc/acms/arc_cfg$"      "$ARC_DIR/arc_out.csv"; then
    pass "$T"
else
    fail "$T" "rc=$rc  csv='$(cat "$ARC_DIR/arc_out.csv" 2>/dev/null || echo missing)'"
fi

# T07e: subdirectories in input dir are skipped (only top-level files packaged)
T="T07e build_package: subdirectories in input dir are ignored"
PKG_SUB="$TEST_DIR/pkg_sub"; mkdir -p "$PKG_SUB/subdir"
printf 'key=val\n' > "$PKG_SUB/top_cfg"
printf 'nested=val\n' > "$PKG_SUB/subdir/nested_cfg"
SUB_IPK="$TEST_DIR/sub.ipk"
out=$("$BUILD_PKG" "$PKG_SUB" "$SUB_IPK" 2>&1); rc=$?
log "$out"
# nested_cfg must not appear in build output or inside data.tar.gz
EXT_SUB="$TEST_DIR/sub_ext"; mkdir -p "$EXT_SUB"
( cd "$EXT_SUB" && ar x "$SUB_IPK" data.tar.gz 2>/dev/null \
    && tar -tzf data.tar.gz 2>/dev/null > "$EXT_SUB/data_list" )
if [ $rc -eq 0 ] \
    && ! echo "$out" | grep -q "nested_cfg" \
    && ! grep -q "nested_cfg" "$EXT_SUB/data_list"; then
    pass "$T"
else fail "$T" "nested file leaked into package; data list: $(cat "$EXT_SUB/data_list" 2>/dev/null)"; fi

# ══════════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}=== install_package error tests (exit before daemon ops — host safe) ===${NC}\n"
# ══════════════════════════════════════════════════════════════════════════════

# T08: no args → usage + exit 1 (no filesystem interaction)
T="T08 install_package: no args → usage+exit1"
out=$("$INSTALL_PKG" 2>&1); rc=$?
log "$out"
if [ $rc -ne 0 ] && echo "$out" | grep -qi "usage"; then pass "$T"
else fail "$T" "rc=$rc  out=$out"; fi

# T09: wget fails (connection refused to unused port) → download_failed
#      download is checked before stop_daemons — safe on host
#      The mock wget passes http:// through to real wget which fails quickly
T="T09 install_package: download failure → download_failed"
reset_acms
out=$(run_patched "http://127.0.0.1:19191/no.ipk"); rc=$?
if [ $rc -ne 0 ] && (echo "$out" | grep -qi "download_failed\|wget failed" \
    || grep -q "download_failed" "$TEST_ACMS_DIR/install_error" 2>/dev/null); then
    pass "$T"
else fail "$T" "rc=$rc  err=$(cat "$TEST_ACMS_DIR/install_error" 2>/dev/null)  out=$out"; fi

# T10: file is not an ar archive → invalid_package
#      format check is before stop_daemons — safe on host
T="T10 install_package: non-ar file → invalid_package"
reset_acms
NOT_AR="$TEST_DIR/not_ar.ipk"
printf 'this is not an ar archive\n' > "$NOT_AR"
out=$(run_patched "file://$NOT_AR"); rc=$?
if [ $rc -ne 0 ] && (echo "$out" | grep -qi "invalid_package\|not a valid opkg" \
    || grep -q "invalid_package" "$TEST_ACMS_DIR/install_error" 2>/dev/null); then
    pass "$T"
else fail "$T" "rc=$rc  err=$(cat "$TEST_ACMS_DIR/install_error" 2>/dev/null)  out=$out"; fi

# T11: ar archive missing data.tar → invalid_package
T="T11 install_package: ar without data.tar → invalid_package (missing data archive)"
reset_acms
NO_DATA="$TEST_DIR/no_data.ipk"
printf 'placeholder\n' > "$TEST_DIR/placeholder.txt"
ar rcs "$NO_DATA" "$TEST_DIR/placeholder.txt" 2>/dev/null
out=$(run_patched "file://$NO_DATA"); rc=$?
if [ $rc -ne 0 ] && (echo "$out" | grep -qi "invalid_package\|missing data" \
    || grep -q "invalid_package" "$TEST_ACMS_DIR/install_error" 2>/dev/null); then
    pass "$T"
else fail "$T" "rc=$rc  err=$(cat "$TEST_ACMS_DIR/install_error" 2>/dev/null)  out=$out"; fi

# T12: valid ar but corrupt data.tar.gz → extract_failed
#      tar extraction is before stop_daemons — safe on host
T="T12 install_package: corrupt data.tar.gz → extract_failed"
reset_acms
CORRUPT="$TEST_DIR/corrupt.ipk"
_tmp3="$TEST_DIR/corrupt_build"; mkdir -p "$_tmp3"
printf '2.0\n'       > "$_tmp3/debian-binary"
printf 'not a tar\n' > "$_tmp3/data.tar.gz"
printf 'not a tar\n' > "$_tmp3/control.tar.gz"
( cd "$_tmp3" && ar rcs "$(realpath "$CORRUPT")" debian-binary data.tar.gz control.tar.gz 2>/dev/null )
rm -rf "$_tmp3"
out=$(run_patched "file://$CORRUPT"); rc=$?
if [ $rc -ne 0 ] && (echo "$out" | grep -qi "extract_failed\|failed to extract" \
    || grep -q "extract_failed" "$TEST_ACMS_DIR/install_error" 2>/dev/null); then
    pass "$T"
else fail "$T" "rc=$rc  err=$(cat "$TEST_ACMS_DIR/install_error" 2>/dev/null)  out=$out"; fi

# ══════════════════════════════════════════════════════════════════════════════
printf "\n${BOLD}=== install_package full install (mock systemctl — host safe) ===${NC}\n"
# ══════════════════════════════════════════════════════════════════════════════

# T13: successful install — install.sh sets stateCode=3
T="T13 install_package: full success → stateCode=3 written to board_state"
reset_acms
GOOD_IPK="$TEST_DIR/good.ipk"
make_ipk "$GOOD_IPK" '#!/bin/sh
set -e
printf "stateCode=3\n" > "$ACMS_BOARD_STATE"
exit 0'
out=$(run_patched "file://$GOOD_IPK"); rc=$?
sc=$(grep '^stateCode=' "$TEST_ACMS_DIR/board_state" 2>/dev/null | cut -d= -f2)
if [ $rc -eq 0 ] && [ "$sc" = "3" ]; then pass "$T"
else fail "$T" "rc=$rc  stateCode='$sc' (want 3)  out=$out"; fi

# T14: install.sh exits non-zero → rollback + install_error written
T="T14 install_package: install.sh failure → rollback + install_failed in install_error"
reset_acms
FAIL_IPK="$TEST_DIR/fail.ipk"
make_ipk "$FAIL_IPK" '#!/bin/sh
exit 1'
out=$(run_patched "file://$FAIL_IPK"); rc=$?
if [ $rc -ne 0 ] \
    && (grep -q "install_failed" "$TEST_ACMS_DIR/install_error" 2>/dev/null \
        || echo "$out" | grep -qi "rolling back\|install_failed"); then
    pass "$T"
else fail "$T" "rc=$rc  err=$(cat "$TEST_ACMS_DIR/install_error" 2>/dev/null)  out=$out"; fi

# T15: stateCode=7 (OTA) reset to 0 after successful install (no error filePath)
T="T15 install_package: stateCode=6 (OTA) reset to 0 on clean success"
reset_acms
OTA_IPK="$TEST_DIR/ota.ipk"
make_ipk "$OTA_IPK" '#!/bin/sh
set -e
printf "stateCode=6\n" > "$ACMS_BOARD_STATE"
exit 0'
out=$(run_patched "file://$OTA_IPK"); rc=$?
sc=$(grep '^stateCode=' "$TEST_ACMS_DIR/board_state" 2>/dev/null | cut -d= -f2)
if [ $rc -eq 0 ] && [ "$sc" = "0" ]; then pass "$T"
else fail "$T" "rc=$rc  stateCode='$sc' (want 0)  out=$out"; fi

# T16: no install.sh in package, board_state has no stateCode → defaults to 0
T="T16 install_package: no install.sh + empty board_state → stateCode defaults to 0"
reset_acms
# Clear stateCode so the "default to 0" branch is exercised
printf '' > "$TEST_ACMS_DIR/board_state"
NO_SH_IPK="$TEST_DIR/no_sh.ipk"
_tmp4="$TEST_DIR/no_sh_build"; mkdir -p "$_tmp4"
_data_dest4="/tmp/acms_test_data_${$}_nosh"
mkdir -p "$_tmp4/data$_data_dest4"
printf 'key=val\n' > "$_tmp4/data$_data_dest4/myfile"
printf '2.0\n' > "$_tmp4/debian-binary"
( cd "$_tmp4/data" && tar -czf "$_tmp4/data.tar.gz" . )
( cd "$_tmp4" && ar rcs "$(realpath "$NO_SH_IPK")" debian-binary data.tar.gz 2>/dev/null )
rm -rf "$_tmp4"
out=$(run_patched "file://$NO_SH_IPK"); rc=$?
sc=$(grep '^stateCode=' "$TEST_ACMS_DIR/board_state" 2>/dev/null | cut -d= -f2)
if [ $rc -eq 0 ] && [ "$sc" = "0" ]; then pass "$T"
else fail "$T" "rc=$rc  stateCode='$sc' (want 0)  out=$out"; fi

# T17: rollback restores overwritten file
T="T17 install_package: rollback restores pre-install file content"
reset_acms
# plant a file where the package will install
_data_dest5="/tmp/acms_test_data_${$}_rollback"
mkdir -p "$_data_dest5"
printf 'original content\n' > "$_data_dest5/test_config"

ROLLBACK_IPK="$TEST_DIR/rollback.ipk"
make_ipk "$ROLLBACK_IPK" '#!/bin/sh
exit 1'   # force rollback
# Override make_ipk's data dest to match the file we planted
_rbuild="$TEST_DIR/rb_build"; mkdir -p "$_rbuild/data$_data_dest5"
printf 'overwritten content\n' > "$_rbuild/data$_data_dest5/test_config"
mkdir -p "$_rbuild/control"
printf '#!/bin/sh\nexit 1\n' > "$_rbuild/control/install.sh"
chmod +x "$_rbuild/control/install.sh"
_rtmp="$TEST_DIR/rb_tmp"; mkdir -p "$_rtmp"
printf '2.0\n' > "$_rtmp/debian-binary"
( cd "$_rbuild/data"    && tar -czf "$_rtmp/data.tar.gz"    . )
( cd "$_rbuild/control" && tar -czf "$_rtmp/control.tar.gz" . )
( cd "$_rtmp" && ar rcs "$(realpath "$ROLLBACK_IPK")" debian-binary control.tar.gz data.tar.gz )
rm -rf "$_rbuild" "$_rtmp"

out=$(run_patched "file://$ROLLBACK_IPK"); rc=$?
restored=$(cat "$_data_dest5/test_config" 2>/dev/null)
rm -rf "$_data_dest5"
if [ $rc -ne 0 ] && [ "$restored" = "original content" ]; then pass "$T"
else fail "$T" "rc=$rc  restored='$restored' (want 'original content')  out=$out"; fi

# ── Summary ───────────────────────────────────────────────────────────────────

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
TOTAL=$((PASS + FAIL))
printf "Results: ${GREEN}%d passed${NC} / ${RED}%d failed${NC} / %d total\n" \
    "$PASS" "$FAIL" "$TOTAL"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$FAIL" -eq 0 ]
