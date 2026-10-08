#!/bin/sh
# install-files.sh: lay down the Muse VM setup files from this
# repo in one idempotent step (INSTALL.md Phase B), replacing the
# manual copy table. Safe to re-run: identical files are left
# alone, changed files are refreshed.
#
# Usage (install, from the repo clone):
#   sh files/scripts/install-files.sh [--with-bridge]
# Usage (drift check, anywhere; the installed copy at
# ~/scripts/install-files.sh works standalone):
#   install-files.sh [--with-bridge] --check
#   --with-bridge  also handle the API Bridge module's scripts
#                  and autostart flag (INSTALL.md 11).
#   --check        write nothing; verify each installed file
#                  against the manifest recorded at install
#                  time and exit 1 on any drift.
#
# The manifest (~/.config/vm-setup/manifest) records the sha256
# of every installed file, so the machine itself knows what was
# installed without the repo at hand. Refreshing to a newer repo
# version still means: pull, then run the installer again.
#
# nixwrap is special: a block between '# BEGIN local-only' and
# '# END local-only' in the installed file is machine-local (the
# repo ships it empty). Refreshes preserve it, the manifest hashes
# nixwrap with that block normalized out, and --check ignores it.
set -u
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO=$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)
FILES="$REPO/files"
MANIFEST=/home/hatch/.config/vm-setup/manifest
CHECK=0
BRIDGE=0
for a in "$@"; do
  case "$a" in
    --check) CHECK=1 ;;
    --with-bridge) BRIDGE=1 ;;
    *) echo "install-files.sh: unknown argument: $a" >&2; exit 2 ;;
  esac
done
if [ "$CHECK" = 0 ] && [ ! -d "$FILES" ]; then
  echo "install-files.sh: no repo files tree found at $FILES" >&2
  echo "run the copy inside the repo clone to install; the installed" >&2
  echo "copy at ~/scripts supports --check standalone." >&2
  exit 2
fi
FAIL=0
say() { printf '%s\n' "$*"; }
MTMP=""
if [ "$CHECK" = 0 ]; then
  mkdir -p "$(dirname "$MANIFEST")"
  MTMP=$(mktemp)
fi

hash_of() {
  if [ "$1" = /home/hatch/bin/nixwrap ]; then
    sed '/^# BEGIN local-only/,/^# END local-only/c # LOCAL-ONLY' "$1" | sha256sum | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}
manifest_hash() {
  awk -v d="$1" '$1=="file" && $3==d {print $2}' "$MANIFEST" 2>/dev/null | head -1
}
record() { [ "$CHECK" = 0 ] && printf 'file %s %s\n' "$(hash_of "$1")" "$1" >> "$MTMP"; }

place_nixwrap() {
  src=$1; dest=$2
  if [ "$CHECK" = 1 ]; then
    if [ ! -f "$dest" ]; then say "MISSING  $dest"; FAIL=1; return; fi
    want=$(manifest_hash "$dest")
    if [ -z "$want" ]; then say "UNRECORDED $dest (re-run the installer from the repo)"; FAIL=1
    elif [ "$(hash_of "$dest")" = "$want" ]; then say "ok       $dest"
    else say "DIFFERS  $dest"; FAIL=1; fi
    return
  fi
  if [ ! -f "$dest" ]; then
    cp "$src" "$dest"; chmod 755 "$dest"; say "installed $dest"; record "$dest"; return
  fi
  region=$(mktemp); merged=$(mktemp)
  sed -n '/^# BEGIN local-only/,/^# END local-only/p' "$dest" > "$region"
  [ -s "$region" ] || printf '# BEGIN local-only\n# END local-only\n' > "$region"
  sed '/^# BEGIN local-only/,$d' "$src" > "$merged"
  cat "$region" >> "$merged"
  sed -n '/^# END local-only/,$p' "$src" | tail -n +2 >> "$merged"
  if [ "$(hash_of "$merged")" = "$(hash_of "$dest")" ]; then
    say "ok       $dest"
  else
    cp "$merged" "$dest"; chmod 755 "$dest"
    say "updated  $dest (local-only block preserved)"
  fi
  rm -f "$region" "$merged"
  record "$dest"
}

