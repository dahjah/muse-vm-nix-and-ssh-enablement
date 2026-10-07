#!/usr/bin/env bash
# Idempotent starter for the full (nix-installed) tailscaled on a Muse VM.
# Called by nixwrap on nix invocations when the opt-in flag
# /home/hatch/.config/vm-tailscale/autostart exists — the boot hook fires a
# nix command after every reboot, so this gives tailscaled boot autostart.
# Healthy path is a fast no-op; failures never propagate to the caller.
set -uo pipefail

STATE=/home/hatch/.local/state/tailscale
LOG="$STATE/bootstrap.log"
TS=/root/.nix-profile/bin/tailscale
TSD=/root/.nix-profile/bin/tailscaled
mkdir -p "$STATE" /run/tailscale

# Serialize (the daemon start takes seconds; polls/invocations can overlap).
exec 9>"$STATE/bootstrap.lock"
flock -n 9 || exit 0

log() { printf '%s %s\n' "$(date -Is)" "$*" >>"$LOG" 2>/dev/null || true; }

# The profile binaries point into /nix; make sure the store is mounted
# (normally nixwrap already did this before calling us).
if ! mountpoint -q /nix 2>/dev/null; then
  [ -d /nix ] || mkdir -p /nix 2>/dev/null
  mount --bind /home/hatch/nixdisk /nix 2>/dev/null || { log "cannot mount store"; exit 0; }
fi
[ -x "$TSD" ] || { log "tailscaled binary missing"; exit 0; }

backend() { "$TS" status --json 2>/dev/null | jq -r '.BackendState // "NoState"' 2>/dev/null || echo NoState; }

if ! pgrep -f 'nix-profile/bin/tailscale[d]' >/dev/null; then
  # Critical: the daemon must NOT inherit the proxy env — registration
  # through the proxy fails (400 / reset); direct works.
  env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    setsid "$TSD" --tun=userspace-networking --statedir="$STATE" >>"$STATE/tailscaled.log" 2>&1 &
  log "tailscaled started"
  for _ in $(seq 1 15); do
    sleep 1
    [ "$(backend)" != "NoState" ] && break
  done
fi

ST="$(backend)"
if [ "$ST" = "Starting" ]; then
  for _ in $(seq 1 10); do sleep 1; ST="$(backend)"; [ "$ST" != "Starting" ] && break; done
fi
case "$ST" in
  Running) : ;;                                        # already connected
  Starting) log "still starting after 10s; leaving it to connect" ;;
  Stopped) timeout 30 "$TS" up >>"$LOG" 2>&1 || log "tailscale up failed"
           log "reconnected via tailscale up" ;;
  NeedsLogin) log "node needs a manual login; skipping" ;;
  *) log "unexpected backend state: $ST" ;;
esac
exit 0
