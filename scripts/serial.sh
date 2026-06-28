#!/usr/bin/env bash
#
# serial.sh — open the board's serial console forwarded from your local host.
# Run INSIDE the Codespace, after ./scripts/host-bridge.sh is up on your host.
#
# The local socat bridge exposes the UART as a TCP socket; here we attach to it.
# Usage:  ./scripts/serial.sh [--device LABEL]      (press Ctrl-] to quit)
#
# --device LABEL selects a multi-device target by its label (or probe serial) in
# bridge-devices.conf, which sets SERIAL_TCP to 4555+index for that device.
set -euo pipefail

DEVICES_CONF="${DEVICES_CONF:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bridge-devices.conf}"
DEVICE=""
while [ $# -gt 0 ]; do
  case "$1" in
    -d|--device) DEVICE="${2:-}"; shift 2 ;;
    --device=*)  DEVICE="${1#*=}"; shift ;;
    *)           shift ;;
  esac
done
if [ -n "$DEVICE" ]; then
  IDX="$(awk -v k="$DEVICE" '!/^[[:space:]]*#/ && NF { if ($1==k||$2==k){print ($3==""?0:$3); exit} }' "$DEVICES_CONF" 2>/dev/null || true)"
  [ -n "${IDX:-}" ] || IDX=0
  SERIAL_TCP="${SERIAL_TCP:-$((4555 + IDX))}"
fi
SERIAL_TCP="${SERIAL_TCP:-4555}"
HOSTPORT="localhost:${SERIAL_TCP}"

if ! nc -z localhost "$SERIAL_TCP" 2>/dev/null; then
  echo "error: nothing listening on $HOSTPORT." >&2
  echo "       Start ./scripts/host-bridge.sh on your local machine first," >&2
  echo "       and make sure a serial port was detected there." >&2
  exit 1
fi

# Attach to the TCP socket. We use socat, not tio: tio's `tcp://` URL support is
# version-dependent (tio 2.7 treats it as a serial *device path* and fails),
# whereas socat handles the socket reliably and bidirectionally.
if command -v socat >/dev/null 2>&1; then
  if [ -t 0 ]; then
    # Interactive terminal: raw mode so keystrokes pass straight through.
    echo "Serial console -> $HOSTPORT   (press Ctrl-] to quit)"
    exec socat -,raw,echo=0,escape=0x1d "TCP:${HOSTPORT}"
  else
    # Non-TTY (piped / non-interactive): stream without termios.
    echo "Serial console -> $HOSTPORT   (non-interactive stream)"
    exec socat STDIO "TCP:${HOSTPORT}"
  fi
else
  echo "Serial console -> $HOSTPORT   (read-only via nc; Ctrl-C to quit)"
  exec nc localhost "$SERIAL_TCP"
fi
