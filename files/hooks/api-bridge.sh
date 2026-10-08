#!/usr/bin/env bash
# Poll for pending API Bridge jobs. If the oldest unanswered job has
# no live claim, claim it and wake the API Bridge side chat's agent
# (the hook definition carries the delivery target and the standing
# instructions). A claim goes stale after 15 minutes so a job whose
# agent died is offered again.
set -euo pipefail
source "$HATCH_HOOK_RUNTIME"

# Cull this hook's runtime log when it grows past 5 MB: the runtime
# appends one JSON record per poll, idle polls included, which is
# otherwise unbounded growth. Keeps the newest 2000 lines, rewritten
# in place so the file keeps its inode.
CULL_LOG="/home/hatch/hooks/logs/api-bridge.jsonl"
if [ -f "$CULL_LOG" ] && [ "$(stat -c %s "$CULL_LOG" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  if tail -n 2000 "$CULL_LOG" > "$CULL_LOG.cull" 2>/dev/null; then
    cat "$CULL_LOG.cull" > "$CULL_LOG" 2>/dev/null || true
  fi
  rm -f "$CULL_LOG.cull"
fi

INBOX=/home/hatch/bridge/inbox
OUTBOX=/home/hatch/bridge/outbox
STATE=/home/hatch/hooks/state/api-bridge
mkdir -p "$STATE" "$INBOX" "$OUTBOX"

# Drop claims for jobs that no longer exist.
for c in "$STATE"/*.claim; do
  [ -e "$c" ] || continue
  cid=$(basename "$c" .claim)
  [ -f "$INBOX/$cid.json" ] || rm -f "$c"
done

now=$(date +%s)
target=""
for j in "$INBOX"/*.json; do
  [ -e "$j" ] || continue
  id=$(basename "$j" .json)
  [ -e "$OUTBOX/$id.txt" ] && continue
  claim="$STATE/$id.claim"
  if [ -f "$claim" ]; then
    claimed_at=$(cat "$claim" 2>/dev/null || echo 0)
    [ $((now - claimed_at)) -lt 900 ] && continue
  fi
  target="$id"
  if [ "${HATCH_HOOK_DRY_RUN:-0}" != "1" ]; then
    echo "$now" > "$claim"
  fi
  break
done

if [ -n "$target" ]; then
  wake "API bridge request pending" "{\"job_id\":\"$target\",\"job_path\":\"$INBOX/$target.json\"}"
else
  silent "no pending bridge jobs" '{}'
fi
