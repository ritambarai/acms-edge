#!/bin/sh
#
# test_scheduler.sh — scheduler first-boot integration test
#
# Compiles server_scheduler with paths redirected to a temp directory,
# places mock core_id / send_state / state_wait scripts, then runs the
# scheduler and verifies the expected state transitions:
#
#   First boot (no board_state):
#     → scheduler creates board_state  stateCode=2  (Board_Registration)
#     → spawns core_id  (mock: writes dummy CoreID + filePath)
#     → spawns send_state stateCode=2  (mock: writes stateCode=1 to server_response)
#     → scheduler reads server_response, updates board_state to stateCode=1
#
#   Second cycle (stateCode=1 = Waiting):
#     → spawns state_wait  (mock: exits immediately)
#     → spawns send_state stateCode=1  (mock: writes stateCode=1 again)
#     → board_state stays stateCode=1
#
# Usage:
#   ./tests/test_scheduler.sh
#   ./tests/test_scheduler.sh -v   # verbose: show scheduler log on failure

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MAKEFILE_DIR="$SCRIPT_DIR/.."
STATE_TABLE_SRC="$SCRIPT_DIR/../../master-metadata/state_table"

TEST_DIR="/tmp/acms_sched_test_$$"
ACMS_DIR="$TEST_DIR/acms"
BIN_DIR="$TEST_DIR/bin"
SCHED_BIN="$TEST_DIR/server_scheduler"
SCHED_LOG="$TEST_DIR/scheduler.log"
CALL_LOG="$TEST_DIR/calls.log"

SCHED_PID=""
PASS=0; FAIL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; BOLD='\033[1m'; NC='\033[0m'

pass() { PASS=$((PASS+1)); printf "${GREEN}PASS${NC}  %s\n" "$1"; }
fail() { FAIL=$((FAIL+1)); printf "${RED}FAIL${NC}  %s\n       → %s\n" "$1" "$2"; }

