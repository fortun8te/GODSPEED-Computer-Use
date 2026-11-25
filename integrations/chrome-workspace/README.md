# Godspeed browser workspace

This integration packages a reviewed Open Browser Use extension with Godspeed's shared visual workspace. It is a separate extension build; it does not modify an already installed browser or helper.

## Visible behavior

Owned work tabs share a **Godspeed** group in each normal Chrome window. The native purple chip uses title case. The group moves to the left after pinned tabs and starts collapsed when none of its tabs is active. A user can expand it, select a tab, or keep a pinned tab without the extension reversing that choice. Tab and group events schedule coalesced local repair; Chrome's temporary refusal to edit tabs during a user drag gets a finite retry schedule.

The group is presentation, not permission. Multiple sessions can share it without gaining access to each other's work. Tabs manually dragged into the group do not become agent-owned. A user tab enters a session only through an explicit claim. An ordinary popup is not auto-claimed based on its opener or timing: that could be a human's popup. Exact `Target.createTarget` results can establish agent creation after Chrome resolves the returned target to a tab. Other popups require an explicit claim before automation.

Each session retains its own `tabOrigins`. Finalization only cleans up that session's temporary agent tabs, returns claimed user tabs, and reserves retained deliverables for their originating session. Retained results stay visible in the workspace. Group membership alone cannot authorize listing page details, reading, CDP access, claiming, finalizing or closing another session's tab.

This scopes direct tab operations among cooperating clients. It is not an origin or browser-profile sandbox for arbitrary JavaScript: pages still run with Chrome's ordinary same-origin rules and the profile's shared cookies and storage. Native-host and relay authentication remain separate from visual grouping.

## Browser and worker lifetime

Live tab/group IDs and ownership use `chrome.storage.session`, which survives extension service-worker suspension within the browser lifetime. Old `storage.local` IDs are never restored as authority after a browser restart, when Chrome may reuse identifiers. A restarted browser therefore requires fresh claims for previously open tabs. No session gains ownership merely because a restored group has the same title.

A similarly named group restored from an earlier browser lifetime can remain until its tabs are explicitly claimed. Godspeed does not seize those tabs or merge a user's group based on its title. The single-workspace rule applies to the tabs whose ownership is established in the current browser lifetime.

Creation receipts are saved before Chrome receives a creation request. A caller timeout keeps tracking a late reply, and unresolved creation defers finalization so cleanup cannot silently orphan the new tab. If a worker crashes before the creation result can be recovered, the uncertainty remains visible and cleanup stays deferred. Inspect the open tabs before starting a fresh browser session; do not automatically repeat the creation request.

Chrome groups are per-window and cannot contain pinned tabs. A pinned owned tab stays pinned. Godspeed does not activate another tab to force a collapse, move a user tab into another window, or keep retrying while the browser refuses changes. A transient layout change during dragging settles after Chrome accepts group edits again.

## Build and prepare

The reviewed source is [iFurySt/open-browser-use](https://github.com/iFurySt/open-browser-use/tree/97ca258065fc285991c46a65007d823de2996fd9), MIT licensed. `upstream.json` pins the commit, version, background digest and stable public extension key. The public key identifies the unpacked extension; it is not a relay signing key and no private key is included.

```sh
python3 scripts/package-godspeed-browser.py --fetch
# Or read Git objects from an existing checkout containing the pinned commit:
python3 scripts/package-godspeed-browser.py --source /absolute/path/to/open-browser-use
```

The builder reads committed source, applies `background.patch`, adds `godspeed-workspace.mjs`, checks JavaScript syntax, and creates a reproducible ZIP with file hashes and the upstream license. It runs no upstream build or install scripts. A failed build does not replace a previous artifact. Native-host and relay-grant authentication remain in the existing helper; the extension adds no permissions to the pinned manifest.

Prepare the ZIP with the existing compatible CLI:

```sh
OPEN_COMPUTER_USE_OBU_BIN=/absolute/path/to/obu \
  bash scripts/setup-godspeed-chrome.sh --workspace-zip \
  "$PWD/dist/chrome-workspace/Godspeed-Chrome-Workspace-1.1.0.1.zip" --no-open
```

The helper prints the local installation path and Chrome approval steps. Approve the workspace extension in the intended profile, keep a single connected extension for that helper/profile, then run the setup script with `--check` and reconnect the MCP client. Preparing a package does not grant Chrome approval. Use the [installation guide](../../docs/INSTALL.md#godspeed-browser-workspace) for details.

## Verification

Portable tests cover the workspace state machine and the actual patched `background.js` against a fake Chrome implementation. Set `GODSPEED_CHROME_WORKSPACE_DIR` to the extracted extension root for backend integration tests. Package tests verify committed-source selection, permission preservation, reproducible bytes, path restrictions and failed-build behavior. Setup tests use an inert helper and do not install anything.

```sh
python3 -I -m unittest discover -s scripts/tests -p 'test_godspeed_browser_package.py'
python3 -I -m unittest discover -s scripts/tests -p 'test_godspeed_chrome_setup.py'
GODSPEED_CHROME_WORKSPACE_DIR=/absolute/path/to/extracted-extension \
  node --test integrations/chrome-workspace/test/*.test.mjs
```

Before replacing a daily-use extension, verify this build in a disposable Chrome profile on macOS: open tabs from two sessions, move the group and an owned tab, pin/unpin one, expand/collapse it manually, finalize each session with a retained result, suspend/restart the worker, and restart Chrome. Confirm that the intended group position returns, manual expansion remains visible, other sessions and user tabs stay untouched, and a new browser lifetime requires fresh ownership. Fake-Chrome tests cannot prove actual Chrome event ordering, native-host compatibility, or behavior during a live drag.
