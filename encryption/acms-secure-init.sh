#!/bin/bash
# acms-secure-init.sh
#
# Runs as a systemd service early in boot — before acms-network-setup.
#
# First boot (temp key still active in LUKS):
#   1. Derives the board's unique key from the Allwinner A20 SID fuse.
#   2. Adds the SID-derived key to the LUKS2 root partition.
#   3. Removes the temporary build key from LUKS keyslots.
#   4. Securely wipes the temp key file from the filesystem.
#   5. Sets a unique root password and stores it in /etc/acms/server_comm.
#   The root partition is now permanently keyed to this specific board.
#
# Subsequent boots (SID key already in LUKS):
#   Verifies SID key unlocks LUKS and exits cleanly.
#   If SID key fails (should not happen on same board), logs an error and exits 1.
#
# Key derivation: SHA-256(hex(raw SID bytes)) → 32 binary bytes.
# The derived key is never stored; it is re-derived from hardware on each use.

set -euo pipefail

# Set to 1 at build time (via build.sh --debug) to also write the plaintext
# root password into server_comm for easier development/testing.
# NEVER set this in production builds.
DEBUG_SAVE_PASSWORD=0

LUKS_DEV="/dev/mmcblk0p2"
TEMP_KEY="/etc/acms/boot-temp-key"
SERVER_COMM="/etc/acms/server_comm"
REKEYED_FLAG="/etc/acms/.rekeyed"

SID_PATHS=(
    "/sys/bus/nvmem/devices/sunxi-sid0/nvmem"
    "/sys/devices/platform/soc/1c23800.sid/nvmem/sunxi-sid0/nvmem"
)

# ── helpers ───────────────────────────────────────────────────────────────────

log() { echo "[acms-secure] $*"; logger -t acms-secure -- "$*" 2>/dev/null || true; }
err() { log "ERROR: $*"; exit 1; }

read_chip_id() {
    for p in "${SID_PATHS[@]}"; do
        [ -r "$p" ] || continue
        local hex
        hex=$(xxd -p "$p" | tr -d '\n')
        # Reject all-zeroes SID (unprogrammed fuse)
        case "$hex" in *[1-9a-fA-F]*) ;; *) continue ;; esac
        printf '%s' "$hex"
        return 0
    done
    # Fallback: /proc/cpuinfo Serial
    local s
    s=$(grep -i "^serial" /proc/cpuinfo 2>/dev/null \
        | awk -F': ' '{print $2}' | tr -d ' \n' || true)
    [ -n "$s" ] && [ "$s" != "0000000000000000" ] && { printf '%s' "$s"; return 0; }
    err "cannot read chip SID — is sunxi-sid loaded?"
}

derive_key() {
    printf '%s' "$1" | sha256sum | awk '{print $1}' | xxd -r -p
}

# Seal the SID into a single storable value (SID_SEALED) and derive the
# root password from it.
#
# SID_SEALED = hex(SID_bytes XOR temp_key_bytes)   (key cycled if SID longer)
# ROOT_PWD   = SID_SEALED[:8]
#
# Server recovery (XOR is its own inverse):
#   SID_bytes = SID_SEALED_bytes XOR temp_key_bytes
#   password  = SID_SEALED[:8]
#
# Sets globals: ROOT_PWD  SID_SEALED
seal_sid() {
    local chip_hex="$1"
    local key_hex
    key_hex=$(xxd -p "$TEMP_KEY" | tr -d '\n')

    SID_SEALED=$(awk -v a="$chip_hex" -v b="$key_hex" 'BEGIN {
        na = length(a) / 2
        nb = length(b) / 2
        for (i = 0; i < na; i++) {
            ai = strtonum("0x" substr(a, i*2+1, 2))
            bi = strtonum("0x" substr(b, (i % nb)*2+1, 2))
            printf "%02x", xor(ai, bi)
        }
        print ""
    }')

    ROOT_PWD="${SID_SEALED:0:8}"
}

