#!/bin/sh
#
# install.sh — opkg install script template
#
# This script is bundled inside the opkg package (in control.tar.gz).
# install_package runs it after placing all files from data.tar.gz.
#
# Environment provided by install_package:
#   ACMS_BOARD_STATE — path to /etc/acms/board_state
#
# To advance the board lifecycle after install, write stateCode to
# $ACMS_BOARD_STATE before exiting. If you do not, install_package
# defaults to stateCode=0 (Running).
#
# Exit 0 on success. Any non-zero exit triggers a full rollback.
#
# ── package-specific setup ────────────────────────────────────────────────────

# Example: set permissions on an installed binary
# chmod +x /usr/local/bin/my_program

# Example: enable a new systemd service
# systemctl enable my-service.service

# Example: write a config file
# cat > /etc/my_app/config <<EOF
# key=value
# EOF

# ── set next stateCode ────────────────────────────────────────────────────────
#
# Write the stateCode the board should enter after this install completes.
# Change to any valid stateCode if this package requires a specific next state.
# If omitted, install_package will default to 0 (Running) automatically.

printf 'stateCode=%s\n' 0 > "$ACMS_BOARD_STATE"

exit 0
