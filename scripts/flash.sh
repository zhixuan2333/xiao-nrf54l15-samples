#!/usr/bin/env bash
#
# flash.sh — flash an ELF to the board via the tunneled OpenOCD GDB server.
# Run INSIDE the Codespace, after ./scripts/host-bridge.sh is up on your host.
#
# Usage:  ./scripts/flash.sh [--device LABEL] [path/to/zephyr.elf]
#         (default elf: build/zephyr/zephyr.elf)
#
# --device LABEL selects a multi-device target by its label (or probe serial) in
# bridge-devices.conf, which sets GDB_PORT to 3333+index for that device.
#
# OPENOCD_PRELOAD is a monitor command run right before `load`. It defaults to
# the nRF54L RRAM write-enable (RRAMC CONFIG.WEN), which is required to program
# RRAM via gdb `load`. Set OPENOCD_PRELOAD="" for SoCs that don't need it.
set -euo pipefail

source /opt/toolchain-env.sh 2>/dev/null || true

DEVICES_CONF="${DEVICES_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bridge-devices.conf}"
DEVICE=""
ELF=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device) DEVICE="${2:-}"; shift 2 ;;
    --device=*)  DEVICE="${1#*=}"; shift ;;
    *)           ELF="$1"; shift ;;
  esac
done
ELF="${ELF:-build/zephyr/zephyr.elf}"
if [ -n "$DEVICE" ]; then
  IDX="$(awk -v k="$DEVICE" '!/^[[:space:]]*#/ && NF { if ($1==k||$2==k){print ($3==""?0:$3); exit} }' "$DEVICES_CONF" 2>/dev/null || true)"
  [ -n "${IDX:-}" ] || IDX=0
  GDB_PORT="${GDB_PORT:-$((3333 + IDX))}"
fi
GDB_PORT="${GDB_PORT:-3333}"
GDB="${GDB:-arm-zephyr-eabi-gdb}"
OPENOCD_PRELOAD="${OPENOCD_PRELOAD-mww 0x5004b500 0x101}"

[ -f "$ELF" ] || { echo "error: $ELF not found. Build first: west build -b <board> app" >&2; exit 1; }
command -v "$GDB" >/dev/null || GDB=gdb-multiarch

echo "Flashing $ELF via localhost:$GDB_PORT ..."
"$GDB" -nx --batch "$ELF" \
  -ex "target extended-remote localhost:${GDB_PORT}" \
  -ex "monitor reset halt" \
  ${OPENOCD_PRELOAD:+-ex "monitor ${OPENOCD_PRELOAD}"} \
  -ex "load" \
  -ex "monitor reset run" \
  -ex "detach" \
  -ex "quit"
echo "Done."
