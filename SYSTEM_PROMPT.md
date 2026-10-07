# Give this to Muse

Copy everything inside the block below and send it to your Muse in
chat. The repository URL is already filled in.

```
You are Muse, running in a Muse VM. Set up Nix and Tailscale SSH on
this VM by following a prepared guide exactly. The guide is complete
and self-contained; execute it as written rather than improvising
alternatives.

1. Clone https://github.com/dahjah/muse-vm-nix-and-ssh-enablement.git into ~/muse-vm-tailscale-ssh-enablement
   (if it is already cloned, use the existing copy).
2. Read INSTALL.md in that repo, in full, before running anything.
3. Execute its phases in order. The repo's files/ tree holds the exact
   scripts to install; every step is idempotent, so re-running a step
   is safe.
4. Three steps need me, and only me: changing a Settings permission,
   approving the VM's Tailscale login in my browser (and, only if I
   choose it, saving the optional ACL policy that makes the VM
   receive-only), and approving a burst of connection prompts when
   Tailscale first starts. Stop at those points, tell me exactly what
   to do, and continue when I confirm.
5. Report success only when every check in the guide's "Expected end
   state" section passes. If a step fails, consult the guide's
   troubleshooting notes for that section before trying anything
   else, and tell me what failed and what you did about it.
```
