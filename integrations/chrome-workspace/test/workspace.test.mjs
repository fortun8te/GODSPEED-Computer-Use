import test from "node:test";
import assert from "node:assert/strict";
import { GodspeedWorkspace, freshWorkspaceState, loadWorkspaceState, saveWorkspaceState,
  findTabOwner, WORKSPACE_STATE_KEY } from "../godspeed-workspace.mjs";
import { fakeChrome } from "./fake-chrome.mjs";

async function harness(options = {}) {
  const fake = fakeChrome(options);
  const store = {
    state: freshWorkspaceState(),
    async save() { await saveWorkspaceState(fake.chrome, this.state); },
    async getSession(sessionId) {
      await this.ready;
      if (!Object.hasOwn(this.state.sessions, sessionId)) {
        this.state.sessions[sessionId] = { title: "Task", activeTabId: null, tabOrigins: Object.create(null) };
        await this.save();
      }
      return this.state.sessions[sessionId];
    }
  };
  store.ready = loadWorkspaceState(fake.chrome).then((state) => { store.state = state; });
  const workspace = new GodspeedWorkspace({ chrome: fake.chrome, store });
  await workspace.ready;
  return { ...fake, store, workspace };
}

const seed = () => [{ id: 1, active: true, pinned: true }, { id: 2, active: false }, { id: 3, active: false }];
const mutations = (calls) => calls.filter((call) => ["tabs.group", "tabs.ungroup", "tabs.remove", "tabs.update", "tabGroups.update", "tabGroups.move"].includes(call.name));

test("browser-lifetime storage ignores local tab IDs and preserves worker identity", async () => {
  const fake = fakeChrome({ local: { OPEN_BROWSER_USE_SESSION_STATE: {
    sessions: { stale: { chromeGroupId: 77, tabOrigins: { 3: "agent" } } }
  } } });
  const fresh = await loadWorkspaceState(fake.chrome);
  assert.equal(Object.keys(fresh.sessions).length, 0);
  fresh.sessions.current = { title: "Task", activeTabId: 3, tabOrigins: { 3: "user" } };
  await saveWorkspaceState(fake.chrome, fresh);
  const workerRestart = await loadWorkspaceState(fake.chrome);
  assert.equal(workerRestart.browserEpoch, fresh.browserEpoch);
  assert.deepEqual(findTabOwner(workerRestart, 3), { sessionId: "current", origin: "user", retained: false });
  const browserRestart = await loadWorkspaceState(fakeChrome({ local: fake.local }).chrome);
  assert.notEqual(browserRestart.browserEpoch, fresh.browserEpoch);
  assert.equal(findTabOwner(browserRestart, 3), null);
});

test("ambiguous persisted ownership fails closed and prototype-like session names stay ordinary", async () => {
  const state = freshWorkspaceState();
  state.sessions.a = { tabOrigins: { 8: "agent" } };
  state.sessions.b = { tabOrigins: { 8: "user" } };
  state.sessions.__proto__ = { tabOrigins: { 9: "user" } };
  const loaded = await loadWorkspaceState(fakeChrome({ session: { [WORKSPACE_STATE_KEY]: state } }).chrome);
  assert.equal(findTabOwner(loaded, 8), null);
  assert.equal(findTabOwner(loaded, 9)?.sessionId, "__proto__");
  assert.equal(Object.getPrototypeOf(loaded.sessions), null);
});

test("one quiet purple group is leftmost after pinned tabs and repeated repair is idempotent", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  await h.workspace.claim("b", 3, "agent");
  await h.workspace.reconcileNow();
  const group = [...h.groups.values()][0];
  assert.equal(h.groups.size, 1);
  assert.equal(group.title, "Godspeed");
  assert.equal(group.color, "purple");
  assert.equal(group.collapsed, true);
  assert.equal(h.tabs.get(2).index, 1);
  assert.equal(h.tabs.get(1).pinned, true);
  assert.equal(h.tabs.get(1).active, true);
  const before = mutations(h.calls).length;
  await h.workspace.reconcileNow();
  await h.workspace.reconcileNow();
  assert.equal(mutations(h.calls).length, before);
  assert.equal(h.calls.some((call) => call.name === "tabs.update" || call.name === "windows.create"), false);
  assert.deepEqual((await h.workspace.ownedTabs("a")).map((tab) => tab.id), [2]);
  assert.deepEqual((await h.workspace.ownedTabs("b")).map((tab) => tab.id), [3]);
});

test("concurrent claims cannot steal a tab from another session", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  const results = await Promise.allSettled([h.workspace.claim("a", 2, "agent"), h.workspace.claim("b", 2, "user")]);
  assert.equal(results.filter((result) => result.status === "fulfilled").length, 1);
  assert.equal(results.filter((result) => result.status === "rejected").length, 1);
  assert.equal(findTabOwner(h.store.state, 2).sessionId, "a");
});

