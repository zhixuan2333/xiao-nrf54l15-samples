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
#   ./scripts/host-bridge.sh [CODESPACE_NAME] [--device LABEL|SERIAL]
#   ./scripts/host-bridge.sh --list          # list connected probes + configured devices
#
# MULTI-DEVICE: with several probes plugged in, pick one by a custom label or by
# its probe serial. Labels live in bridge-devices.conf (committed, so the
# Codespace resolves them too):
#       # label    probe_serial   index
#       xiao_a      E81ECDC6       0
#       xiao_b      A1B2C3D4       1
# Each index offsets the ports (gdb 3333+i, telnet 4444+i, serial 4555+i), so you
# can run one bridge per device at once. OpenOCD binds the exact probe by serial.
#
# Configure the probe/target with env vars (defaults shown):
#   OPENOCD_CFG=<repo>/openocd/xiao_nrf54l15.cfg  # self-contained board cfg (default)
#   OPENOCD_INTERFACE=cmsis-dap            # bare probe name: cmsis-dap / jlink / stlink
#   OPENOCD_SERIAL=                        # probe serial (set automatically by --device)
#   OPENOCD_TARGET=                        # set e.g. target/nrf52.cfg for two-file mode
#   SERIAL_PORT=<auto-detected>            # e.g. /dev/cu.usbmodemXXXX, /dev/ttyACM0
#   SERIAL_BAUD=115200
#   GDB_PORT=3333  TELNET_PORT=4444  SERIAL_TCP=4555   (env overrides the index offset)
#
# Anything after `--` is passed straight to OpenOCD, e.g.:
#   ./scripts/host-bridge.sh my-codespace -- -c "init; reset"
set -euo pipefail

# This script lives in <repo>/scripts/.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# OpenOCD config — two modes:
#  * Self-contained board cfg (DEFAULT): a single .cfg that wires up probe +
#    target on its own. Default = bundled XIAO nRF54L15 config, which works with
#    stock OpenOCD 0.12.0 (no target/nordic/nrf54l.cfg needed). It selects the
#    probe from $OPENOCD_INTERFACE (a bare name like cmsis-dap / jlink / stlink).
#  * Two-file mode: set OPENOCD_TARGET (e.g. target/nrf52.cfg) to use the classic
#    interface + target pair for any other OpenOCD-supported SoC.
OPENOCD_CFG="${OPENOCD_CFG:-$REPO/openocd/xiao_nrf54l15.cfg}"
OPENOCD_INTERFACE="${OPENOCD_INTERFACE:-cmsis-dap}"
OPENOCD_SERIAL="${OPENOCD_SERIAL:-}"
OPENOCD_TARGET="${OPENOCD_TARGET:-}"
SERIAL_BAUD="${SERIAL_BAUD:-115200}"
DEVICES_CONF="${DEVICES_CONF:-$REPO/bridge-devices.conf}"

die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing: [CODESPACE] [--device X] [--list] [-- <openocd args>]
# ---------------------------------------------------------------------------
DEVICE=""
LIST=0
CODESPACE=""
OPENOCD_EXTRA=()
while [ $# -gt 0 ]; do
  case "$1" in
    -l|--list)   LIST=1; shift ;;
    -d|--device) DEVICE="${2:-}"; shift 2 ;;
    --device=*)  DEVICE="${1#*=}"; shift ;;
    --)          shift; OPENOCD_EXTRA=("$@"); break ;;
    -*)          die "unknown option: $1 (try --list)" ;;
    *)           if [ -z "$CODESPACE" ]; then CODESPACE="$1"; else OPENOCD_EXTRA+=("$1"); fi; shift ;;
  esac
done

# ---------------------------------------------------------------------------
# Resolve --device against bridge-devices.conf (label or serial), then derive
# this device's port set from its index. Explicit GDB_PORT/etc env still wins.
# ---------------------------------------------------------------------------
DEV_INDEX=0
if [ -n "$DEVICE" ]; then
  CONF_LINE="$(awk -v k="$DEVICE" '!/^[[:space:]]*#/ && NF { if ($1==k || $2==k) { print $1, $2, ($3==""?0:$3); exit } }' "$DEVICES_CONF" 2>/dev/null || true)"
  if [ -n "$CONF_LINE" ]; then
    read -r _RL OPENOCD_SERIAL DEV_INDEX <<<"$CONF_LINE"
    echo "Device '$_RL' -> probe serial $OPENOCD_SERIAL (index $DEV_INDEX)" >&2
  else
    OPENOCD_SERIAL="$DEVICE"
    echo "Device '$DEVICE' not in $DEVICES_CONF — using it as a probe serial (index 0)" >&2
  fi
