#!/usr/bin/env bash
# Poor-man's boot trigger for Nix on a Muse VM.
# /tmp is tmpfs: it is empty after every cell restart. The marker living
# there (NOT in persistent home) is therefore a reliable "already handled
# this boot" flag. First poll that finds the marker missing runs the nix
# wrapper once (which mounts the store and fires the companion bootstrap),
# then writes the marker. All later polls are a single file test.
set -uo pipefail
source "$HATCH_HOOK_RUNTIME"

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
