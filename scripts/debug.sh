#!/usr/bin/env bash
#
# debug.sh — interactive GDB debug session against the tunneled OpenOCD server.
# Run INSIDE the Codespace, after ./scripts/host-bridge.sh is up on your host.
#
# Usage:  ./scripts/debug.sh [path/to/zephyr.elf]   (default: build/zephyr/zephyr.elf)
set -euo pipefail

source /opt/toolchain-env.sh 2>/dev/null || true

ELF="${1:-build/zephyr/zephyr.elf}"
GDB_PORT="${GDB_PORT:-3333}"
GDB="${GDB:-arm-zephyr-eabi-gdb}"

[ -f "$ELF" ] || { echo "error: $ELF not found. Build first: west build -b <board> app" >&2; exit 1; }
command -v "$GDB" >/dev/null || GDB=gdb-multiarch

exec "$GDB" "$ELF" \
  -ex "target extended-remote localhost:${GDB_PORT}" \
  -ex "monitor reset halt"
