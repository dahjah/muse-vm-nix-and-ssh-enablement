# Muse VM setup guide: Nix + Tailscale SSH

## 0. For the Muse instance receiving this document

You are being handed a working system to reproduce.
Execute in the order below; every script is idempotent, so re-running a
step is safe. Sections §1–§10 explain *why*; the `files/` tree holds the
exact scripts. If `/home/hatch` already contains the files (same VM, state loss
only), skip to the §9 checklist instead.

**Steps only the user can do: ask for them, never work around them:**
1. Settings > Permissions: enable the necessary Direct network
   protocols (each is a checkbox), and under **Advanced** turn
   **off** SNI mismatch rejection. Both are required (see §2).
2. Approve the Tailscale login URL in their browser when you present it.
   Optional and recommended: also offer the §7 ACL policy, which makes
   the VM receive-only. It requires `tag:muse` in their tailnet policy
   with the user as tagOwner; if their account already has it saved,
   it persists server-side, don't duplicate it. If the user would
   rather the VM have normal, full tailnet access, skip the policy
   entirely; the standard `up` command in §7 is all they need.
3. Approve the burst of per-IP "wants to connect" prompts that follows a
   Tailscale start (the DERP sweep, §7). There is no auto-approve; warn
   them it's coming, once, instead of apologizing per prompt.

**Phase B: lay down the files (skip any that already exist):**
Copy from this repo's `files/` tree to the target paths, and `chmod +x`
each script:

| Repo file | Target |
|---|---|
| `files/bin/nixwrap` | `/home/hatch/bin/nixwrap` |
| `files/scripts/bootstrap-tailscale.sh` | `/home/hatch/scripts/bootstrap-tailscale.sh` |
| `files/hooks/nix-boot-trigger.sh` | `/home/hatch/hooks/scripts/nix-boot-trigger.sh` |
| `files/nix/setup-nix.sh` | `/home/hatch/workspace/nix/setup-nix.sh` |

- Create directories: `~/bin`, `~/scripts`, `~/.config/vm-tailscale`,
  `~/.local/state/tailscale`.
- Symlink farm: `for t in nix nix-env nix-shell nix-build nix-store
  nix-channel nix-instantiate nix-collect-garbage nix-hash
  nix-copy-closure nixsh tailscale tailscaled; do ln -sf nixwrap
  /home/hatch/bin/$t; done`
- Flag: `touch ~/.config/vm-tailscale/autostart`

**Phase C: Nix:** run `sh ~/workspace/nix/setup-nix.sh` (repo:
`files/nix/setup-nix.sh`), then
`/home/hatch/bin/nix-env -iA nixpkgs.tailscale`. Done when
`nix --version` prints 2.35.2 and a real store operation (e.g.
`nix-env -iA nixpkgs.hello`) succeeds. If an install ever fails naming a
`user.hatch_tainted.<new-suffix>` attribute, append that suffix to
`ignored-acls` in §4's config (all three places it lives) and retry.

**Phase D: boot hook:** register `nix-boot-trigger` exactly as in §6,
dry-run both marker branches, enable it. Done when the hook log shows one
bootstrap poll followed by ~20 ms silent polls.

**Phase E: Tailscale:** start the daemon and run `up` exactly as in §7,
present the login URL to the user (step 2 above). The §7 ACL policy
is optional: offer it, and if the user declines, follow §7's skip path.
Afterwards verify
`tailscale status --json` shows `BackendState: Running`, `Online: true`,
`Health: []`. Done means the user can `ssh root@muse-vm` from their own
device. From then on, reboots self-recover the whole stack; your only
recurring job is not to be surprised by it.


## 1. The machine

- Dedicated Muse Secure VM: 2 CPUs, 7.7 GiB RAM, Ubuntu 24.04.5 LTS, hostname `htch-runtime`, systemd-nspawn cell (PID 1 = systemd 255).
- Commands run as **root (uid 0)**, but the session `HOME` is `/home/hatch`.
- Filesystems: this split drives every design decision:
  - `/home/hatch` = 100 GB btrfs volume (`/dev/mapper/rv`). **Persists across reboots and VM replacement.** Everything durable must live here.
  - `/` = overlay, 7.5 GB, upper layer in `/run/hatch/overlay/upper` (tmpfs). **Everything outside home is wiped on every cell restart**: `/etc`, `/root`, `/nix` mount point, `/tmp`, `/run`.
- Initially nothing listening; no sshd (client only).

## 2. Settings only the user can change (Muse app / web Settings)

