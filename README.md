# Muse VM: Nix + Tailscale SSH enablement

Give your Muse VM two things it doesn't ship with:

1. **The Nix package manager**, installed so that it survives VM
   reboots and replacements, allowing full access to nixpkgs
   instead of the limited apt packages available within the muse
   VM.
2. **Full Tailscale with SSH support**: the upstream `tailscaled`,
   allowing SSH access to the VM from other devices on the same
   tailnet. An optional ACL policy (recommended) can additionally
   restrict the VM to receive-only operation, preventing it from
   initiating connections to other tailnet devices.

## Quick start

Installation is performed by a Muse agent, not manually:

1. Copy the prompt block from [SYSTEM_PROMPT.md](SYSTEM_PROMPT.md)
   and send it to Muse in chat.
2. Muse clones this repository and follows [INSTALL.md](INSTALL.md).
3. The process pauses at three points for user action:
   - **Permissions settings.** In the Muse app or web UI, under
     Settings > Permissions, enable the necessary Direct network
     protocols (each is enabled with a checkbox), and under
     **Advanced** turn off **SNI mismatch rejection**. Both changes
     are required.
   - **Tailscale login approval.** Open the login link provided by
     Muse and approve the VM in a browser. Muse will also offer
     the optional ACL policy described under Security below;
     applying it is a short procedure in the Tailscale admin
     console, separate from the login approval.
   - **Connection prompt approvals.** On first start, Tailscale
     contacts its relay servers worldwide to select the fastest one.
     Each new address generates an approval prompt. The set is
     finite; once approved, the prompts stop.

After installation, the setup is self-maintaining: reboots and VM
replacements recover automatically.

## How it works

### Nix

A Muse VM preserves only the home directory between reboots; all
other filesystems are wiped. The Nix store therefore resides on a
disk image inside the home directory and is bind-mounted into place
on demand by a wrapper script. A single configuration setting
(`ignored-acls`) works around an immutable file marker that this
platform stamps on files, which stock Nix otherwise refuses to
process.

### Boot recovery

No usable systemd is available for custom services in this
environment. Instead, a runtime hook polls every 5 seconds for a
marker file that exists only after a successful boot setup. The
first poll that finds the marker missing runs a single Nix command,
which triggers the wrapper's self-healing steps. In steady state,
each poll is a single file test: no agent is woken and no tokens are
consumed.

### Tailscale

The platform's built-in Tailscale is a minimal client that cannot
accept inbound connections. This setup installs the full upstream
`tailscaled` from Nix and runs it in userspace-networking mode,
because the VM's gateway passes no UDP and relay-over-HTTPS is the
available data path. Daemon state is stored in the home directory,
so the node remains registered across reboots without re-login.

## Repository layout

| File | Description |
|---|---|
| `README.md` | This document |
| `SYSTEM_PROMPT.md` | Copy/paste prompt for delegating the installation to Muse |
| `INSTALL.md` | Step-by-step installation guide followed by Muse |
| `files/bin/nixwrap` | Wrapper invoked by every `nix`/`tailscale` command |
| `files/nix/setup-nix.sh` | Full Nix install/reinstall script |
| `files/hooks/nix-boot-trigger.sh` | Boot recovery poll script |
| `files/hooks/nix-boot-trigger.json` | Hook registration parameters |
| `files/scripts/bootstrap-tailscale.sh` | Idempotent `tailscaled` starter |
| `files/tailscale/policy.jsonc` | Tailscale ACL policy for the admin console |

## Security

By default, the VM joins the tailnet under the account owner's
identity, and the account's existing policy applies unchanged. The
Tailscale node key persists in `~/.local/state/tailscale/`; to
revoke the VM's access permanently, delete the node in the
Tailscale admin console or delete that state directory.

### Optional: apply the receive-only ACL policy

The policy makes the VM a pure SSH target: `tag:muse` appears as
a source in no rule, so the VM can initiate nothing on the
tailnet, while the owner's devices retain normal access to it and
to everything else. The policy includes tests, so a later edit
that breaks either property causes Tailscale to refuse the save.

This policy is a security feature, not a requirement. If it is
skipped, the VM is a normal tailnet member with full access under
the account's existing policy. SSH access to the VM works in
either configuration; the policy only controls what the VM can
initiate.

To apply it, the user performs the following in the Tailscale
admin console:

1. Open the admin console and go to **Access Controls**, the policy
   editor.
2. Replace the policy with the contents of
   [files/tailscale/policy.jsonc](files/tailscale/policy.jsonc).
   The policy defines `tag:muse`, grants every tailnet member the
   right to apply it (`tagOwners`), gives the owner's devices
   allow-all access, and adds an SSH rule for the tagged VM.
3. In the `tests` section, replace `your-own-login@example.com`
   with your own Tailscale login.
4. If the tailnet has other tagged devices that must keep normal
   access, add their tags to the `src` list of the allow-all rule,
   as the comments in the file describe. A tag that appears as a
   source in no rule can initiate nothing, which is the intent for
   `tag:muse` but will silently lock out any other tag that is
   forgotten. Do not add `tag:muse` as a source.
5. Save. Tailscale evaluates the policy's `tests` on save and
   refuses to save if any check fails.
6. Tell Muse the policy is saved, ideally before approving the
   VM's login link. Muse then joins the VM with
   `--advertise-tags=tag:muse` so the policy applies to it from the
   start.

## Requirements

- A Muse VM (the environment described under "The machine" in [INSTALL.md](INSTALL.md))
- A Tailscale account (the free tier is sufficient)
- A few minutes for the manual steps listed under Quick start
