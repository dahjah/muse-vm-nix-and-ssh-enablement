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
# The vulnerable step is instantiation itself: creating a large
# package's .drv closure writes thousands of files in a burst,
# and the run dies partway, on a different fresh .drv each time.
# But .drv files persist between runs, so resuming instantiation
# compounds progress. This script therefore:
#
#   1. resumes instantiation until the package's full closure is
#      instantiated (bounded at 50 attempts),
#   2. waits until the store's total attribute count is stable
#      across two sweeps a few seconds apart,
#   3. installs, retrying a bounded number of times.
#
# Usage: sh nix-install-settled.sh <attr> [<attr> ...]
# Example: sh nix-install-settled.sh hello tailscale

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

instantiate_until_done() {
  pkg="$1"
  attempt=1
  while [ "$attempt" -le 50 ]; do
    if "$BIN/nix-instantiate" '<nixpkgs>' -A "$pkg" >/dev/null 2>&1; then
      return 0
    fi
    echo "nix-install-settled: instantiating $pkg stopped (attempt $attempt); resuming" >&2
    attempt=$((attempt + 1))
    sleep 3
  done
  echo "nix-install-settled: could not fully instantiate $pkg after 50 attempts" >&2
  return 1
}

install_one() {
  pkg="$1"
  instantiate_until_done "$pkg" || return 1
  wait_until_settled || true
  attempt=1
  while [ "$attempt" -le 5 ]; do
    if "$BIN/nix-env" -iA "nixpkgs.$pkg"; then
      return 0
    fi
    echo "nix-install-settled: install attempt $attempt for $pkg failed; retrying" >&2
    attempt=$((attempt + 1))
    sleep 5
    wait_until_settled || true
  done
  echo "nix-install-settled: giving up on $pkg after 5 install attempts" >&2
  return 1
}

rc=0
for pkg in "$@"; do
  install_one "$pkg" || rc=1
done
exit $rc