test("manual expansion survives later actions and a service-worker restart", async (t) => {
  const h = await harness({ tabs: seed() });
  await h.workspace.claim("a", 2, "agent");
  await h.workspace.reconcileNow();
  const group = [...h.groups.values()][0];
  await h.chrome.tabGroups.update(group.id, { collapsed: false });
  await h.workspace.claim("b", 3, "agent");
  await h.workspace.reconcileNow();
  await h.workspace.queue;
  assert.equal(group.collapsed, false);
  h.workspace.dispose();
  const restarted = await harness({ tabs: [...h.tabs.values()], groups: [...h.groups.values()], session: h.session });
  t.after(() => restarted.workspace.dispose());
  await restarted.workspace.reconcileNow();
  assert.equal(restarted.groups.get(group.id).collapsed, false);
});

test("an active user tab is never switched or closed to collapse its workspace", async (t) => {
  const h = await harness({ tabs: [{ id: 1, active: true }, { id: 2 }] });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 1, "user");
  await h.workspace.reconcileNow();
  assert.equal([...h.groups.values()][0].collapsed, false);
  assert.equal(h.tabs.get(1).active, true);
  assert.equal(h.calls.some((call) => call.name === "tabs.update" || call.name === "tabs.remove"), false);
});

test("activating an already-expanded workspace persists the preference without a group update", async (t) => {
  const h = await harness({ tabs: [{ id: 1, active: true }, { id: 2 }] });
  await h.workspace.claim("a", 1, "user");
  await h.workspace.reconcileNow();
  const group = [...h.groups.values()][0];
  assert.equal(group.collapsed, false);
  h.activate(1);
  await h.workspace.queue;
  h.activate(2);
  await h.workspace.queue;
  h.workspace.dispose();
  const restarted = await harness({ tabs: [...h.tabs.values()], groups: [...h.groups.values()], session: h.session });
  t.after(() => restarted.workspace.dispose());
  await restarted.workspace.reconcileNow();
  assert.equal(restarted.groups.get(group.id).collapsed, false);
});

test("pinned claimed tabs stay pinned and normal windows get separate groups", async (t) => {
  const h = await harness({ tabs: [...seed(), { id: 4, windowId: 2, index: 0 }, { id: 5, windowId: 3, index: 0 }],
    windows: [{ id: 1, type: "normal" }, { id: 2, type: "normal" }, { id: 3, type: "popup" }] });
  t.after(() => h.workspace.dispose());
  for (const tabId of [1, 2, 4, 5]) await h.workspace.claim("a", tabId, "user");
  await h.workspace.reconcileNow();
  assert.equal(h.groups.size, 2);
  assert.notEqual(h.tabs.get(2).groupId, h.tabs.get(4).groupId);
  assert.equal(h.tabs.get(1).pinned, true);
  assert.equal(h.tabs.get(1).groupId, -1);
  assert.equal(h.tabs.get(5).groupId, -1);
  h.moveTabToWindow(2, 2);
  await h.workspace.reconcileNow();
  assert.equal(h.tabs.get(2).groupId, h.tabs.get(4).groupId);
  assert.equal(findTabOwner(h.store.state, 2).sessionId, "a");
});

test("drag-lock failures retry locally a finite number of times then recover on a new event", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  h.fail("tabs.group", 20);
  await assert.rejects(h.workspace.reconcileNow(), /dragging/);
  await new Promise((resolve) => setTimeout(resolve, 1050));
  assert.equal(h.calls.filter((call) => call.name === "tabs.group").length, 4);
  assert.equal(findTabOwner(h.store.state, 2).sessionId, "a");
  assert.match(h.workspace.lastError, /dragging/);
  h.fail("tabs.group", 0);
  h.chrome.tabs.onMoved.emit(2, { windowId: 1, toIndex: 1 });
  await h.workspace.reconcileNow();
  assert.equal(h.groups.size, 1);
  assert.equal(h.workspace.lastError, null);
});

test("deliverables remain visible in the workspace without becoming another session's tabs", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  await h.workspace.claim("b", 3, "agent");
  await h.workspace.reconcileNow();
  const groupId = h.tabs.get(2).groupId;
  await assert.rejects(h.workspace.finalize("a", [{ tabId: 3, status: "deliverable" }], async () => {}), /unknown tab/);
  await h.workspace.finalize("a", [{ tabId: 2, status: "deliverable" }], async () => {});
  await h.workspace.reconcileNow();
  assert.equal(h.tabs.get(2).groupId, groupId);
  assert.equal(h.tabs.get(3).groupId, groupId);
  assert.deepEqual((await h.workspace.ownedTabs("b")).map((tab) => tab.id), [3]);
  assert.deepEqual((await h.workspace.ownedTabs("a")).map((tab) => tab.id), []);
  await assert.rejects(h.workspace.claim("b", 2, "user"), /already part/);
  await h.workspace.finalize("b", [], async () => {});
  assert.equal(h.tabs.has(2), true);
  assert.equal(h.tabs.has(3), false);
});

