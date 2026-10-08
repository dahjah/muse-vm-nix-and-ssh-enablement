#!/bin/sh
# Reinstall Nix 2.35.2 on a Muse VM (e.g. after a VM replacement).
#
# Key discovery: files on the regular filesystems here acquire an immutable
# xattr (user.hatch_tainted[.n]) that cannot be removed from inside the VM,
# and stock Nix refuses store paths whose xattrs it cannot strip. The fix is
# Nix's own `ignored-acls` setting (runbook section 4): list the marker
# attributes there and Nix leaves them alone. That lets the store live on
# the real disk at /home/hatch/nixdisk (100G volume, persistent), bind-mounted
# over /nix per session (mounts don't persist across sessions; the wrappers
# in /home/hatch/bin do the mount automatically).
# Also: root single-user install needs the sandbox off (see /etc/nix/nix.conf).
set -e

# Backing directory for the store: default is the persistent disk
# volume. Pass /var/tmp/nixroot for the tmpfs stage (INSTALL.md
# section 4, "Installing packages").

# xattr-retry shim: ensure the pinned CI-built .so is present
# and preload it for everything this script runs, since these
# nix calls do not pass through the wrappers (see nixwrap for
# the full explanation). The pin here and in nixwrap must
# match. A .so already present is never overwritten.
XATTR_SHIM=/home/hatch/bin/xattr-retry.so
XATTR_SHIM_URL=https://github.com/dahjah/muse-vm-nix-and-ssh-enablement/releases/download/shim-v1/xattr-retry.so
XATTR_SHIM_SHA256=19038c96d55f08eda8388b41a68be4c9bcdc3554fa7fc6e1fe5985c5189852e2
if [ ! -f "$XATTR_SHIM" ]; then
  shim_tmp="$XATTR_SHIM.tmp.$$"
  if curl -fsSL --max-time 30 -o "$shim_tmp" "$XATTR_SHIM_URL" && \
     echo "$XATTR_SHIM_SHA256  $shim_tmp" | sha256sum -c - >/dev/null; then
    mv "$shim_tmp" "$XATTR_SHIM"
  else
    rm -f "$shim_tmp"
    echo "setup-nix.sh: warning: xattr-retry shim could not be fetched; continuing without it" >&2
  fi
fi
if [ -f "$XATTR_SHIM" ]; then
  LD_PRELOAD="$XATTR_SHIM${LD_PRELOAD:+:$LD_PRELOAD}"
  export LD_PRELOAD
fi

BACKING=${1:-/home/hatch/nixdisk}
mkdir -p "$BACKING" /nix /etc/nix
cat > /etc/nix/nix.conf <<'CONF'
sandbox = false
build-users-group =
experimental-features = nix-command flakes
ignored-acls = security.csm security.selinux system.nfs4_acl security.tamper_marker user.hatch_tainted user.hatch_tainted.n user.hatch_tainted.u
CONF
mountpoint -q /nix || mount --bind "$BACKING" /nix

curl -fsSL https://nixos.org/nix/install -o /tmp/nix-install.sh
sh /tmp/nix-install.sh --no-daemon --yes || true
NIXBIN=$(ls -d /nix/store/*-nix-2.35.2 | head -1)
if [ ! -e /root/.nix-profile/bin/nix ]; then
  sudo HOME=/root "$NIXBIN/bin/nix-env" -i "$NIXBIN"
fi
export PATH="/root/.nix-profile/bin:$PATH"
nix-channel --add https://channels.nixos.org/nixpkgs-unstable nixpkgs || true
nix-channel --update
nix --version
