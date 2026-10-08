#!/bin/sh
# Idempotent starter for the muse-api-bridge server (nix-installed) on
# a Muse VM. Mirrors bootstrap-tailscale.sh: safe to run on every nix
# invocation; a cheap no-op when the server is already running.
# Runtime state (job queue, token) lives in ~/bridge/; logs and the
# pidfile live in ~/.local/state/api-bridge/.
STATE=/home/hatch/.local/state/api-bridge
BRIDGE_HOME=/home/hatch/bridge
BIN=/root/.nix-profile/bin/muse-api-bridge-server
mkdir -p "$STATE" "$BRIDGE_HOME/inbox" "$BRIDGE_HOME/outbox" "$BRIDGE_HOME/bin"
LOG="$STATE/bootstrap.log"
ts() { date -Iseconds; }

# The agent calls the bridge tools by their ~/bridge/bin paths; keep
# those symlinks pointed at the packaged tools (a package upgrade
# that adds a tool then needs no manual step).
for tool in bridge-respond bridge-key bridge-reply bridge-next bridge-close; do
  if [ -e "/root/.nix-profile/bin/$tool" ]; then
    ln -sf "/root/.nix-profile/bin/$tool" "$BRIDGE_HOME/bin/$tool"
  fi
done

# The bearer token is runtime state, never part of the nix package
# (the store is world-readable). Generate one on first run.
if [ ! -f "$BRIDGE_HOME/token" ]; then
  python3 -c "import secrets; print(secrets.token_hex(24))" > "$BRIDGE_HOME/token" \
    && chmod 600 "$BRIDGE_HOME/token" \
    && echo "$(ts) generated bridge token" >> "$LOG"
fi

# Seed the named keyring from that token (the server prefers
# keys.json when it exists; bridge-key manages it from then on).
# The raw key stays readable in the token file, which is how
# the user learns the initial key; its keyring name is "initial".
if [ ! -f "$BRIDGE_HOME/keys.json" ]; then
  python3 - "$BRIDGE_HOME" <<'PYEOF' && echo "$(ts) seeded bridge keyring (key name: initial)" >> "$LOG"
import hashlib, json, os, sys
base = sys.argv[1]
token = open(os.path.join(base, "token")).read().strip()
data = {"keys": [{"name": "initial", "sha256": hashlib.sha256(token.encode()).hexdigest(), "created": "bootstrap"}]}
path = os.path.join(base, "keys.json")
with open(path, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.chmod(path, 0o600)
PYEOF
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
