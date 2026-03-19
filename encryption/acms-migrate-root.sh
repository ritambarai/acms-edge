#!/bin/bash
# acms-migrate-root.sh
#
# Run ONCE on the board (booted from USB or second SD card) to migrate
# the target SD card's root partition to LUKS encryption.
#
# What it does:
#   1. Reads chip ID from SID
#   2. Prompts for encryption password
#   3. rsync current root → tmpfs snapshot
#   4. Formats root partition as LUKS2 (keyed to SID + password)
#   5. Copies root back into encrypted partition
#   6. Updates /boot/armbianEnv.txt with acms_root= kernel arg
#
# Usage (as root, NOT running from the SD card being encrypted):
#   ./acms-migrate-root.sh /dev/mmcblk0      # target SD card

set -euo pipefail

TARGET_DISK="${1:-}"
BOOT_PART=""
ROOT_PART=""
MAP_NAME="cryptroot"
WORK_DIR="/tmp/acms-migrate"

SID_PATHS=(
    "/sys/bus/nvmem/devices/sunxi-sid0/nvmem"
    "/sys/devices/platform/soc/1c23800.sid/nvmem/sunxi-sid0/nvmem"
)

# ── helpers ───────────────────────────────────────────────────────────────────

read_chip_id() {
    for p in "${SID_PATHS[@]}"; do
        [ -r "$p" ] || continue
        xxd -p "$p" | tr -d '\n'
        return 0
    done
    echo "ERROR: cannot read chip ID" >&2; return 1
}

derive_key() {
    printf '%s%s' "$1" "$2" | sha256sum | awk '{print $1}' | xxd -r -p
}

cleanup() {
    echo "Cleaning up..."
    umount "$WORK_DIR/root_old" 2>/dev/null || true
    umount "$WORK_DIR/root_new" 2>/dev/null || true
    umount "$WORK_DIR/boot"     2>/dev/null || true
    cryptsetup luksClose "$MAP_NAME" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── checks ────────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

[ -n "$TARGET_DISK" ] || {
    echo "Usage: $0 <disk>   e.g. $0 /dev/mmcblk0"
    exit 1
}

[ -b "$TARGET_DISK" ] || { echo "ERROR: $TARGET_DISK not a block device"; exit 1; }

for cmd in cryptsetup xxd sha256sum rsync mkfs.ext4; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found"; exit 1; }
done

# Detect partition naming (mmcblk0 → mmcblk0p1, sda → sda1)
if [[ "$TARGET_DISK" == *mmcblk* ]] || [[ "$TARGET_DISK" == *nvme* ]]; then
    BOOT_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    BOOT_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

[ -b "$ROOT_PART" ] || { echo "ERROR: $ROOT_PART not found"; exit 1; }

# Ensure SD card is not the running root
RUNNING_ROOT=$(findmnt -n -o SOURCE /)
if [ "$RUNNING_ROOT" = "$ROOT_PART" ]; then
    echo "ERROR: $ROOT_PART is the currently running root."
    echo "  Boot from a USB drive or second SD card, then run this script."
    exit 1
fi

echo "=== ACMS Root Encryption Migration ==="
echo "Target disk : $TARGET_DISK"
echo "Boot part   : $BOOT_PART"
echo "Root part   : $ROOT_PART  ← will be reformatted as LUKS2"
echo ""
echo "WARNING: all data on $ROOT_PART will be re-encrypted."
echo "         Ensure you have a backup or are prepared for data loss on failure."
read -r -p "Type YES to continue: " confirm
[ "$confirm" = "YES" ] || { echo "Aborted."; exit 1; }

# ── read chip ID + password ───────────────────────────────────────────────────

CHIP_ID=$(read_chip_id)
echo "Chip ID: ${CHIP_ID:0:8}****"

read -r -s -p "Set encryption password: " PWD1; echo
read -r -s -p "Confirm password: "        PWD2; echo
[ "$PWD1" = "$PWD2" ] || { echo "ERROR: passwords do not match"; exit 1; }
[ -n "$PWD1" ]        || { echo "ERROR: password cannot be empty"; exit 1; }

KEY_BIN=$(derive_key "$CHIP_ID" "$PWD1")

# ── snapshot current root into tmpfs ─────────────────────────────────────────

mkdir -p "$WORK_DIR/root_old" "$WORK_DIR/root_new" "$WORK_DIR/boot"

echo "[1/6] Mounting current root..."
mount -o ro "$ROOT_PART" "$WORK_DIR/root_old"

ROOT_SIZE_KB=$(du -sk "$WORK_DIR/root_old" | awk '{print $1}')
TMPFS_SIZE=$(( (ROOT_SIZE_KB + 102400) / 1024 ))MB   # +100MB headroom

echo "[2/6] Copying root to tmpfs (${TMPFS_SIZE})..."
mount -t tmpfs -o size="$TMPFS_SIZE" tmpfs /tmp/acms-rootsnap 2>/dev/null || \
    mkdir -p /tmp/acms-rootsnap
rsync -aAX --exclude='/proc/*' --exclude='/sys/*' \
           --exclude='/dev/*'  --exclude='/run/*' \
    "$WORK_DIR/root_old/" /tmp/acms-rootsnap/

umount "$WORK_DIR/root_old"

# ── format as LUKS2 ───────────────────────────────────────────────────────────

echo "[3/6] Formatting $ROOT_PART as LUKS2..."
printf '%s' "$KEY_BIN" | cryptsetup luksFormat \
    --type luks2 \
    --key-file=- \
    "$ROOT_PART"

echo "[4/6] Opening LUKS volume..."
printf '%s' "$KEY_BIN" | cryptsetup luksOpen \
    --key-file=- \
    "$ROOT_PART" "$MAP_NAME"

mkfs.ext4 -q /dev/mapper/"$MAP_NAME"
mount /dev/mapper/"$MAP_NAME" "$WORK_DIR/root_new"

# ── restore root ──────────────────────────────────────────────────────────────

echo "[5/6] Restoring root into encrypted partition..."
rsync -aAX /tmp/acms-rootsnap/ "$WORK_DIR/root_new/"
rm -rf /tmp/acms-rootsnap

# ── update bootargs ───────────────────────────────────────────────────────────

echo "[6/6] Updating boot config..."
mount "$BOOT_PART" "$WORK_DIR/boot"

ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")

ARMBIANENV="$WORK_DIR/boot/armbianEnv.txt"
if [ -f "$ARMBIANENV" ]; then
    # Add acms_root= to extraargs
    if grep -q "extraargs" "$ARMBIANENV"; then
        sed -i "s|extraargs=|extraargs=acms_root=$ROOT_PART |" "$ARMBIANENV"
    else
        echo "extraargs=acms_root=$ROOT_PART" >> "$ARMBIANENV"
    fi
    echo "Updated armbianEnv.txt"
fi

# Write crypttab inside the new root so systemd knows about it
echo "$MAP_NAME  UUID=$ROOT_UUID  none  luks,initramfs" \
    > "$WORK_DIR/root_new/etc/crypttab"

umount "$WORK_DIR/boot"
umount "$WORK_DIR/root_new"

echo ""
echo "=== Migration complete ==="
echo "Root partition $ROOT_PART is now LUKS2 encrypted."
echo "Key = SHA-256(SID + password) — never stored anywhere."
echo ""
echo "Remove the USB/temp SD and reboot from the encrypted SD card."
echo "The board will prompt for the password at every boot."
