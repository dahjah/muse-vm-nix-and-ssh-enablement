#!/usr/bin/env bash
# Poor-man's boot trigger for Nix on a Muse VM.
# /tmp is tmpfs: it is empty after every cell restart. The marker living
# there (NOT in persistent home) is therefore a reliable "already handled
# this boot" flag. First poll that finds the marker missing runs the nix
# wrapper once (which mounts the store and fires the companion bootstrap),
# then writes the marker. All later polls are a single file test.
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

# Cull this hook's runtime log when it grows past 5 MB: the runtime
# appends one JSON record per poll, idle polls included, which is
# otherwise unbounded growth. Keeps the newest 2000 lines, rewritten
# in place so the file keeps its inode.
CULL_LOG="/home/hatch/hooks/logs/nix-boot-trigger.jsonl"
if [ -f "$CULL_LOG" ] && [ "$(stat -c %s "$CULL_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  if tail -n 2000 "$CULL_LOG" > "$CULL_LOG.cull" 2>/dev/null; then
    cat "$CULL_LOG.cull" > "$CULL_LOG" 2>/dev/null || true
  fi
  rm -f "$CULL_LOG.cull"
fi

MARKER="/tmp/.nix-bootstrapped"
LOCK="/tmp/.nix-bootstrapped.lock"

if [ -e "$MARKER" ]; then
  silent "marker present; nix already bootstrapped this boot" '{}'
fi

# Dry run: report what would happen, change nothing.
if [ "${HATCH_HOOK_DRY_RUN:-0}" = "1" ]; then
  log "dry-run: marker missing; a live poll would run nix --version here" '{"dry_run":true}'
  silent "dry-run: marker missing; would bootstrap" '{"dry_run":true}'
fi

# Serialize: a bootstrap can take ~90s when the tunnel also needs starting.
exec 9>"$LOCK"
if ! flock -n 9; then
  silent "bootstrap already in progress in another poll" '{}'
fi

OUT="$(/home/hatch/bin/nix --version 2>&1 | tr -d '\000-\037' | cut -c1-200)"
RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'nix (Nix)'; then
  touch "$MARKER"
  log "nix bootstrapped after boot" "{\"version\":\"$OUT\"}"
  silent "nix bootstrapped for this boot" "{\"version\":\"$OUT\"}"
fi

# Failure: stay silent by design (the user monitors manually while
# testing and reports failures in chat). The marker stays absent, so the next poll retries.
log "nix bootstrap failed; will retry next poll" "{\"exit_code\":$RC,\"output\":\"$OUT\"}"
silent "nix bootstrap failed; marker left absent for retry" "{\"exit_code\":$RC}"