cleanup() {
    [ -n "$SCHED_PID" ] && kill "$SCHED_PID" 2>/dev/null; wait "$SCHED_PID" 2>/dev/null
    if [ "$FAIL" -gt 0 ] && [ "$VERBOSE" = "1" ]; then
        printf "\n--- scheduler log ---\n"; cat "$SCHED_LOG" 2>/dev/null
        printf "\n--- call log ---\n";      cat "$CALL_LOG" 2>/dev/null
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# ── wait_for: poll until condition is true or timeout ─────────────────────────
# wait_for <description> <shell-condition> [timeout_secs]
wait_for() {
    _desc="$1"; _cond="$2"; _max="${3:-10}"
    _i=0
    while [ "$_i" -lt "$_max" ]; do
        eval "$_cond" 2>/dev/null && return 0
        sleep 1
        _i=$((_i + 1))
    done
    return 1
}

# ── setup ─────────────────────────────────────────────────────────────────────

mkdir -p "$ACMS_DIR" "$BIN_DIR"
cp "$STATE_TABLE_SRC" "$ACMS_DIR/state_table"

# ── compile test scheduler ────────────────────────────────────────────────────

printf "${BOLD}=== compiling test scheduler ===${NC}\n"
if ! make -C "$MAKEFILE_DIR" test-scheduler TEST_SCHED_DIR="$TEST_DIR" \
        --no-print-directory 2>&1; then
    echo "FATAL: could not compile test scheduler — aborting" >&2
    exit 1
fi
echo "Compiled: $SCHED_BIN"

# ── mock binaries ─────────────────────────────────────────────────────────────
#
# Each mock records its name (and args) to CALL_LOG so tests can verify
# which binaries were invoked and in what order.

DUMMY_CORE_ID="DEADBEEFCAFE1234DEADBEEFCAFE1234"

# mock core_id: write dummy CoreID to server_comm, filePath to board_state
cat > "$BIN_DIR/core_id" << MOCK_CORE_ID
#!/bin/sh
printf 'CoreID=$DUMMY_CORE_ID\n' > "$ACMS_DIR/server_comm"
# preserve stateCode from board_state, append filePath
_sc=\$(grep '^stateCode=' "$ACMS_DIR/board_state" 2>/dev/null | head -1)
printf '%s\nfilePath=$ACMS_DIR/server_comm\n' "\$_sc" > "$ACMS_DIR/board_state"
echo "core_id" >> "$CALL_LOG"
exit 0
MOCK_CORE_ID

# mock send_state: always respond with stateCode=1 (Waiting)
cat > "$BIN_DIR/send_state" << MOCK_SEND_STATE
#!/bin/sh
printf 'stateCode=1\n' > "$ACMS_DIR/server_response"
echo "send_state \$*" >> "$CALL_LOG"
exit 0
MOCK_SEND_STATE

# mock state_wait: return immediately (real one sleeps 15s for Waiting)
cat > "$BIN_DIR/state_wait" << MOCK_STATE_WAIT
#!/bin/sh
echo "state_wait \$*" >> "$CALL_LOG"
exit 0
MOCK_STATE_WAIT

# mock install_package: should never be called in this test
cat > "$BIN_DIR/install_package" << MOCK_INSTALL
#!/bin/sh
echo "install_package \$*" >> "$CALL_LOG"
echo "[TEST] ERROR: install_package was unexpectedly called" >&2
exit 1
MOCK_INSTALL

chmod +x "$BIN_DIR/core_id" "$BIN_DIR/send_state" \
         "$BIN_DIR/state_wait" "$BIN_DIR/install_package"

touch "$CALL_LOG"

# ── launch scheduler ──────────────────────────────────────────────────────────

printf "\n${BOLD}=== scheduler first-boot tests ===${NC}\n"

# Verify no board_state exists (true first boot)
T="S00 pre-condition: no board_state on disk"
if [ ! -f "$ACMS_DIR/board_state" ]; then pass "$T"
else fail "$T" "board_state already exists: $(cat "$ACMS_DIR/board_state")"; fi

"$SCHED_BIN" > "$SCHED_LOG" 2>&1 &
SCHED_PID=$!
echo "Scheduler pid=$SCHED_PID"

# ── cycle 1: Board_Registration (stateCode=2) ─────────────────────────────────

T="S01 scheduler creates board_state with stateCode=2 on first boot"
# Check scheduler log — the message is printed before the first cycle completes
if wait_for "$T" 'grep -q "created board_state (stateCode=2)" "$SCHED_LOG"'; then
    pass "$T"
else fail "$T" "sched log: $(cat "$SCHED_LOG" 2>/dev/null || echo missing)"; fi

T="S02 core_id ran and wrote dummy CoreID to server_comm"
if wait_for "$T" 'grep -q "CoreID=$DUMMY_CORE_ID" "$ACMS_DIR/server_comm"'; then
    pass "$T"
else fail "$T" "server_comm: $(cat "$ACMS_DIR/server_comm" 2>/dev/null || echo missing)"; fi

T="S03 scheduler forwarded filePath contents (CoreID) to send_state"
# The scheduler reads filePath from board_state and passes its key=value pairs
# as kwargs to send_state.  Verify CoreID appears in the send_state invocation.
if wait_for "$T" 'grep -q "send_state stateCode=2 CoreID=" "$CALL_LOG"'; then
    pass "$T"
else fail "$T" "call log: $(cat "$CALL_LOG" 2>/dev/null || echo empty)"; fi

T="S04 send_state called with stateCode=2 for Board_Registration"
if wait_for "$T" 'grep -q "send_state stateCode=2" "$CALL_LOG"'; then
    pass "$T"
else fail "$T" "call log: $(cat "$CALL_LOG" 2>/dev/null || echo empty)"; fi

T="S05 server_response written with stateCode=1"
if wait_for "$T" 'grep -q "^stateCode=1$" "$ACMS_DIR/server_response"'; then
    pass "$T"
else fail "$T" "server_response: $(cat "$ACMS_DIR/server_response" 2>/dev/null || echo missing)"; fi

T="S06 board_state advanced to stateCode=1 (Waiting) after server response"
if wait_for "$T" 'grep -q "^stateCode=1$" "$ACMS_DIR/board_state"' 15; then
    pass "$T"
else fail "$T" "board_state: $(cat "$ACMS_DIR/board_state" 2>/dev/null || echo missing)"; fi

# ── cycle 2: Waiting (stateCode=1) ───────────────────────────────────────────

T="S07 state_wait spawned for stateCode=1 (Waiting)"
if wait_for "$T" 'grep -q "^state_wait" "$CALL_LOG"'; then
    pass "$T"
else fail "$T" "call log: $(cat "$CALL_LOG" 2>/dev/null || echo empty)"; fi

T="S08 send_state called with stateCode=1 in Waiting cycle"
if wait_for "$T" 'grep -c "send_state stateCode=1" "$CALL_LOG" | grep -qv "^0$"'; then
    pass "$T"
else fail "$T" "call log: $(cat "$CALL_LOG" 2>/dev/null || echo empty)"; fi

T="S09 board_state stays stateCode=1 after second server response"
if wait_for "$T" 'grep -q "^stateCode=1$" "$ACMS_DIR/board_state"'; then
    pass "$T"
else fail "$T" "board_state: $(cat "$ACMS_DIR/board_state" 2>/dev/null || echo missing)"; fi

T="S10 install_package was never called (no url in server response)"
if ! grep -q "install_package" "$CALL_LOG" 2>/dev/null; then pass "$T"
else fail "$T" "install_package appears in call log: $(grep install_package "$CALL_LOG")"; fi

# ── summary ───────────────────────────────────────────────────────────────────

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
TOTAL=$((PASS + FAIL))
printf "Results: ${GREEN}%d passed${NC} / ${RED}%d failed${NC} / %d total\n" \
    "$PASS" "$FAIL" "$TOTAL"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"

[ "$FAIL" -eq 0 ]