- **Settings > Permissions > Direct network protocols**: each protocol is a toggle (Outbound SSH; Outgoing email (SMTP); Email mailbox access (IMAP, POP3); Database connections; File transfer (FTP); External DNS lookups; Other TCP connections; Other UDP traffic). Off blocks the protocol; on lets the assistant ask for approval per connection. Required for this setup: **Other TCP connections** (the Tailscale control plane and its DERP relays are direct TCP connections) and **External DNS lookups** (tailscaled resolves the control and relay hostnames itself). Not needed: the SMTP, IMAP/POP3, database, and FTP toggles. Other UDP traffic cannot succeed through this gateway at all, so it can stay off. Outbound SSH is needed only if the agent itself makes SSH connections (for example, git over SSH).
- Advanced: **SNI mismatch rejection** must be turned **off**; this setup does not work with it on.
- Approvals are per single IP:port ("Always allow" covers only that destination). There is **no auto-approve**. Only the user can approve; the agent cannot. Prompt cards attribute the request to "your assistant", the VM has no network identity separate from the agent runtime, so daemon traffic (e.g. tailscaled's) is presented as the agent's. Leaving *Other UDP traffic* off refuses the UDP class (which cannot succeed through this gateway anyway) and shrinks prompt volume; the TCP set (control plane + DERP map) is finite and saturates via per-IP approvals.

## 3. Network/gateway behavior

- All egress funnels through a gateway (fake-IP DNS: public names resolve to 198.18.x.x; gateway at 198.19.0.1:3128, also IPv6 `fd8b:4f84:7d32:99::1`, host `hatch-egress-proxy`). An explicit HTTP proxy is in the agent shell's environment.
- **Direct TLS works only when SNI == the DNS-mapped destination hostname.** Mismatched SNI is killed (EOF). No-SNI and matching-SNI handshakes succeed.
- **UDP is effectively dead** (tailscaled netcheck: "UDP is blocked"). TCP via the explicit proxy CONNECT works broadly.
- Consequence: anything that must receive connections does so over a **persistent outbound TCP/TLS connection** (DERP), never via inbound ports (there are none) and never via UDP.

## 4. Nix (the centerpiece)

### The problem
Files on the regular filesystems acquire immutable extended attributes in the
`user.hatch_tainted*` family (variants observed: bare `user.hatch_tainted`,
`.n`, `.u`, **the suffix set differs between boots**, so the config lists all
observed variants; if a future install fails naming a new variant, append it
in all three places listed below). Stock Nix aborts registering store paths:
`removing extended attribute 'user.hatch_tainted...' ... Operation not permitted`.
The attributes cannot be removed from inside (setfattr → EPERM), including via
the real `attr` tools. tmpfs (`/tmp`, `/var/tmp`) is exempt but non-persistent.

### The fix: Nix's `ignored-acls`
`/etc/nix/nix.conf`:
```
sandbox = false
build-users-group =
experimental-features = nix-command flakes
ignored-acls = security.csm security.selinux system.nfs4_acl security.tamper_marker user.hatch_tainted user.hatch_tainted.n user.hatch_tainted.u
```
(`sandbox = false` + empty build-users-group because the root sandboxed
builder cannot write the store here.)

### Layout
- Nix **2.35.2**, official installer, single-user. Channel: nixpkgs-unstable.
- Store backing on the persistent volume: **`/home/hatch/nixdisk`** (contains `store/` + `var/`), bind-mounted over `/nix` per session (mounts don't persist).
- Profile lives in the volume (`/nix/var/nix/profiles/default`); the symlink `/root/.nix-profile` and `/etc/nix/nix.conf` live on the ephemeral overlay.

### The wrapper: `/home/hatch/bin/nixwrap`
Symlinks in `/home/hatch/bin/` (`nix`, `nix-env`, `nix-shell`, `nix-build`,
`nix-store`, `nix-channel`, `nix-instantiate`, `nix-collect-garbage`,
`nix-hash`, `nix-copy-closure`, `nixsh`, plus `tailscale`/`tailscaled`) all
point to `nixwrap`, which on every invocation:
1. `mkdir -p /nix` if absent (fresh overlay has no `/nix`),
2. bind-mounts `/home/hatch/nixdisk` over `/nix` if not mounted,
3. recreates `/etc/nix/nix.conf` if absent (content above),
4. recreates `/root/.nix-profile` symlink and `/root/.nix-channels` if absent,
5. runs the companion bootstraps whose opt-in flags exist
   (tailscale, §7; the API Bridge module, §11).

The order of steps 3-5 matters: the bootstrap starts a binary that
lives in the profile, so the profile must be recreated first. If
the bootstrap runs before step 4 on a fresh boot, it finds no
binary and gives up, and nothing retries it until the next manual
nix invocation.
6. execs the real tool from `/root/.nix-profile/bin`.

Full-reinstall script (fresh VM): **`~/workspace/nix/setup-nix.sh`**: it
installs Nix itself but does NOT create the symlink farm, install packages,
or lay down any scripts; on a fresh instance follow §0 Phase B/C for those.
Installed via nix so far: hello, attr 2.6.0, cowsay, tailscale 1.102.5.

## 5. Why not systemd (persistence investigation)

- Boot target is a custom minimal `/etc/systemd/system/default.target` that
  does **not** pull in `multi-user.target`; `WantedBy=multi-user.target`
  services never start.
- Unit files in home + symlinks in `/etc` *are* discovered and run within a
  boot, but the symlinks sit on the ephemeral overlay, gone next boot.
- No user manager in agent sessions; `.bashrc`/`.profile` never fire (shells are `--norc --noprofile`).
- Conclusion: no userspace mechanism gets code running at boot from inside the
  guest. The runtime's saved jobs (crons/hooks) are the only restored layer.

## 6. Boot recovery: the hook (replaced a 1-minute agent cron)

- Hook id **`nix-boot-trigger`**: a runtime-saved automation whose **Bash
  script** (`~/hooks/scripts/nix-boot-trigger.sh`, repo:
  `files/hooks/nix-boot-trigger.sh`) is polled by the runtime every
  **5 s** as plain shell, **no model
  tokens**. Polls consume nothing but a few ms of CPU.
- Boot detection uses a marker trick: the script checks
  `/tmp/.nix-bootstrapped`. `/tmp` is tmpfs, so the marker is gone after
  every restart; the first poll that misses it runs
  `/home/hatch/bin/nix --version` (which mounts the store, self-heals the
  config/profile), writes the marker, and
  goes silent. Later polls are a single file test (~20 ms).
- Failure behavior (deliberate): log the failure to the hook
  log (`~/hooks/logs/nix-boot-trigger.jsonl`), **stay silent, never wake an
  agent**; the marker stays absent so the next poll retries. The hook's
  worker-prompt field (platform-required, non-empty) is literally `None.`
  and the script contains no `wake` call at all.
- An earlier design, a cron waking an agent every minute to run the same
  command, worked but paid the full agent context per run (~1,440/day);
  it was removed the same day.
- After a reboot the hook resumes polling by itself. Its retries are
  what surface incomplete self-healing; the failure modes to expect are
  a missing `/nix` mount point, a missing `/root/.nix-profile`, and a
  missing `/etc/nix/nix.conf` (all overlay losses). nixwrap (§4)
  recreates all three.


**Registration (exact parameters, for recreation):** the definition is a
runtime-saved record (mirror at `~/hooks/definitions/nix-boot-trigger.json`):

```json
{
  "id": "nix-boot-trigger",
  "script_path": "~/hooks/scripts/nix-boot-trigger.sh",
  "prompt": "None.",
  "poll_interval_secs": 5,
  "script_timeout_secs": 240,
  "delivery": {"surface": "main"},
  "enabled": true
}
```

Recreate by: writing the script (repo: `files/hooks/nix-boot-trigger.sh`)
to that path and making it
executable, registering a hook with the parameters above (it starts
disabled), dry-running it twice, marker present → `silent`; marker absent
→ `silent` with a "would bootstrap" log line (dry runs change nothing),
then enabling it and confirming in `~/hooks/logs/nix-boot-trigger.jsonl`
that a live poll bootstraps and subsequent polls are ~20 ms silents.
House rules learned here: the script must `source "$HATCH_HOOK_RUNTIME"`,
end with exactly one `silent`/`wake` decision (this one never wakes), and
guard state writes behind the `HATCH_HOOK_DRY_RUN` check.


## 7. Tailscale

- The platform's built-in `tailscale` (`/opt/hatch/bin/tailscale`) is a
  client-only shim: only up/down/status/ip, no `--ssh`, accepts no inbound.
  It cannot be uninstalled (`/opt/hatch/bin` is platform-owned, read-only)
  and was never connected, so it is simply ignored. Bare `tailscale` still
  resolves to it (PATH order); use `/home/hatch/bin/tailscale`.
- Full upstream **tailscale + tailscaled 1.102.5** installed via Nix (§4).
- Daemon start (userspace mode; state in home):
  ```
  mkdir -p /run/tailscale
  env -u HTTPS_PROXY -u HTTP_PROXY -u https_proxy -u http_proxy \
    setsid /home/hatch/bin/tailscaled --tun=userspace-networking \
      --statedir=/home/hatch/.local/state/tailscale \
      >/home/hatch/.local/state/tailscale/tailscaled.log 2>&1 &
  /home/hatch/bin/tailscale up --ssh --hostname=muse-vm
  ```
- The node joins under the user's own identity, with whatever their
  existing tailnet policy allows. No tags and no ACL changes are
  involved. (With the optional ACL policy below, the node must carry
  the tag instead: add `--advertise-tags=tag:muse` to the `up`
  command.)
- Networking facts: through the env proxy, control registration fails
  (HTTP 400 via :3128; reset via the :3130 tailnet proxy). **Direct works**,
  hence the proxy env must be removed for the daemon. Direct UDP is dead, so
  peers are reached via DERP relays over TCP 443 (home relay: Dallas).
- **Login persistence:** the node key and control-plane registration live
  in `tailscaled.state` inside the statedir above (home = persistent), so
  reboots and daemon restarts reconnect with **no new login**. A fresh login is needed only
  if the statedir is deleted or the node is removed in the admin console.
- `/dev/net/tun` exists and `cap_net_admin` is in the bounding set, so
  kernel-TUN mode might work; it was never needed, userspace mode plus
  DERP covers everything here.
- **Autostart (opt-in):** nixwrap runs
  `/home/hatch/scripts/bootstrap-tailscale.sh` (repo:
  `files/scripts/bootstrap-tailscale.sh`) on every nix
  invocation when the flag `/home/hatch/.config/vm-tailscale/autostart`
  exists, so the boot hook's post-reboot nix call brings tailscaled up
  and reconnects it automatically. The script is
  idempotent, strips the proxy env itself, uses the statedir above, and
  only logs (never blocks) on trouble; a `NeedsLogin` state still needs a
  human with a browser. The manual command block above remains the
  fallback. Boot-time DERP/probe connection prompts are expected and
  the user approves them.
- Approvals: the daemon's DERP sweeps and probes generate per-IP "wants to
  connect" prompts (a finite set, roughly the DERP map, v4+v6).
  No auto-approve exists. Leaving the *Other UDP traffic* toggle off
  silences the UDP class, which can never succeed here anyway.
- **Optional security feature (recommended): the receive-only ACL
  policy.** Without it the VM is a normal tailnet node with full
  access under the account's existing policy. With it, the whole
  pattern is one idea: **tag:muse is a source in no rule**, so the VM
  can initiate nothing, while the owner's devices can reach it (and
  everything else) freely. An `ssh` rule covers Tailscale SSH into
  the tagged node (ACLs alone don't govern it), and the policy's
  `tests` section locks both halves in, Tailscale refuses to save the
  policy if a future edit breaks them. The complete policy is
  `files/tailscale/policy.jsonc`
  in this repo; its contents go in the Tailscale admin console's
  policy editor, replacing what is there. (The user's
  step-by-step for applying it is in the README's Security
  section.)


## 8. Expected end state (example values; yours will differ)

A finished setup looks like this (example node name and address shown;
expect the same *shape*, not the same values):

- Nix 2.35.2 working; hello, attr, cowsay, and tailscale installed in
  the profile.
- Hook `nix-boot-trigger` enabled, polling every 5 s; marker present.
- tailscaled running with autostart enabled (§7); node online, Health
  `[]` (no DERP or ACL warnings).
- Platform Tailscale shim: unused, not connected.

## 9. Rebuild checklist (fresh VM or full loss of state)

Home (`/home/hatch`) and all scripts survive VM replacement, so a rebuild
is mostly re-running and verifying, in this order:

1. Settings > Permissions > Direct network protocols: enable the
   required protocols (§2; user only, the agent cannot).
2. Run any wrapper once, `/home/hatch/bin/nix --version`, and let nixwrap
   self-heal (mount point, nix.conf, profile link). If the store itself is
   gone, run `~/workspace/nix/setup-nix.sh` first.
3. `nix-env -iA nixpkgs.tailscale` if the profile lacks it.
4. Confirm the hook `nix-boot-trigger` exists and is enabled (definitions
   are runtime-saved; recreate from §6 + `files/hooks/` if missing).
5. tailscaled autostarts via its flag (§7); if the node shows
   NeedsLogin, run the §7 command block and approve the login URL.
6. If the ACL policy was applied, it lives in the user's Tailscale
   account (server-side), so it survives; verify `tailscale status`
   Health is `[]`.
7. If the node itself was ever deleted from the tailnet, redo
   `tailscale up --ssh --hostname=muse-vm` (adding
   `--advertise-tags=tag:muse` if the ACL policy is in use) and
   approve the login URL in a browser.
8. If the API Bridge module (§11) is enabled, confirm its flag
   exists and the server answers `curl 127.0.0.1:8080/health` after
   the first nix call of the boot.

## 10. Known quirk: taint-marker suffixes

The suffix variants in `ignored-acls` may gain new forms on future
boots (two variants have been seen: `.n` and `.u`). If an
install ever fails naming a `user.hatch_tainted.<new-suffix>`
attribute, append that exact suffix to `ignored-acls` in all three
places it lives (§4) and retry.

## 11. Optional module: API Bridge (OpenAI-compatible endpoint)

An optional add-on that exposes this VM's Muse agent as an
OpenAI-compatible HTTP endpoint on the tailnet, so programs on the
user's other devices can send chat requests to it. It spends the
user's normal Muse usage (each request is an ordinary agent turn
in a dedicated side chat). Skip this section entirely if the user
does not want it.

Components (all in this repo):

- `files/api-bridge/`: a self-contained Nix module.
  `api-bridge.nix` is a derivation packaging `server.py` (the HTTP
  server) and `bridge-respond` (the answer-delivery tool) into the
  profile as `muse-api-bridge-server` and `bridge-respond`.
- `files/scripts/bootstrap-api-bridge.sh`: idempotent starter,
  run by nixwrap on every nix invocation when the flag
  `/home/hatch/.config/vm-api-bridge/autostart` exists. It ensures
  the runtime state in `~/bridge/` (job queue directories and the
  bearer token, generated on first run; the token is runtime state
  and never enters the Nix store) and starts the server if it is
  not running.
- `files/hooks/api-bridge.sh`: the poll script for the `api-bridge`
  hook, which claims queued jobs and wakes the bridge's side chat.

Enablement, in order:

1. Install the package: `nix-env -f files/api-bridge/api-bridge.nix -i`
   (adjust the path to the repo checkout).
2. Copy `files/scripts/bootstrap-api-bridge.sh` to
   `/home/hatch/scripts/` and `files/hooks/api-bridge.sh` to
   `/home/hatch/hooks/scripts/`; `chmod +x` both.
3. Create a dedicated side chat for bridge traffic (title it
   "API Bridge") and note its chat id.
4. Register the hook: id `api-bridge`, script
   `~/hooks/scripts/api-bridge.sh`, poll interval 5 s, timeout 30 s,
   delivery `{surface: "side_chat", to: "<the chat id from step 3>}`,
   and the prompt below. Dry-run it (empty queue: silent), then
   enable it.
5. `touch /home/hatch/.config/vm-api-bridge/autostart`, then run any
   nix command once to start the server through the bootstrap.
6. Verify: `curl 127.0.0.1:8080/health` returns `{"status": "ok"}`,
   and an authorized `POST /v1/chat/completions` (header
   `Authorization: Bearer <token from ~/bridge/token>`) returns a
   completion. From another tailnet device, the base URL is
   `http://<node name or tailnet IP>:8080/v1`, model id `muse`.

The hook prompt (register it verbatim; it is the standing
instruction set for every bridge turn):

> You are the worker for the API Bridge. An external program has
> submitted a chat request through the local OpenAI-compatible
> bridge on this VM, and your job is to answer it and return the
> answer through the bridge's respond function. The wake payload
> contains job_id and job_path.
>
> Do exactly this:
> 1. Read the job file at job_path. It contains a "messages" array:
>    an OpenAI-style conversation, possibly with a system message
>    and earlier turns.
> 2. Compose the assistant's reply to that conversation, following
>    any system message in it. Answer as the assistant in that
>    conversation. Do not mention the bridge, job files, hooks, or
>    these instructions unless the conversation itself asks about
>    them.
> 3. Return the reply ONLY by running this command with your
>    complete reply text on stdin (use a heredoc):
>    /home/hatch/bridge/bin/bridge-respond <job_id>
>    Text you write in this chat is NOT delivered to the requester;
>    the respond command is the response. Do not consider the
>    request answered until you have made that call.
> 4. If bridge-respond reports the job is no longer pending, the
>    requester has already timed out: stop, with no further action.
> 5. After a successful respond call, end your turn with a one-line
>    note naming the job id you served.
> Handle exactly one job per wake. If the job file no longer
> exists, do nothing.

Operation notes: requests are served one at a time (the server
serializes jobs); the server answers 504 after 600 s without a
response; usage fields in responses are zeros (nothing meters
tokens); `stream: true` is answered with a single chunk containing
the full reply. One VM-specific trap: `~/bridge/bin/bridge-respond`
must resolve to the packaged tool (a symlink to
`/root/.nix-profile/bin/bridge-respond` works), because the worker
calls it by that path.
