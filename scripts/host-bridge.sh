#!/usr/bin/env bash
#
# host-bridge.sh  —  RUN THIS ON YOUR LOCAL MACHINE (where the board is plugged in).
#
# GitHub Codespaces run in the cloud and cannot see your USB device. This script
# exposes the board to the Codespace using the "network OpenOCD/serial" model:
#
#   1. starts OpenOCD locally (GDB :3333, telnet :4444, tcl :6666)
#   2. bridges the board's serial port to TCP :4555 with socat
#   3. opens a REVERSE SSH tunnel into the Codespace (gh codespace ssh -R ...)
#      so that, inside the Codespace, localhost:{3333,4444,4555} reach this host.
#
# Requirements on the local host:  gh, openocd, socat  (a debug probe for SWD).
#
# Usage:
#   ./scripts/host-bridge.sh [CODESPACE_NAME]
#
# Configure the probe/target with env vars (defaults shown):
#   OPENOCD_INTERFACE=interface/cmsis-dap.cfg
#   OPENOCD_TARGET=target/nordic/nrf54l.cfg   # XIAO nRF54L15; see ./openocd for others
#   SERIAL_PORT=<auto-detected>            # e.g. /dev/tty.usbmodemXXXX, /dev/ttyACM0
#   SERIAL_BAUD=115200
#   GDB_PORT=3333  TELNET_PORT=4444  SERIAL_TCP=4555
#
# Anything after `--` is passed straight to OpenOCD, e.g.:
#   ./scripts/host-bridge.sh my-codespace -- -c "init; reset"
set -euo pipefail

# Defaults target the Seeed XIAO nRF54L15 over a CMSIS-DAP probe. Override with
# env vars for any other OpenOCD-supported board (see openocd/README.md).
OPENOCD_INTERFACE="${OPENOCD_INTERFACE:-interface/cmsis-dap.cfg}"
OPENOCD_TARGET="${OPENOCD_TARGET:-target/nordic/nrf54l.cfg}"
SERIAL_BAUD="${SERIAL_BAUD:-115200}"
GDB_PORT="${GDB_PORT:-3333}"
TELNET_PORT="${TELNET_PORT:-4444}"
SERIAL_TCP="${SERIAL_TCP:-4555}"

# First non-flag arg is the Codespace name (optional). Everything after a `--`
# is passed straight through to OpenOCD.
CODESPACE=""
if [ "${1:-}" != "--" ] && [ -n "${1:-}" ]; then
  CODESPACE="$1"
  shift
fi
if [ "${1:-}" = "--" ]; then
  shift
fi
OPENOCD_EXTRA=("$@")

die() { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. Install it first."; }

need gh
need openocd
need socat

# ---------------------------------------------------------------------------
# Resolve the Codespace name.
# ---------------------------------------------------------------------------
if [ -z "$CODESPACE" ]; then
  echo "No Codespace name given; listing yours:" >&2
  gh codespace list >&2 || die "Run: gh auth login"
  CODESPACE="$(gh codespace list --json name,displayName -q '.[0].name' 2>/dev/null || true)"
  [ -n "$CODESPACE" ] || die "Pass the Codespace name explicitly: $0 <name>"
  echo "Using first Codespace: $CODESPACE" >&2
fi

# ---------------------------------------------------------------------------
# Auto-detect the serial port if not provided.
# ---------------------------------------------------------------------------
detect_serial() {
  if [ "$(uname)" = "Darwin" ]; then
    ls /dev/tty.usbmodem* /dev/tty.usbserial* 2>/dev/null | head -n1
  else
    ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | head -n1
  fi
}
SERIAL_PORT="${SERIAL_PORT:-$(detect_serial || true)}"

PIDS=()
cleanup() {
  echo; echo "Shutting down bridge..." >&2
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# 1) OpenOCD
# ---------------------------------------------------------------------------
echo "▶ OpenOCD  : $OPENOCD_INTERFACE + $OPENOCD_TARGET  (gdb:$GDB_PORT telnet:$TELNET_PORT)" >&2
openocd \
  -f "$OPENOCD_INTERFACE" \
  -f "$OPENOCD_TARGET" \
  -c "gdb_port $GDB_PORT" \
  -c "telnet_port $TELNET_PORT" \
  -c "tcl_port disabled" \
  ${OPENOCD_EXTRA[@]+"${OPENOCD_EXTRA[@]}"} &
PIDS+=($!)
sleep 1

# ---------------------------------------------------------------------------
# 2) Serial -> TCP bridge
# ---------------------------------------------------------------------------
TUNNEL_ARGS=(-R "${GDB_PORT}:localhost:${GDB_PORT}" -R "${TELNET_PORT}:localhost:${TELNET_PORT}")
if [ -n "${SERIAL_PORT:-}" ] && [ -e "$SERIAL_PORT" ]; then
  echo "▶ Serial   : $SERIAL_PORT @ ${SERIAL_BAUD}  ->  tcp:$SERIAL_TCP" >&2
  socat "TCP-LISTEN:${SERIAL_TCP},reuseaddr,fork" \
        "FILE:${SERIAL_PORT},b${SERIAL_BAUD},raw,echo=0" &
  PIDS+=($!)
  TUNNEL_ARGS+=(-R "${SERIAL_TCP}:localhost:${SERIAL_TCP}")
else
  echo "⚠ Serial   : no port found (set SERIAL_PORT=...); skipping serial bridge" >&2
fi

# ---------------------------------------------------------------------------
# 3) Reverse SSH tunnel into the Codespace (this call blocks; Ctrl-C to stop).
# ---------------------------------------------------------------------------
echo "▶ Tunnel   : reverse-forwarding into Codespace '$CODESPACE'" >&2
echo "  Inside the Codespace: ./scripts/flash.sh   ./scripts/debug.sh   ./scripts/serial.sh" >&2
echo "  Press Ctrl-C to stop." >&2
gh codespace ssh -c "$CODESPACE" -- -N "${TUNNEL_ARGS[@]}"
