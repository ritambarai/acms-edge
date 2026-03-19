#!/bin/bash
# setup_luks.sh
#
# One-time setup: creates a file-backed LUKS container on the existing
# filesystem, keyed to the board's hardware chip ID (Allwinner A20 SID).
#
# The key is derived via SHA-256 of the raw SID — never stored anywhere.
# If the image file is copied to another machine it cannot be decrypted
# without this exact SoC.
#
# Usage (run as root on the board):
#   ./setup_luks.sh                        # 512 MB at /secure.img, mount /data
#   ./setup_luks.sh 1024 /mnt/secure.img /data
#
# Requires: cryptsetup, xxd
#   apt install cryptsetup xxd

set -e

SIZE_MB="${1:-512}"
IMG_FILE="${2:-/secure.img}"
MOUNT_POINT="${3:-/data}"
MAP_NAME="secure_data"

SID_PATHS=(
    "/sys/bus/nvmem/devices/sunxi-sid0/nvmem"
    "/sys/devices/platform/soc/1c23800.sid/nvmem/sunxi-sid0/nvmem"
)

read_chip_id() {
    for p in "${SID_PATHS[@]}"; do
        if [ -r "$p" ]; then
            xxd -p "$p" | tr -d '\n'
            return 0
        fi
    done
    local s
    s=$(grep -i "^serial" /proc/cpuinfo | awk -F': ' '{print $2}' | tr -d ' \n')
    if [ -n "$s" ] && [ "$s" != "0000000000000000" ]; then
        echo -n "$s"; return 0
    fi
    echo "ERROR: cannot read chip ID — try: modprobe sunxi-sid" >&2
    return 1
}

derive_key() {
    echo -n "$1" | sha256sum | awk '{print $1}' | xxd -r -p
}

# ── checks ───────────────────────────────────────────────────────────────────

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

for cmd in cryptsetup xxd sha256sum mkfs.ext4; do
    command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found — apt install cryptsetup xxd"; exit 1; }
done

if [ -e "$IMG_FILE" ]; then
    echo "ERROR: $IMG_FILE already exists. Remove it first or choose a different path."
    exit 1
fi

echo "=== ACMS file-backed LUKS setup ==="
echo "Image file : $IMG_FILE  (${SIZE_MB} MB)"
echo "Mount point: $MOUNT_POINT"
echo ""
read -r -p "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 1; }

# ── create image ─────────────────────────────────────────────────────────────

echo ""
echo "[1/5] Creating ${SIZE_MB} MB image..."
dd if=/dev/zero of="$IMG_FILE" bs=1M count="$SIZE_MB" status=progress
chmod 600 "$IMG_FILE"

# ── format with LUKS ─────────────────────────────────────────────────────────

CHIP_ID=$(read_chip_id)
echo ""
echo "[2/5] Chip ID (SID): ${CHIP_ID:0:8}****  (display truncated)"

KEY_BIN=$(derive_key "$CHIP_ID")

echo "[3/5] Formatting LUKS2 container..."
echo -n "$KEY_BIN" | cryptsetup luksFormat \
    --type luks2 \
    --key-file=- \
    "$IMG_FILE"

# ── open + mkfs ───────────────────────────────────────────────────────────────

echo "[4/5] Opening and formatting ext4..."
echo -n "$KEY_BIN" | cryptsetup luksOpen \
    --key-file=- \
    "$IMG_FILE" "$MAP_NAME"

mkfs.ext4 -q /dev/mapper/"$MAP_NAME"

# ── mount ─────────────────────────────────────────────────────────────────────

echo "[5/5] Mounting at $MOUNT_POINT..."
mkdir -p "$MOUNT_POINT"
mount /dev/mapper/"$MAP_NAME" "$MOUNT_POINT"
chmod 700 "$MOUNT_POINT"

echo ""
echo "Done. Encrypted container mounted at $MOUNT_POINT"
echo "Use unlock_luks.sh on each boot to remount."
echo ""
echo "To install auto-unlock on boot:"
echo "  cp unlock_luks.sh /usr/local/bin/"
echo "  cp acms-unlock.service /etc/systemd/system/"
echo "  systemctl enable acms-unlock.service"