write_server_comm() {
    local key="$1" value="$2"
    mkdir -p "$(dirname "$SERVER_COMM")"
    if grep -q "^${key}=" "$SERVER_COMM" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$SERVER_COMM"
    else
        echo "${key}=${value}" >> "$SERVER_COMM"
    fi
}

# ── pre-flight ────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || err "must run as root"

for cmd in cryptsetup xxd sha256sum openssl chpasswd; do
    command -v "$cmd" &>/dev/null || err "$cmd not found"
done

cryptsetup isLuks "$LUKS_DEV" 2>/dev/null || \
    err "$LUKS_DEV is not a LUKS volume — full-root encryption may not be set up"

# ── subsequent boot: SID key already enrolled ─────────────────────────────────

if [ -f "$REKEYED_FLAG" ]; then
    # Root was already unlocked by the initramfs SID keyscript — the fact
    # that we are running proves the SID key is valid.  No need to re-verify
    # against the live LUKS device (which may hold an exclusive lock).
    log "Subsequent boot — SID key already enrolled, root unlocked by initramfs"
    [ -f "$TEMP_KEY" ] && { shred -u "$TEMP_KEY" 2>/dev/null || rm -f "$TEMP_KEY"; }
    exit 0
fi

# ── first boot: SID key not yet enrolled ─────────────────────────────────────

log "First boot — SID key not enrolled; performing LUKS re-keying..."

[ -f "$TEMP_KEY" ] || err "temp key not found at $TEMP_KEY — cannot re-key; reflash required"

chip_id=$(read_chip_id)
sid_key=$(derive_key "$chip_id")

# Secure tmpfs for SID key material (never touches persistent storage)
KEY_TMP=$(mktemp -d /run/acms-key-XXXXXX)
chmod 700 "$KEY_TMP"
SID_KEY_FILE="$KEY_TMP/sid.key"

cleanup_key_tmp() {
    [ -f "$SID_KEY_FILE" ] && { shred -u "$SID_KEY_FILE" 2>/dev/null || rm -f "$SID_KEY_FILE"; }
    rm -rf "$KEY_TMP" 2>/dev/null || true
}
trap cleanup_key_tmp EXIT

printf '%s' "$sid_key" > "$SID_KEY_FILE"
chmod 600 "$SID_KEY_FILE"

log "Adding SID key to LUKS..."
cryptsetup luksAddKey \
    --key-file="$TEMP_KEY" \
    "$LUKS_DEV" \
    "$SID_KEY_FILE" || err "failed to add SID key to LUKS"

log "Verifying SID key..."
printf '%s' "$sid_key" | cryptsetup luksOpen \
    --test-passphrase --key-file=- "$LUKS_DEV" 2>/dev/null || \
    err "SID key added but luksOpen test failed — aborting to preserve temp key"

log "Removing temp key from LUKS..."
cryptsetup luksRemoveKey \
    --key-file="$SID_KEY_FILE" \
    "$LUKS_DEV" \
    "$TEMP_KEY" || log "WARNING: failed to remove temp key — SID key is active but temp key remains"

# ── seal SID and set root password ───────────────────────────────────────────

seal_sid "$chip_id"   # sets ROOT_PWD and SID_SEALED

log "Setting root password..."
echo "root:${ROOT_PWD}" | chpasswd || log "WARNING: chpasswd failed"

log "Writing credentials to ${SERVER_COMM}..."
write_server_comm "SID_SEALED" "$SID_SEALED"
[ "$DEBUG_SAVE_PASSWORD" -eq 1 ] && write_server_comm "ROOT_PASSWORD" "$ROOT_PWD"
chmod 640 "$SERVER_COMM"

# ── finalise ─────────────────────────────────────────────────────────────────

log "Wiping temp key from filesystem..."
shred -u "$TEMP_KEY" 2>/dev/null || rm -f "$TEMP_KEY"

touch "$REKEYED_FLAG"
chmod 400 "$REKEYED_FLAG"

log "Re-keying complete — root partition permanently bound to this board's SID."
