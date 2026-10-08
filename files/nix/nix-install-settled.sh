#!/bin/sh
# Install nixpkgs attributes into the default profile, tolerating
# the host's asynchronous taint-marking of new store files.
#
# A file's user.hatch_tainted* markers are added one by one shortly
# after the file is created. Nix lists a file's attributes by
# probing the list size and then reading into a buffer of that
# size; a marker landing between the two calls makes the read fail
# with "querying extended attributes ... Numerical result out of
# range", and Nix does not retry. ignored-acls cannot help: it
# applies after the list has been read.
#
# So: instantiate first (creates the .drv files), wait until the
# store's total attribute count is stable across two sweeps a few
# seconds apart, then install. Retry the whole sequence a bounded
# number of times per package.
#
# Usage: sh nix-install-settled.sh <attr> [<attr> ...]
# Example: sh nix-install-settled.sh tailscale hello

set -u
BIN=/home/hatch/bin
STORE=/home/hatch/nixdisk/store

wait_until_settled() {
  python3 - "$STORE" <<'EOF'
import os, sys, time
store = sys.argv[1]
def sweep():
    n = 0
    for e in os.scandir(store):
        try:
            n += len(os.listxattr(e.path))
        except OSError:
            pass
    return n
prev = sweep()
for _ in range(40):
    time.sleep(3)
    cur = sweep()
    if cur == prev:
        sys.exit(0)
    prev = cur
sys.exit(1)
EOF
}

install_one() {
  pkg="$1"
  attempt=1
  while [ "$attempt" -le 5 ]; do
    "$BIN/nix-instantiate" '<nixpkgs>' -A "$pkg" >/dev/null 2>&1 || true
    wait_until_settled || true
    if "$BIN/nix-env" -iA "nixpkgs.$pkg"; then
      return 0
    fi
    echo "nix-install-settled: attempt $attempt for $pkg failed; retrying" >&2
    attempt=$((attempt + 1))
    sleep 5
  done
  echo "nix-install-settled: giving up on $pkg after 5 attempts" >&2
  return 1
}

rc=0
for pkg in "$@"; do
  install_one "$pkg" || rc=1
done
exit $rc
