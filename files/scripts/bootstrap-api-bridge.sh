#!/bin/sh
# Idempotent starter for the muse-api-bridge server (nix-installed) on
# a Muse VM. Mirrors bootstrap-tailscale.sh: safe to run on every nix
# invocation; a cheap no-op when the server is already running.
# Runtime state (job queue, token) lives in ~/bridge/; logs and the
# pidfile live in ~/.local/state/api-bridge/.
STATE=/home/hatch/.local/state/api-bridge
BRIDGE_HOME=/home/hatch/bridge
BIN=/root/.nix-profile/bin/muse-api-bridge-server
mkdir -p "$STATE" "$BRIDGE_HOME/inbox" "$BRIDGE_HOME/outbox"
LOG="$STATE/bootstrap.log"
ts() { date -Iseconds; }

# The bearer token is runtime state, never part of the nix package
# (the store is world-readable). Generate one on first run.
if [ ! -f "$BRIDGE_HOME/token" ]; then
  python3 -c "import secrets; print(secrets.token_hex(24))" > "$BRIDGE_HOME/token" \
    && chmod 600 "$BRIDGE_HOME/token" \
    && echo "$(ts) generated bridge token" >> "$LOG"
fi

if [ ! -x "$BIN" ]; then
  echo "$(ts) server binary missing" >> "$LOG"
  exit 0
fi

# Already running? Check the pidfile first, then the process table
# (the pidfile can go stale across reboots; /proc is per-boot).
if [ -f "$STATE/server.pid" ]; then
  pid=$(cat "$STATE/server.pid" 2>/dev/null || echo "")
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    exit 0
  fi
fi
if pgrep -f 'libexec/server\.py' >/dev/null 2>&1; then
  pgrep -f 'libexec/server\.py' | head -1 > "$STATE/server.pid"
  exit 0
fi

setsid "$BIN" >> "$STATE/server.log" 2>&1 &
echo $! > "$STATE/server.pid"
echo "$(ts) api-bridge server started (pid $!)" >> "$LOG"
exit 0
