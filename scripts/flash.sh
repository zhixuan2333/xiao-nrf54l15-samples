#!/usr/bin/env bash
#
# flash.sh — flash an ELF to the board via the tunneled OpenOCD GDB server.
# Run INSIDE the Codespace, after ./scripts/host-bridge.sh is up on your host.
#
# Usage:  ./scripts/flash.sh [path/to/zephyr.elf]   (default: build/zephyr/zephyr.elf)
set -euo pipefail

source /opt/toolchain-env.sh 2>/dev/null || true

ELF="${1:-build/zephyr/zephyr.elf}"
GDB_PORT="${GDB_PORT:-3333}"
GDB="${GDB:-arm-zephyr-eabi-gdb}"

[ -f "$ELF" ] || { echo "error: $ELF not found. Build first: west build -b <board> app" >&2; exit 1; }
command -v "$GDB" >/dev/null || GDB=gdb-multiarch

echo "Flashing $ELF via localhost:$GDB_PORT ..."
"$GDB" -nx --batch "$ELF" \
  -ex "target extended-remote localhost:${GDB_PORT}" \
  -ex "monitor reset halt" \
  -ex "load" \
  -ex "monitor reset run" \
  -ex "detach" \
  -ex "quit"
echo "Done."