test("reclaimed user-origin tabs and unowned neighbors are never disposed as agent tabs", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "user");
  await h.workspace.claim("a", 2, "agent");
  await h.workspace.reconcileNow();
  const groupId = h.tabs.get(2).groupId;
  await h.chrome.tabs.group({ groupId, tabIds: [3] });
  await h.workspace.finalize("a", [], async () => {});
  assert.equal(h.tabs.has(2), true);
  assert.equal(h.tabs.get(2).groupId, -1);
  assert.equal(h.tabs.has(3), true);
  assert.equal(findTabOwner(h.store.state, 3), null);
  assert.equal(h.calls.some((call) => call.name === "tabs.remove"), false);
});

test("opener-only popups are unowned; exact returned target proof can adopt a created tab", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  const popup = await h.chrome.tabs.create({ openerTabId: 2, windowId: 1, active: false, url: "https://example.test/popup" });
  await h.workspace.reconcileNow();
  assert.equal(findTabOwner(h.store.state, popup.id), null);
  assert.equal(h.tabs.get(popup.id).groupId, -1);
  await h.workspace.adoptCreatedTarget("a", `target-${popup.id}`);
  assert.equal(findTabOwner(h.store.state, popup.id).sessionId, "a");
  assert.equal(h.tabs.get(popup.id).groupId, h.tabs.get(2).groupId);
});

test("delayed exact target proof retries locally without any later browser event", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  const popup = await h.chrome.tabs.create({ openerTabId: 2, windowId: 1, active: false });
  const original = h.chrome.debugger.getTargets;
  let lookups = 0;
  h.chrome.debugger.getTargets = async () => {
    lookups++;
    const targets = await original();
    return lookups < 3 ? targets.filter((entry) => entry.tabId !== popup.id) : targets;
  };
  await h.workspace.adoptCreatedTarget("a", `target-${popup.id}`);
  assert.equal(findTabOwner(h.store.state, popup.id), null);
  await new Promise((resolve) => setTimeout(resolve, 650));
  assert.equal(findTabOwner(h.store.state, popup.id)?.sessionId, "a");
  assert.equal(h.tabs.get(popup.id).groupId, h.tabs.get(2).groupId);
  assert.equal(Object.keys(h.store.state.workspace.pendingTargets).length, 0);
});

test("finalization preserves unresolved creation proof, including expiry, until an exact mapping arrives", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  const popup = await h.chrome.tabs.create({ windowId: 1, active: false });
  const original = h.chrome.debugger.getTargets;
  h.chrome.debugger.getTargets = async () => (await original()).filter((target) => target.tabId !== popup.id);
  const targetId = `target-${popup.id}`;
  await h.workspace.adoptCreatedTarget("a", targetId);
  h.store.state.workspace.pendingTargets[targetId].expires = Date.now() - 1;
  await assert.rejects(h.workspace.finalize("a", [], async () => {}), /Finalization deferred/);
  assert.equal(h.tabs.has(2), true);
  assert.equal(h.tabs.has(popup.id), true);
  assert.ok(h.store.state.sessions.a);
  assert.ok(h.store.state.workspace.pendingTargets[targetId]);
  await h.store.save();
  const loaded = await loadWorkspaceState(h.chrome);
  assert.equal(loaded.workspace.pendingTargets[targetId].unresolved, true, "Worker restart must not turn expired proof into successful cleanup.");
  h.chrome.debugger.getTargets = original;
  await h.workspace.reconcileNow();
  assert.equal(findTabOwner(h.store.state, popup.id)?.sessionId, "a");
  await h.workspace.finalize("a", [{ tabId: popup.id, status: "deliverable" }], async () => {});
  assert.equal(h.tabs.has(2), false);
  assert.equal(h.tabs.has(popup.id), true);
});

test("creation receipts defer cleanup and survive worker restart as uncertain outcomes", async (t) => {
  const h = await harness({ tabs: seed() });
  t.after(() => h.workspace.dispose());
  await h.workspace.claim("a", 2, "agent");
  const receipt = await h.workspace.beginCreation("a");
  await assert.rejects(h.workspace.finalize("a", [], async () => {}), /Finalization deferred/);
  const loaded = await loadWorkspaceState(h.chrome);
  assert.equal(loaded.workspace.creations[receipt].status, "uncertain");
  await h.workspace.creationFailed(receipt, false);
  await h.workspace.finalize("a", [], async () => {});
  assert.equal(h.tabs.has(2), false);
});
