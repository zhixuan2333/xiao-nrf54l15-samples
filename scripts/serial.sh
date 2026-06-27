#!/usr/bin/env bash
#
# serial.sh — open the board's serial console forwarded from your local host.
# Run INSIDE the Codespace, after ./scripts/host-bridge.sh is up on your host.
#
# The local socat bridge exposes the UART as a TCP socket; here we attach to it.
# Usage:  ./scripts/serial.sh        (Ctrl-] or Ctrl-C to quit, depending on tool)
set -euo pipefail

SERIAL_TCP="${SERIAL_TCP:-4555}"
HOSTPORT="localhost:${SERIAL_TCP}"

if ! nc -z localhost "$SERIAL_TCP" 2>/dev/null; then
  echo "error: nothing listening on $HOSTPORT." >&2
  echo "       Start ./scripts/host-bridge.sh on your local machine first," >&2
  echo "       and make sure a serial port was detected there." >&2
  exit 1
fi

echo "Serial console -> $HOSTPORT   (tio: Ctrl-t q to quit | socat: Ctrl-])"
if command -v tio >/dev/null 2>&1; then
  # tio >= 2.x can attach directly to a TCP socket.
  exec tio "tcp://${HOSTPORT}"
else
  exec socat -,raw,echo=0,escape=0x1d "TCP:${HOSTPORT}"
fi
