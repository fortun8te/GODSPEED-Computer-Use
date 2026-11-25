# Locked physical host with an isolated macOS guest

This route is for unattended jobs on an Apple Silicon Mac whose physical screen must remain locked. It does **not** unlock the host, interact with the login screen, replace the macOS lock, change code-signing requirements, or install privileged host components.

The public Godspeed build is ad hoc signed. A Developer ID certificate is not needed for this guest route. A completely unsigned executable may not run or receive the required macOS permissions, especially on Apple Silicon. Use a normal local development build; do not disable Gatekeeper, SIP, or TCC.

## Set up once, while present

1. Use an Apple-supported macOS guest (see [Apple's virtualization guide](https://developer.apple.com/documentation/virtualization/running-macos-in-a-virtual-machine-on-apple-silicon)). Allocate sufficient memory and disk space for your workload. Prefer a dedicated, non-admin guest account and a private host-only network where supported.
2. Log in to the guest normally and install Godspeed **inside the guest** using the [normal setup instructions](INSTALL.md). Launch it there and approve its ordinary Accessibility and Screen Recording permissions. Keep your personal files, passwords and accounts out of the guest where practical. The guest must have a usable logged-in desktop for GUI jobs.
3. In the guest, enable Remote Login only for the dedicated account if you want to use the host-side MCP client. Set up a dedicated SSH key using normal SSH authentication. Verify the guest's host key fingerprint through its local console before trusting it. Do not expose SSH to the public internet or use password automation.
4. Create a dedicated SSH config alias on the client (replace the example address and account with your guest's actual values):

   ```sshconfig
   Host godspeed-guest
       HostName <guest-private-address>
       User <guest-account>
       IdentityFile ~/.ssh/godspeed-guest
       IdentitiesOnly yes
   ```

   Verify the alias connects to the guest rather than the host. Authenticate normally and confirm the verified host key once before using the bridge. The bridge will fail on an untrusted or changed host key; it does not enroll keys for you.

5. Keep the physical host awake during the job using normal macOS energy settings. The host can be locked normally. Do not disable the host's lock or password requirements. The guest can still lock, sleep or lose its session; if that happens, stop GUI work and return to the guest console.

## Connect the MCP client

From the host or another authorized machine that can reach the guest:

```sh
python3 /absolute/path/to/godspeed/scripts/godspeed-guest-mcp.py godspeed-guest --check
```

To connect Codex:

```sh
codex mcp add godspeed-guest -- python3 /absolute/path/to/godspeed/scripts/godspeed-guest-mcp.py godspeed-guest
```

For other stdio clients, use the same command and arguments. The bridge forwards MCP stdin/stdout through an authenticated SSH connection to the **guest's** standard user-local Godspeed launcher. It does not send host UI input, forward the SSH agent, allocate a terminal, open port forwards, or execute caller-provided shell commands. It does not reconnect or replay interrupted writes; read current guest state before recovering a failed workflow.

If MCP initialization succeeds but GUI reads fail, confirm that the guest's app is running in its logged-in desktop session with the required permissions. A successful handshake is not proof of GUI availability. Do not use a privileged daemon as a substitute for the guest's normal app session.

## Validate before relying on unattended operation

Use a disposable guest Calculator or TextEdit window. Read it with Godspeed to obtain its Window ID. Run the following before and after manually locking the physical host (substitute the actual guest Window ID and installed version):

```sh
python3 /absolute/path/to/godspeed/scripts/godspeed-guest-mcp.py godspeed-guest \
  --check --version <installed-version> --probe-app Calculator --window-id 42
```

The optional probe reads a pinned guest window, without clicking, typing, capturing a screenshot or printing its contents. To verify screenshot and action delivery, separately run a harmless task in the disposable guest and inspect its final state. Record actual host lock state independently; the probe does not attest to it.

| Scenario | Required outcome |
| --- | --- |
| Host unlocked, guest logged in | MCP and disposable GUI probe work. |
| Host locked normally, guest logged in | Same probe and harmless verified guest task work; physical host stays locked. |
| Guest locked or logged out | GUI task stops; no host or guest unlock attempt. |
| Guest disconnected or shut down | Clear transport failure; no automatic action replay. |
| Guest host key changed | SSH refuses; investigate and verify the new key before reconnecting. |
| Missing guest permissions | Report failure; approve permissions in the guest through normal macOS UI. |

For a useful comparison, measure completion rate and p50/p95 latency for identical disposable tasks on the unlocked host and guest. Report host memory pressure and guest configuration. Do not claim locked-host GUI support based only on tools/list or mock tests.

## Native Locked Use

The experimental privileged native implementation is a separate trust boundary. It requires the existing signed, validated components and explicit local administrator enrollment. Public builds do not package it. This transport does not change its signature requirements or enable access to the host's locked desktop.

Live validation of this guest configuration is still required; the transport and its protocol checks can be tested without a VM using the mock subprocess tests:

```sh
python3 -I -m unittest discover -s scripts/tests -p 'test_godspeed_guest_mcp.py'
```
