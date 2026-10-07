# Muse VM: Nix + Tailscale SSH enablement

Give your Muse VM two things it doesn't ship with:

1. **The Nix package manager**, installed so it survives VM reboots and
   replacements, install any of the 100k+ nixpkgs packages on your VM.
2. **Real Tailscale with SSH**: the full upstream Tailscale, so you can
   `ssh` into your Muse VM from your own devices over your tailnet.
   An optional ACL policy (recommended) can also make the VM
   receive-only, so it cannot initiate connections out to your other
   devices.

## Quick start

You don't install this by hand. Your Muse does it:

1. Copy the prompt block from [SYSTEM_PROMPT.md](SYSTEM_PROMPT.md) and
   send it to your Muse in chat.
2. Muse clones this repo and works through [INSTALL.md](INSTALL.md).
3. At three points Muse will stop and need you:
   - **Flip one setting.** In the Muse app or web UI:
     Settings > Permissions > Direct network protocols, set the rows
     to **Ask**. (There is no "allow" option; Ask is what lets
     Tailscale's connections be approved.)
   - **Approve the Tailscale login.** Click the login link Muse
     gives you and approve the VM in your browser. Muse will also
     offer you the optional ACL policy from
     `files/tailscale/policy.jsonc` to paste into your Tailscale
     admin console (see "Optional hardening" below); applying it
     also means adding yourself as owner of `tag:muse`.
   - **Approve a burst of connection prompts.** The first time
     Tailscale starts, it contacts its relay servers around the world
     to pick the fastest one. Each new address produces an approval
     prompt. It's a finite set; approve them and they stop.

After that, the setup maintains itself: reboots and VM replacements
self-recover with no further work.

## How it works, in one paragraph each

**Nix.** A Muse VM keeps only your home folder between reboots;
everything else is wiped. The Nix store therefore lives on a disk image
inside home and is bind-mounted into place on demand by a small wrapper
script. One configuration setting (`ignored-acls`) works around an
immutable file marker this platform stamps on files, which stock Nix
otherwise refuses to handle.

**Boot recovery.** There is no usable systemd for custom services
here, so a runtime hook polls every 5 seconds. It checks for a marker
file that only exists after a successful boot setup; the first poll
that finds it missing runs one Nix command, which triggers all the
self-healing. Steady-state cost is one file test, no agent, no
tokens, no wake-ups.

**Tailscale.** The platform's built-in Tailscale is a minimal client
that can't accept connections. This setup installs the full upstream
`tailscaled` from Nix and runs it in userspace-networking mode (the
VM's gateway passes no UDP, so relay-over-HTTPS is the data path).
Its state lives in your home folder, so the node stays registered
across reboots without re-login.

**Optional hardening: the ACL policy.** The Tailscale policy in
this repo makes the VM a pure SSH target: `tag:muse` is a source in
no rule, so the VM can initiate nothing on your tailnet, while your
own devices can reach it (and everything else) normally. Policy
tests are included so a future edit that breaks either half refuses
to save. This is a security feature, not a requirement: skip it and
the VM is a normal tailnet member with full access under your
account's existing policy, like any other device you own. SSH into
the VM works either way; the policy only controls what the VM can
initiate.

## Repo layout

| File | What it is |
|---|---|
| `README.md` | This document, for humans |
| `SYSTEM_PROMPT.md` | The copy/paste prompt to give Muse |
| `INSTALL.md` | The step-by-step guide Muse follows |
| `files/bin/nixwrap` | The wrapper behind every `nix`/`tailscale` command |
| `files/nix/setup-nix.sh` | Full Nix install/reinstall script |
| `files/hooks/nix-boot-trigger.sh` | The boot-recovery poll script |
| `files/hooks/nix-boot-trigger.json` | The hook's registration parameters |
| `files/scripts/bootstrap-tailscale.sh` | Idempotent tailscaled starter |
| `files/tailscale/policy.jsonc` | The Tailscale ACL policy (you paste this) |

## Security notes

- If you apply the ACL policy, it is what stands between "on your
  tailnet" and "can SSH in", and it limits SSH to your own account's
  devices. Without it, whatever your tailnet policy allows applies.
- The VM's Tailscale node key persists in
  `~/.local/state/tailscale/` (tagged nodes have key expiry off by
  default). To revoke the VM's access permanently, delete the node
  in the Tailscale admin console or delete that state folder.

## Requirements

- A Muse VM (the environment described in `INSTALL.md` §1)
- A Tailscale account (free tier is fine)
- Five minutes of your time, spread across Muse's work
