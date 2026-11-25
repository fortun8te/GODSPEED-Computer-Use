import test from "node:test";
import assert from "node:assert/strict";
import { access, readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { fakeChrome } from "./fake-chrome.mjs";

const directory = process.env.GODSPEED_CHROME_WORKSPACE_DIR;
const entry = directory && resolve(directory, "background.js");
if (directory) {
  // A supplied integration build must work. Missing/wrong source is a failure, never a skip.
  await access(entry);
  await access(resolve(directory, "godspeed-workspace.mjs"));
  assert.match(await readFile(entry, "utf8"), /new GodspeedWorkspace/);
}
let instance = 0;
const request = (session_id, extra = {}) => ({ session_id, turn_id: "integration-turn", ...extra });

async function backendHarness(t, options = {}) {
  const fake = fakeChrome({ tabs: [{ id: 1, active: true, pinned: true }, { id: 2 }, { id: 3 }], ...options });
  const previous = globalThis.chrome;
  globalThis.chrome = fake.chrome;
  const imported = await import(`${pathToFileURL(entry).href}?integration=${++instance}`);
  const backend = imported.backend;
  await backend.store.ready;
  await backend.webMcpGate.ready;
  t.after(async () => {
    backend.workspace.dispose();
    await backend.workspace.queue;
    await backend.store.saveQueue;
    globalThis.chrome = previous;
  });
  return { ...fake, backend, imported };
}

test("packaged patched backend", { skip: !directory && "Set GODSPEED_CHROME_WORKSPACE_DIR to the unpacked build" }, async (t) => {
  await t.test("two sessions share presentation while read/claim/finalize stay isolated", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    const b = await h.backend.createTab(request("b"));
    await h.backend.workspace.reconcileNow();
    assert.equal(h.tabs.get(a.id).groupId, h.tabs.get(b.id).groupId);
    assert.equal(h.groups.size, 1);
    assert.equal(h.tabs.get(1).active, true);
    assert.equal(h.tabs.get(a.id).active, false);
    assert.equal(h.tabs.get(b.id).active, false);
    assert.deepEqual((await h.backend.getTabs(request("a"))).map((tab) => tab.id), [a.id]);
    assert.deepEqual((await h.backend.getTabs(request("b"))).map((tab) => tab.id), [b.id]);
    await assert.rejects(h.backend.claimUserTab(request("a", { tabId: b.id })), /already part/);
    await assert.rejects(h.backend.finalizeTabs(request("a", { keep: [{ tabId: b.id, status: "deliverable" }] })), /unknown tab/);
    await h.backend.finalizeTabs(request("a", { keep: [{ tabId: a.id, status: "deliverable" }] }));
    await h.backend.finalizeTabs(request("b", { keep: [] }));
    await h.backend.workspace.reconcileNow();
    assert.equal(h.tabs.has(a.id), true);
    assert.equal(h.tabs.has(b.id), false);
    await assert.rejects(h.backend.claimUserTab(request("b", { tabId: a.id })), /already part/);
    assert.deepEqual(await h.backend.getTabs(request("a")), []);
    assert.deepEqual(await h.backend.getTabs(request("b")), []);
    assert.equal(h.calls.some((call) => call.name === "tabs.update"), false);
  });

  await t.test("group removal never grants authority or erases ownership", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    const groupId = h.tabs.get(a.id).groupId;
    await h.chrome.tabs.group({ groupId, tabIds: [2] });
    assert.deepEqual((await h.backend.getTabs(request("a"))).map((tab) => tab.id), [a.id]);
    await h.chrome.tabs.ungroup(a.id);
    await assert.rejects(h.backend.claimUserTab(request("b", { tabId: a.id })), /already part/);
    await h.backend.workspace.reconcileNow();
    await h.backend.finalizeTabs(request("a", { keep: [] }));
    assert.equal(h.tabs.has(2), true);
    assert.equal(h.tabs.has(1), true);
    assert.equal(h.tabs.has(a.id), false);
  });

  await t.test("SDK tabId CDP shapes work while cross-session targetId routes are refused", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    const b = await h.backend.createTab(request("b"));
    await h.backend.attach(request("a", { tabId: a.id }));
    await h.backend.attach(request("b", { tabId: b.id }));
    for (const method of ["Accessibility.enable", "Accessibility.getFullAXTree", "Accessibility.getPartialAXTree", "Accessibility.queryAXTree",
      "DOM.describeNode", "DOM.focus", "DOM.getBoxModel", "DOM.getDocument", "DOM.getNodeForLocation", "DOM.resolveNode", "DOM.scrollIntoViewIfNeeded", "DOM.setFileInputFiles",
      "Emulation.setFocusEmulationEnabled", "Emulation.setPageScaleFactor", "Input.dispatchKeyEvent", "Input.dispatchMouseEvent", "Input.insertText",
      "Page.addScriptToEvaluateOnNewDocument", "Page.captureScreenshot", "Page.close", "Page.createIsolatedWorld", "Page.enable", "Page.getFrameTree",
      "Page.getNavigationHistory", "Page.navigate", "Page.navigateToHistoryEntry", "Page.reload", "Page.setInterceptFileChooserDialog",
      "Runtime.callFunctionOn", "Runtime.evaluate", "Runtime.releaseObject", "Runtime.releaseObjectGroup"]) {
      assert.deepEqual(await h.backend.executeCdp(request("a", { target: { tabId: a.id }, method, commandParams: {} })), { ok: true });
    }
    assert.deepEqual(await h.backend.executeCdp(request("a", {
      target: { targetId: `target-${a.id}` }, method: "Runtime.evaluate", commandParams: {}
    })), { ok: true });
    await assert.rejects(h.backend.executeCdp(request("a", {
      target: { targetId: `target-${b.id}` }, method: "Runtime.evaluate"
    })), /not part/);
    for (const method of ["Target.closeTarget", "Target.activateTarget", "Target.attachToTarget", "Target.sendMessageToTarget"]) {
      await assert.rejects(h.backend.executeCdp(request("a", {
        target: { tabId: a.id }, method, commandParams: { targetId: `target-${b.id}` }
      })), /not part|cross-target/);
    }
    await assert.rejects(h.backend.executeCdp(request("a", { target: {}, method: "Runtime.evaluate" })), /owned tab/);
    const listed = await h.backend.executeCdp(request("a", { target: {}, method: "Target.getTargets" }));
    assert.deepEqual(listed.targetInfos.map((target) => target.tabId), [a.id]);
  });

  await t.test("CDP alternate routes and nested/global Target commands fail before forwarding", async (t) => {
    const h = await backendHarness(t);
    await h.backend.claimUserTab(request("a", { tabId: 2 }));
    await h.backend.claimUserTab(request("b", { tabId: 3 }));
    await h.backend.attach(request("a", { tabId: 2 }));
    const cases = [
      { target: { tabId: 2, targetId: "target-3" }, method: "Runtime.evaluate" },
      { target: { tabId: 2, extensionId: "foreign-extension" }, method: "Runtime.evaluate" },
      { target: { tabId: 2, sessionId: "foreign-debugger-session" }, method: "Runtime.evaluate" },
      { target: { tabId: 2 }, method: "Target.getTargetInfo", commandParams: { targetId: "target-3" } },
      { target: { tabId: 2 }, method: "Target.autoAttachRelated", commandParams: { targetId: "target-3", waitForDebuggerOnStart: false } },
      { target: { tabId: 2 }, method: "Target.exposeDevToolsProtocol", commandParams: { targetId: "target-3" } },
      { target: { tabId: 2 }, method: "Target.sendMessageToTarget", commandParams: { targetId: "target-2",
        message: JSON.stringify({ id: 1, method: "Target.closeTarget", params: { targetId: "target-3" } }) } },
      { target: { tabId: 2 }, method: "Browser.close" },
      { target: { tabId: 2 }, method: "Target.createTarget", commandParams: { url: "about:blank", browserContextId: "foreign" } },
      { target: { tabId: 2 }, method: "Target.createTarget", commandParams: { url: "about:blank", newWindow: true } },
      { target: { tabId: 2 }, method: "Target.setDiscoverTargets", commandParams: { discover: true } }
    ];
    for (const payload of cases) {
      const sent = h.calls.filter((call) => call.name === "debugger.sendCommand").length;
      await assert.rejects(h.backend.executeCdp(request("a", payload)));
      assert.equal(h.calls.filter((call) => call.name === "debugger.sendCommand").length, sent, JSON.stringify(payload));
    }
    await h.backend.executeCdp(request("a", { target: { targetId: "target-2" }, method: "Runtime.evaluate" }));
    assert.deepEqual(h.calls.filter((call) => call.name === "debugger.sendCommand").at(-1).args.target, { tabId: 2 });
  });

  await t.test("native port exposes only the public protocol, not internal or prototype methods", async (t) => {
    const h = await backendHarness(t);
    await h.backend.claimUserTab(request("b", { tabId: 3 }));
    await h.backend.attach(request("b", { tabId: 3 }));
    let identifier = 0;
    async function rpc(method, params) {
      const id = ++identifier;
      h.nativePort.onMessage.emit({ jsonrpc: "2.0", id, method, params });
      for (let retry = 0; retry < 50; retry++) {
        const response = h.nativePort.messages.find((message) => message.id === id);
        if (response) return response;
        await new Promise((resolve) => setTimeout(resolve, 2));
      }
      assert.fail(`No native response for ${method}`);
    }
    for (const [method, params] of [["detachTab", 3], ["detachMany", [3]], ["getSessionTabs", "b"],
      ["setSessionActiveTab", "b"], ["constructor", {}], ["toString", {}]]) {
      const before = h.calls.filter((call) => call.name === "debugger.detach").length;
      const response = await rpc(method, params);
      assert.match(response.error?.message ?? "", /public handler/);
      assert.equal(h.calls.filter((call) => call.name === "debugger.detach").length, before);
    }
    assert.equal((await rpc("ping", {})).result, "pong");
    assert.deepEqual((await rpc("getTabs", request("b"))).result.map((tab) => tab.id), [3]);
  });

  await t.test("an exact created CDP target is grouped without activating it; opener is insufficient", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    await h.backend.attach(request("a", { tabId: a.id }));
    const created = await h.backend.executeCdp(request("a", {
      target: { tabId: a.id }, method: "Target.createTarget", commandParams: { url: "https://example.test/result", background: false }
    }));
    const newId = Number(created.targetId.replace("target-", ""));
    assert.equal(h.tabs.get(newId).groupId, h.tabs.get(a.id).groupId);
    assert.equal(h.tabs.get(newId).active, false);
    assert.equal(h.tabs.get(1).active, true);
    const popup = await h.chrome.tabs.create({ windowId: 1, openerTabId: a.id, active: false, url: "https://example.test/user-popup" });
    await h.backend.workspace.reconcileNow();
    assert.equal(h.tabs.get(popup.id).groupId, -1);
    const owned = (await h.backend.getTabs(request("a"))).map((tab) => tab.id);
    assert.deepEqual(new Set(owned), new Set([a.id, newId]));
    assert.equal(owned.includes(popup.id), false);
  });

  await t.test("handoff and worker restart retain scope while a full browser restart ignores stale local IDs", async (t) => {
    const h = await backendHarness(t, { local: { OPEN_BROWSER_USE_SESSION_STATE: {
      sessions: { stale: { chromeGroupId: 99, tabOrigins: { 2: "agent" } } }
    } } });
    assert.deepEqual(await h.backend.getTabs(request("stale")), []);
    await h.backend.claimUserTab(request("a", { tabId: 2 }));
    await h.backend.finalizeTabs(request("a", { keep: [{ tabId: 2, status: "handoff" }] }));
    h.backend.workspace.dispose();
    await h.backend.workspace.queue;
    await h.backend.store.saveQueue;
    const restarted = new h.imported.BrowserBackend();
    t.after(async () => { restarted.workspace.dispose(); await restarted.workspace.queue; });
    await restarted.store.ready;
    assert.deepEqual((await restarted.getTabs(request("a"))).map((tab) => tab.id), [2]);
    assert.deepEqual(await restarted.getTabs(request("b")), []);
    await restarted.finalizeTabs(request("a", { keep: [] }));
    assert.equal(h.tabs.has(2), true, "A handed-off user tab keeps its user origin across worker restart.");
  });

  await t.test("failed cleanup preserves unclosed ownership for a safe retry", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    h.fail("tabs.remove", 1, "Chrome is temporarily busy");
    await assert.rejects(h.backend.finalizeTabs(request("a", { keep: [] })), /temporarily busy/);
    assert.equal(h.tabs.has(a.id), true);
    assert.deepEqual((await h.backend.getTabs(request("a"))).map((tab) => tab.id), [a.id]);
    await assert.rejects(h.backend.claimUserTab(request("b", { tabId: a.id })), /already part/);
    await h.backend.finalizeTabs(request("a", { keep: [] }));
    assert.equal(h.tabs.has(a.id), false);
  });

  await t.test("explicit user reclaim promotes a retained result so cleanup cannot delete it", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    await h.backend.finalizeTabs(request("a", { keep: [{ tabId: a.id, status: "deliverable" }] }));
    await h.backend.claimUserTab(request("a", { tabId: a.id }));
    await h.backend.finalizeTabs(request("a", { keep: [] }));
    assert.equal(h.tabs.has(a.id), true);
    assert.equal(h.tabs.get(a.id).groupId, -1);
  });

  await t.test("concurrent finalization defers while a CDP create reply is in flight", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    await h.backend.attach(request("a", { tabId: a.id }));
    let finishCreation;
    h.command(async (_target, method, params) => {
      assert.equal(method, "Target.createTarget");
      return await new Promise((resolve) => {
        finishCreation = async () => {
          const tab = await h.chrome.tabs.create({ windowId: 1, active: !params.background, url: params.url });
          resolve({ targetId: `target-${tab.id}` });
        };
      });
    });
    const creating = h.backend.executeCdp(request("a", { target: { tabId: a.id }, method: "Target.createTarget", commandParams: { url: "about:blank" } }));
    for (let attempt = 0; !finishCreation && attempt < 50; attempt++) await new Promise((resolve) => setTimeout(resolve, 2));
    assert.equal(typeof finishCreation, "function");
    await assert.rejects(h.backend.finalizeTabs(request("a", { keep: [] })), /Finalization deferred/);
    assert.equal(h.tabs.has(a.id), true);
    await finishCreation();
    const created = await creating;
    const createdId = Number(created.targetId.replace("target-", ""));
    assert.ok((await h.backend.getTabs(request("a"))).some((tab) => tab.id === createdId));
    await h.backend.finalizeTabs(request("a", { keep: [{ tabId: createdId, status: "deliverable" }] }));
    assert.equal(h.tabs.has(a.id), false);
    assert.equal(h.tabs.has(createdId), true);
  });

  await t.test("a caller timeout keeps tracking a late creation reply instead of orphaning its tab", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    await h.backend.attach(request("a", { tabId: a.id }));
    let finishCreation;
    h.command(async () => await new Promise((resolve) => {
      finishCreation = async () => {
        const tab = await h.chrome.tabs.create({ windowId: 1, active: false, url: "about:blank" });
        resolve({ targetId: `target-${tab.id}` });
        return tab.id;
      };
    }));
    await assert.rejects(h.backend.executeCdp(request("a", {
      target: { tabId: a.id }, method: "Target.createTarget", commandParams: { url: "about:blank" }, timeoutMs: 5
    })), /Timed out/);
    await assert.rejects(h.backend.finalizeTabs(request("a", { keep: [] })), /Finalization deferred/);
    const createdId = await finishCreation();
    for (let attempt = 0; Object.keys(h.backend.store.state.workspace.creations).length && attempt < 50; attempt++) {
      await new Promise((resolve) => setTimeout(resolve, 2));
    }
    await h.backend.workspace.queue;
    assert.ok((await h.backend.getTabs(request("a"))).some((tab) => tab.id === createdId));
    await h.backend.finalizeTabs(request("a", { keep: [{ tabId: createdId, status: "deliverable" }] }));
    assert.equal(h.tabs.has(createdId), true);
  });

  await t.test("failed retained-result persistence stays dirty until repair and survives worker restart", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    await h.backend.workspace.queue;
    const original = h.chrome.storage.session.set;
    let failWrites = true;
    let attempts = 0;
    h.chrome.storage.session.set = async (update) => {
      const state = update.GODSPEED_BROWSER_WORKSPACE_STATE_V1;
      if (failWrites && state?.workspace.retained[String(a.id)]) {
        attempts++;
        throw new Error("Session storage is temporarily unavailable");
      }
      await original(update);
    };
    await assert.rejects(h.backend.finalizeTabs(request("a", { keep: [{ tabId: a.id, status: "deliverable" }] })), /storage/);
    assert.equal(h.backend.store.hasUnsavedState, true);
    await new Promise((resolve) => setTimeout(resolve, 1050));
    assert.equal(attempts, 4, "Persistence repair must stop after the bounded local retries.");
    assert.equal(h.backend.store.hasUnsavedState, true);
    assert.match(h.backend.workspace.lastError, /storage/);
    failWrites = false;
    await h.backend.workspace.reconcileNow();
    await h.backend.workspace.queue;
    assert.equal(h.backend.store.hasUnsavedState, false);
    assert.equal(h.backend.workspace.lastError, null);
    assert.ok(h.session.GODSPEED_BROWSER_WORKSPACE_STATE_V1.workspace.retained[String(a.id)]);
    h.backend.workspace.dispose();
    const restarted = new h.imported.BrowserBackend();
    try {
      await restarted.store.ready;
      assert.deepEqual(await restarted.getTabs(request("a")), []);
      await assert.rejects(restarted.claimUserTab(request("b", { tabId: a.id })), /already part/);
      await restarted.finalizeTabs(request("a", { keep: [] }));
      assert.equal(h.tabs.has(a.id), true, "A repaired retained result must not reappear as disposable after restart.");
    } finally { restarted.workspace.dispose(); await restarted.workspace.queue; await restarted.store.saveQueue; }
  });

  await t.test("an older failed save cannot overwrite a newer successful ownership snapshot", async (t) => {
    const h = await backendHarness(t);
    const a = await h.backend.createTab(request("a"));
    await h.backend.workspace.queue;
    h.fail("storage.session.set", 1, "First snapshot failed");
    const first = h.backend.store.save();
    h.backend.store.state.sessions.a.title = "Newer snapshot";
    h.backend.store.state.sessions.a.tabOrigins[String(a.id)] = "user";
    const newer = h.backend.store.save();
    const outcomes = await Promise.allSettled([first, newer]);
    assert.equal(outcomes[0].status, "rejected");
    assert.equal(outcomes[1].status, "fulfilled");
    assert.equal(h.backend.store.hasUnsavedState, false);
    const saved = h.session.GODSPEED_BROWSER_WORKSPACE_STATE_V1.sessions.a;
    assert.equal(saved.title, "Newer snapshot");
    assert.equal(saved.tabOrigins[String(a.id)], "user");
    await h.backend.workspace.reconcileNow();
    assert.equal(h.backend.workspace.lastError, null);
  });
});