place() {
  src=$1; dest=$2; mode=$3
  if [ "$dest" = /home/hatch/bin/nixwrap ]; then place_nixwrap "$src" "$dest"; return; fi
  if [ "$CHECK" = 1 ]; then
    if [ ! -f "$dest" ]; then say "MISSING  $dest"; FAIL=1; return; fi
    want=$(manifest_hash "$dest")
    if [ -z "$want" ]; then say "UNRECORDED $dest (re-run the installer from the repo)"; FAIL=1
    elif [ "$(hash_of "$dest")" = "$want" ]; then say "ok       $dest"
    else say "DIFFERS  $dest"; FAIL=1; fi
    return
  fi
  if [ ! -f "$src" ]; then say "ERROR    source missing: $src"; FAIL=1; return; fi
  mkdir -p "$(dirname "$dest")"
  if [ ! -f "$dest" ]; then
    cp "$src" "$dest"; chmod "$mode" "$dest"; say "installed $dest"
  elif cmp -s "$src" "$dest"; then
    say "ok       $dest"
  else
    cp "$src" "$dest"; chmod "$mode" "$dest"; say "updated  $dest"
  fi
  record "$dest"
}

link() {
  dest=/home/hatch/bin/$1
  if [ -L "$dest" ] && [ "$(readlink "$dest")" = nixwrap ]; then
    say "ok       $dest -> nixwrap"
  elif [ "$CHECK" = 1 ]; then
    say "BADLINK  $dest"; FAIL=1
  else
    ln -sf nixwrap "$dest"; say "linked   $dest -> nixwrap"
  fi
}

flag() {
  f=$1
  if [ -f "$f" ]; then say "ok       $f"
  elif [ "$CHECK" = 1 ]; then say "MISSING  $f"; FAIL=1
  else mkdir -p "$(dirname "$f")"; touch "$f"; say "created  $f"; fi
}

[ "$CHECK" = 0 ] && mkdir -p /home/hatch/bin /home/hatch/scripts \
  /home/hatch/hooks/scripts /home/hatch/workspace/nix \
  /home/hatch/.config/vm-tailscale /home/hatch/.local/state/tailscale

place "$FILES/bin/nixwrap" /home/hatch/bin/nixwrap 755
for t in nix nix-env nix-shell nix-build nix-store nix-channel \
         nix-instantiate nix-collect-garbage nix-hash \
         nix-copy-closure nixsh tailscale tailscaled; do
  link "$t"
done
place "$FILES/scripts/bootstrap-tailscale.sh" /home/hatch/scripts/bootstrap-tailscale.sh 755
place "$FILES/scripts/install-files.sh" /home/hatch/scripts/install-files.sh 755
place "$FILES/scripts/doctor.sh" /home/hatch/scripts/doctor.sh 755
place "$FILES/hooks/nix-boot-trigger.sh" /home/hatch/hooks/scripts/nix-boot-trigger.sh 755
place "$FILES/nix/setup-nix.sh" /home/hatch/workspace/nix/setup-nix.sh 755
place "$FILES/nix/ignored-acls.txt" /home/hatch/workspace/nix/ignored-acls.txt 644
place "$FILES/bin/xattr-retry.c" /home/hatch/workspace/nix/xattr-retry.c 644
flag /home/hatch/.config/vm-tailscale/autostart

if [ "$BRIDGE" = 1 ]; then
  [ "$CHECK" = 0 ] && mkdir -p /home/hatch/.config/vm-api-bridge
  place "$FILES/scripts/bootstrap-api-bridge.sh" /home/hatch/scripts/bootstrap-api-bridge.sh 755
  place "$FILES/hooks/api-bridge.sh" /home/hatch/hooks/scripts/api-bridge.sh 755
  flag /home/hatch/.config/vm-api-bridge/autostart
fi

if [ "$CHECK" = 0 ]; then mv "$MTMP" "$MANIFEST"; say "manifest written to $MANIFEST"; fi
if [ "$FAIL" = 0 ]; then
  say "install-files: all files in place"
else
  say "install-files: drift found (see above)"
fi
exit $FAIL
