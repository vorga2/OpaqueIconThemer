#!/bin/sh
set -eu

HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-2222}"
USER="${USER:-root}"
DYLIB="${1:-OpaqueIconThemerBridge.dylib}"
PLIST="${2:-SpringBoardBridge/OpaqueIconThemerBridge.plist}"

if [ ! -f "$DYLIB" ]; then
  echo "Missing dylib: $DYLIB" >&2
  exit 1
fi
if [ ! -f "$PLIST" ]; then
  echo "Missing filter plist: $PLIST" >&2
  exit 1
fi

REMOTE_DIR="/var/jb/Library/MobileSubstrate/DynamicLibraries"

echo "Installing bridge to $USER@$HOST:$PORT ..."
ssh -p "$PORT" "$USER@$HOST" "mkdir -p '$REMOTE_DIR'"
scp -P "$PORT" "$DYLIB" "$USER@$HOST:$REMOTE_DIR/OpaqueIconThemerBridge.dylib"
scp -P "$PORT" "$PLIST" "$USER@$HOST:$REMOTE_DIR/OpaqueIconThemerBridge.plist"
ssh -p "$PORT" "$USER@$HOST" "chmod 755 '$REMOTE_DIR/OpaqueIconThemerBridge.dylib'; chmod 644 '$REMOTE_DIR/OpaqueIconThemerBridge.plist'; if command -v sbreload >/dev/null 2>&1; then sbreload; else killall -9 SpringBoard; fi"

echo "Installed. Reopen OpaqueIconThemer and tap refresh."
