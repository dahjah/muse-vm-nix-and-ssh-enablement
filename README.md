# Muse VM: Nix + Tailscale SSH enablement

Give your Muse VM two things it doesn't ship with:

1. **The Nix package manager**, installed so that it survives VM
   reboots and replacements, allowing full access to nixpkgs
   instead of the limited apt packages available within the muse
   VM.
2. **Full Tailscale with SSH support**: the built-in Tailscale is
   a minimal client that cannot accept inbound connections. This
   installs the full upstream `tailscaled`, allowing SSH access
   to the VM from other devices on the same tailnet. An optional
   ACL policy (recommended) can additionally restrict the VM to
   receive-only operation.

## Quick start

Installation is performed by a Muse agent, not manually:

1. Copy the prompt block from [SYSTEM_PROMPT.md](SYSTEM_PROMPT.md)
   and send it to Muse in chat.
2. Muse clones this repository and follows [INSTALL.md](INSTALL.md).
3. The process pauses at three points for user action:
   - **Permissions settings.** In the Muse app or web UI, under
     Settings > Permissions, enable **Other TCP connections** and
     **External DNS lookups** (Direct network protocols, each is a
     toggle), and under **Advanced** turn off **SNI mismatch
     rejection**. The remaining protocol toggles are not needed for
     this setup.
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
which triggers the wrapper's self-healing steps. Recovery is
idempotent: every step checks whether its piece is already in
place before recreating it, so a partial failure is simply
retried on the next poll and repeated boots converge to the same
state.

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
| `files/bin/xattr-retry.c` | Source of the xattr-retry preload shim (CI publishes the built .so as a release asset) |
| `files/nix/setup-nix.sh` | Full Nix install/reinstall script |
| `files/nix/ignored-acls.txt` | Single source for the `ignored-acls` list in nix.conf |
| `files/scripts/install-files.sh` | Phase B installer (records the install manifest; `--check` reports drift) |
| `files/scripts/doctor.sh` | Layer-by-layer health check (§9) |
| `files/hooks/nix-boot-trigger.sh` | Boot recovery poll script |
| `files/hooks/nix-boot-trigger.json` | Hook registration parameters |
| `files/scripts/bootstrap-tailscale.sh` | Idempotent `tailscaled` starter |
| `files/tailscale/policy.jsonc` | Tailscale ACL policy for the admin console |
| `files/api-bridge/` | Optional module: OpenAI-compatible bridge package (server, respond tool, derivation) |
| `files/scripts/bootstrap-api-bridge.sh` | Idempotent starter for the bridge server |
| `files/hooks/api-bridge.sh` | Poll script for the bridge job hook |

## Optional module: API Bridge

The repository also contains an optional module that exposes the
VM's Muse agent as an OpenAI-compatible HTTP endpoint on the
tailnet (`files/api-bridge/`, packaged with Nix), for users who
want to point their own programs or agents at Muse over
Tailscale. It is opt-in and independent of the base setup;
`INSTALL.md` §11 covers installation and operation.

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

To apply it, the user works in the Tailscale admin console,
under **Access Controls** (the policy editor). Which path to
take depends on the state of the existing policy. The
complete example policy is
[files/tailscale/policy.jsonc](files/tailscale/policy.jsonc).

**If the existing policy is the untouched Tailscale default**
(or contains nothing worth keeping), it can be replaced
wholesale with the contents of that file. Then replace
`your-own-login@example.com` in its `tests` section with your
own Tailscale login, and heed the warning about other tags
below before saving.

**If the existing policy has rules that matter, merge
instead.** Merging only adds entries; nothing existing is
removed or changed, so every device keeps the access it has
now. Four additions, all taken from the example file:

1. In `tagOwners`, add the entry
   `"tag:muse": ["autogroup:member"]`.
2. In `acls`, confirm an accept rule lets members reach the
   VM. The untouched default already contains exactly this
   rule, in which case nothing needs adding:

   ```jsonc
   {
       "action": "accept",
       "src":    ["autogroup:member"],
       "dst":    ["*:*"],
   },
   ```

   If the policy is more restrictive, append this narrower
   entry to the `acls` array instead, which grants members
   access to the VM and nothing else:

   ```jsonc
   {
       "action": "accept",
       "src":    ["autogroup:member"],
       "dst":    ["tag:muse:*"],
   },
   ```

   The property that must hold either way, and the whole
   mechanism of the policy: `tag:muse` appears as a source
   in no rule anywhere.
3. Append this entry to the `ssh` array:

   ```jsonc
   {
       "action": "accept",
       "src":    ["autogroup:member"],
       "dst":    ["tag:muse"],
       "users":  ["autogroup:nonroot", "root"],
   },
   ```

   The example file's second SSH rule (the `autogroup:self`
   check rule) is part of the default policy already; add it
   only if it is missing.
4. Append the two entries from the file's `tests` array to
   the policy's `tests` (creating the array if it has none),
   replacing `your-own-login@example.com` with your own
   Tailscale login.

Either way, finish with:

5. Save. Tailscale evaluates the policy's `tests` on save
   and refuses to save if any check fails.
6. Tell Muse the policy is saved, ideally before approving
   the VM's login link. Muse then joins the VM with
   `--advertise-tags=tag:muse` so the policy applies to it
   from the start.

Warning, for the wholesale path only: if the tailnet has
other tagged devices, a replaced policy leaves their tags as
a source in no rule, and a tag that appears as a source in
no rule can initiate nothing, so they are silently locked
out unless their tags are added to the `src` list of the
allow-all rule, as the comments in the file describe. Do not
add `tag:muse` as a source. Merging does not have this
problem, because it removes nothing.

## Requirements

- A Muse VM (the environment described under "The machine" in [INSTALL.md](INSTALL.md))
- A Tailscale account (the free tier is sufficient)
- A few minutes for the manual steps listed under Quick start
