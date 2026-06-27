#!/usr/bin/env bash
set -euo pipefail

source /opt/toolchain-env.sh 2>/dev/null || true
git config --global --add safe.directory "*" || true
chmod +x /workspaces/xiao-nrf54l15-samples/scripts/*.sh 2>/dev/null || true

cat <<EOF

  XIAO nRF54L15 samples — ready ($NCS_VERSION, board $BOARD)
  ────────────────────────────────────────────────────────────
  Build:
      west build -b \$BOARD apps/hello_world
      west build -b \$BOARD apps/blinky

  Connect hardware (run on your LOCAL machine, board plugged in):
      ./scripts/host-bridge.sh <codespace-name>

  Then inside this Codespace:
      ./scripts/flash.sh        # flash build/zephyr/zephyr.elf
      ./scripts/serial.sh       # serial console
      ./scripts/debug.sh        # gdb
  ────────────────────────────────────────────────────────────
EOF
