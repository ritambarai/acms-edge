#!/bin/bash
# unlock_luks.sh
#
# Reads chip ID from SID, derives the key, opens the LUKS container
# and mounts it. Called at boot via acms-unlock.service.
#
# Usage:
#   ./unlock_luks.sh [image_file] [mount_point]

set -e

IMG_FILE="${1:-/secure.img}"
MOUNT_POINT="${2:-/data}"
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
    return 1
}

derive_key() {
    echo -n "$1" | sha256sum | awk '{print $1}' | xxd -r -p
}

[ "$(id -u)" -eq 0 ] || { echo "ERROR: must run as root"; exit 1; }

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    echo "$MOUNT_POINT already mounted"
    exit 0
fi

[ -f "$IMG_FILE" ] || { echo "ERROR: $IMG_FILE not found"; exit 1; }

CHIP_ID=$(read_chip_id) || { echo "ERROR: cannot read chip ID"; exit 1; }

derive_key "$CHIP_ID" | cryptsetup luksOpen \
    --key-file=- \
    "$IMG_FILE" "$MAP_NAME"

mkdir -p "$MOUNT_POINT"
mount /dev/mapper/"$MAP_NAME" "$MOUNT_POINT"

echo "Unlocked $IMG_FILE → $MOUNT_POINT"