fi
GDB_PORT="${GDB_PORT:-$((3333 + DEV_INDEX))}"
TELNET_PORT="${TELNET_PORT:-$((4444 + DEV_INDEX))}"
SERIAL_TCP="${SERIAL_TCP:-$((4555 + DEV_INDEX))}"
need() { command -v "$1" >/dev/null 2>&1 || die "'$1' not found on PATH. Install it first."; }

# Serial-port discovery. With a probe serial, prefer the cu.* device whose name
# embeds that serial (macOS: /dev/cu.usbmodem<SERIAL><iface>); else first found.
detect_serial() {
  local want="${1:-}" hit=""
  if [ "$(uname)" = "Darwin" ]; then
    if [ -n "$want" ]; then hit="$(ls /dev/cu.usbmodem${want}* 2>/dev/null | head -n1)"; fi
    if [ -z "$hit" ]; then hit="$(ls /dev/cu.usbmodem* /dev/cu.usbserial* 2>/dev/null | head -n1)"; fi
  else
    if [ -n "$want" ]; then hit="$(ls /dev/serial/by-id/*${want}* 2>/dev/null | head -n1)"; fi
    if [ -z "$hit" ]; then hit="$(ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null | head -n1)"; fi
  fi
  printf '%s' "$hit"
}

list_devices() {
  echo "Connected probes / serial ports:" >&2
  if [ "$(uname)" = "Darwin" ]; then
    ls /dev/cu.usbmodem* /dev/cu.usbserial* 2>/dev/null | while read -r d; do
      # cu name = <serial><interface-digit>; drop the trailing digit for the serial.
      suf="${d#/dev/cu.usbmodem}"
      printf "  %-34s serial≈%s\n" "$d" "${suf%?}" >&2
    done
    if command -v system_profiler >/dev/null 2>&1; then
      echo "  Exact USB serial numbers (use these in bridge-devices.conf):" >&2
      system_profiler SPUSBDataType 2>/dev/null | awk -F': ' '/Serial Number:/{print "    " $2}' | sort -u >&2
    fi
  else
    ls /dev/serial/by-id/ 2>/dev/null >&2 || ls /dev/ttyACM* /dev/ttyUSB* 2>/dev/null >&2
  fi
  echo "Configured devices ($DEVICES_CONF):" >&2
  if [ -f "$DEVICES_CONF" ]; then
    awk '!/^[[:space:]]*#/ && NF { i=($3==""?0:$3); printf "  %-12s serial=%-14s index=%s  (gdb %d, telnet %d, serial %d)\n",$1,$2,i,3333+i,4444+i,4555+i }' "$DEVICES_CONF" >&2
  else
    echo "  (none — create $DEVICES_CONF; see the header of this script)" >&2
  fi
}

if [ "$LIST" = "1" ]; then list_devices; exit 0; fi

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

# Auto-detect the serial port (for the selected probe serial, if any).
SERIAL_PORT="${SERIAL_PORT:-$(detect_serial "$OPENOCD_SERIAL" || true)}"

