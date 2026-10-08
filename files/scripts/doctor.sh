#!/bin/sh
# doctor.sh: assert the Muse VM setup is healthy, layer by
# layer (INSTALL.md sections 8 and 9 as executable checks).
# Exit 0 means every layer passes; a failing layer names itself
# and the guide section that covers it.
#
# Usage: doctor.sh [--fix]
#   --fix  after the first pass, attempt the mechanical repairs
#          (trigger the wrappers' self-healing and boot
#          recovery, reinstall a missing profile package), then
#          check again and report the final state. Layout drift
#          is not auto-fixed: it needs the repo (install-files.sh).
set -u
FIX=0
[ "${1:-}" = "--fix" ] && FIX=1
FAILS=0
pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s: %s\n' "$1" "$2"; FAILS=$((FAILS + 1)); }
BRIDGE_FLAG=/home/hatch/.config/vm-api-bridge/autostart

run_checks() {
  FAILS=0
  # Layout: every installed file matches the repo.
  if [ -x /home/hatch/scripts/install-files.sh ]; then
    extra=""
    [ -f "$BRIDGE_FLAG" ] && extra="--with-bridge"
    if /home/hatch/scripts/install-files.sh --check $extra >/dev/null 2>&1; then
      pass "layout (installed files match the install manifest)"
    else
      fail "layout" "drift; run install-files.sh from the repo (INSTALL.md Phase B)"
    fi
  else
    fail "layout" "install-files.sh not installed; run it from the repo (INSTALL.md Phase B)"
  fi
  # Shim: present, and the pinned release build.
  SHIM=/home/hatch/bin/xattr-retry.so
  PIN=$(sed -n 's/^XATTR_SHIM_SHA256=//p' /home/hatch/bin/nixwrap 2>/dev/null | head -1)
  if [ ! -f "$SHIM" ]; then
    fail "shim" "xattr-retry.so missing; any nix command refetches it (INSTALL.md section 4)"
  elif [ -n "$PIN" ] && [ "$(sha256sum "$SHIM" | cut -d' ' -f1)" = "$PIN" ]; then
    pass "shim (present, matches the pinned release checksum)"
  else
    fail "shim" "present but not the pinned release build (a deliberate local build is the one exception; INSTALL.md section 4)"
  fi
  # Nix through the wrapper.
  V=$(/home/hatch/bin/nix --version 2>/dev/null)
  case "$V" in
    *2.35.2*) pass "nix ($V)" ;;
    *) fail "nix" "no working nix via the wrappers (INSTALL.md section 4)" ;;
  esac
  # Profile contents.
  Q=$(/home/hatch/bin/nix-env -q 2>/dev/null)
  if printf '%s\n' "$Q" | grep -q '^tailscale-'; then
    pass "profile (tailscale installed)"
  else
    fail "profile" "tailscale not in the profile (INSTALL.md section 4)"
  fi
  if [ -f "$BRIDGE_FLAG" ]; then
    if printf '%s\n' "$Q" | grep -q '^muse-api-bridge'; then
      pass "profile (api-bridge installed)"
    else
      fail "profile" "api-bridge flag set but package missing (INSTALL.md section 11)"
    fi
  fi
  # Tailscale daemon state.
  TS=$(/home/hatch/bin/tailscale status --json 2>/dev/null)
  if printf '%s' "$TS" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if (d.get("BackendState")=="Running" and d.get("Self",{}).get("Online") and d.get("Health")==[]) else 1)' 2>/dev/null; then
    pass "tailscale (Running, online, health [])"
  else
    fail "tailscale" "daemon not Running/online/healthy (INSTALL.md section 7)"
  fi
  # Bridge server, when the module is enabled.
  if [ -f "$BRIDGE_FLAG" ]; then
    if curl -fs --max-time 5 http://127.0.0.1:8080/health 2>/dev/null | grep -q '"ok"'; then
      pass "bridge (health ok)"
    else
      fail "bridge" "no health response on 127.0.0.1:8080 (INSTALL.md section 11)"
    fi
  fi
}

run_checks
if [ "$FIX" = 1 ] && [ "$FAILS" -gt 0 ]; then
  echo "--- attempting mechanical repairs"
  /home/hatch/bin/nix --version >/dev/null 2>&1 || true
  Q=$(/home/hatch/bin/nix-env -q 2>/dev/null)
  printf '%s\n' "$Q" | grep -q '^tailscale-' || \
    /home/hatch/bin/nix-env -iA nixpkgs.tailscale >/dev/null 2>&1 || true
  sleep 2
  echo "--- re-checking"
  run_checks
fi
if [ "$FAILS" = 0 ]; then
  echo "doctor: all layers healthy"
else
  echo "doctor: $FAILS layer(s) failing"
fi
echo "note: hook registration itself is platform state and is not"
echo "visible from the shell; the layout check covers its scripts (section 6)."
exit $FAILS