PIDS=()
cleanup() {
  echo; echo "Shutting down bridge..." >&2
  for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
  wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Pre-flight: clear stale OpenOCD / socat / tunnels left by previous runs.
# (These cause "Address already in use" and connect storms on re-run.)
# ---------------------------------------------------------------------------
free_port() {
  local p="$1" pids
  pids="$(lsof -ti "tcp:$p" 2>/dev/null || true)"
  if [ -n "$pids" ]; then
    echo "  freeing stale tcp:$p (pids: $pids)" >&2
    kill $pids 2>/dev/null || true
  fi
}
echo "Cleaning up stale local OpenOCD/serial/tunnels..." >&2
free_port "$GDB_PORT"; free_port "$TELNET_PORT"; free_port "$SERIAL_TCP"
# Kill leftover socat children that may still hold the serial device (these can
# linger past a port free and steal serial bytes on the next run).
pkill -f "socat .*${SERIAL_TCP}" 2>/dev/null || true
[ -n "${SERIAL_PORT:-}" ] && pkill -f "socat .*${SERIAL_PORT}" 2>/dev/null || true
pkill -f "codespace ssh -c ${CODESPACE}" 2>/dev/null || true
sleep 1
# Raise the fd limit so the SSH reverse tunnel can handle many short-lived
# gdb connections without "Too many open files".
ulimit -n 4096 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1) OpenOCD
# ---------------------------------------------------------------------------
if [ -n "$OPENOCD_TARGET" ]; then
  # Two-file mode. Accept a bare probe name or a full cfg path for the interface.
  case "$OPENOCD_INTERFACE" in
    */*) IFACE_FILE="$OPENOCD_INTERFACE" ;;
    *)   IFACE_FILE="interface/${OPENOCD_INTERFACE}.cfg" ;;
  esac
  echo "▶ OpenOCD  : $IFACE_FILE + $OPENOCD_TARGET  (gdb:$GDB_PORT telnet:$TELNET_PORT)" >&2
  OCD_FILES=(-f "$IFACE_FILE" -f "$OPENOCD_TARGET")
else
  # Self-contained board cfg. It reads $OPENOCD_INTERFACE (bare name) internally.
  [ -f "$OPENOCD_CFG" ] || die "OpenOCD config not found: $OPENOCD_CFG"
  export OPENOCD_INTERFACE
  echo "▶ OpenOCD  : $OPENOCD_CFG (probe=$OPENOCD_INTERFACE)  (gdb:$GDB_PORT telnet:$TELNET_PORT)" >&2
  OCD_FILES=(-f "$OPENOCD_CFG")
fi
# Bind a specific probe by serial (multi-device). `adapter serial` is set after
# the cfg (which selects the driver) and before the implicit init.
OCD_SERIAL_ARG=()
if [ -n "$OPENOCD_SERIAL" ]; then
  echo "  probe serial: $OPENOCD_SERIAL" >&2
  OCD_SERIAL_ARG=(-c "adapter serial $OPENOCD_SERIAL")
fi
openocd \
  "${OCD_FILES[@]}" \
  ${OCD_SERIAL_ARG[@]+"${OCD_SERIAL_ARG[@]}"} \
  -c "gdb_port $GDB_PORT" \
  -c "telnet_port $TELNET_PORT" \
  -c "tcl_port disabled" \
  ${OPENOCD_EXTRA[@]+"${OPENOCD_EXTRA[@]}"} &
OPENOCD_PID=$!
PIDS+=($OPENOCD_PID)

# Wait for the GDB server to come up; fail loudly if it didn't (bad probe,
# port still busy, missing cfg) instead of tunneling a dead endpoint.
for _ in $(seq 1 20); do
  nc -z localhost "$GDB_PORT" 2>/dev/null && break
  kill -0 "$OPENOCD_PID" 2>/dev/null || die "OpenOCD exited — see its output above (probe connected? ports free?)"
  sleep 0.5
done
nc -z localhost "$GDB_PORT" 2>/dev/null \
  || die "OpenOCD GDB server never opened on :$GDB_PORT — check the OpenOCD output above"
echo "✓ OpenOCD GDB server listening on :$GDB_PORT" >&2

# ---------------------------------------------------------------------------
# 2) Serial -> TCP bridge
# ---------------------------------------------------------------------------
TUNNEL_ARGS=(-R "${GDB_PORT}:localhost:${GDB_PORT}" -R "${TELNET_PORT}:localhost:${TELNET_PORT}")
if [ -n "${SERIAL_PORT:-}" ] && [ -e "$SERIAL_PORT" ]; then
  echo "▶ Serial   : $SERIAL_PORT @ ${SERIAL_BAUD}  ->  tcp:$SERIAL_TCP" >&2
  # socat serial termios options differ by build/OS:
  #  * macOS / socat >= 1.8: numeric ispeed/ospeed + cfmakeraw (b<rate> removed).
  #  * Linux / socat 1.7.x: the classic b<rate> shorthand.
  # Override entirely with SERIAL_SOCAT_OPTS=... if your socat needs something else.
  if [ -n "${SERIAL_SOCAT_OPTS:-}" ]; then
    SER_OPTS="$SERIAL_SOCAT_OPTS"
  elif [ "$(uname)" = "Darwin" ]; then
    SER_OPTS="cfmakeraw,ispeed=${SERIAL_BAUD},ospeed=${SERIAL_BAUD},clocal=1"
  else
    SER_OPTS="b${SERIAL_BAUD},raw,echo=0,clocal=1"
  fi
  # max-children=1: a serial port has ONE byte stream — allowing a second reader
  # (e.g. VS Code auto-forwarding the same port) makes them steal bytes from each
  # other and the console turns to garbage. Enforce a single attached reader.
  socat "TCP-LISTEN:${SERIAL_TCP},reuseaddr,fork,max-children=1" \
        "FILE:${SERIAL_PORT},${SER_OPTS}" &
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
# ExitOnForwardFailure makes a port already bound on the Codespace side (e.g. a
# leftover tunnel) a hard, visible error rather than a silent dead forward.
gh codespace ssh -c "$CODESPACE" -- -N \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  "${TUNNEL_ARGS[@]}"
