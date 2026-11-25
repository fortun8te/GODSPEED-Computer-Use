// Godspeed's presentation layer for the pinned Open Browser Use extension.
// A group is a visual workspace, never a tab-ownership or authorization boundary.
export const WORKSPACE_STATE_KEY = "GODSPEED_BROWSER_WORKSPACE_STATE_V1";
export const WORKSPACE_TITLE = "Godspeed";
export const WORKSPACE_COLOR = "purple";
const RETRY_DELAYS = [80, 200, 500];
const id = (value) => Number.isSafeInteger(value) && value >= 0;
const dictionary = () => Object.create(null);
const record = (value) => value !== null && typeof value === "object" && !Array.isArray(value);
const origin = (value) => value === "agent" || value === "user";

export function freshWorkspaceState() {
  return {
    version: 1, browserEpoch: crypto.randomUUID(), sessions: dictionary(),
    workspace: { groups: dictionary(), retained: dictionary(), pendingTargets: dictionary(), creations: dictionary() }, deliverableGroupId: null
  };
}

export async function loadWorkspaceState(chrome) {
  if (!chrome.storage?.session) throw new Error("Godspeed workspace requires Chrome session storage.");
  const stored = (await chrome.storage.session.get(WORKSPACE_STATE_KEY))[WORKSPACE_STATE_KEY];
  const state = freshWorkspaceState();
  // Never recover live tab/group IDs from storage.local: Chrome may reuse them after a
  // browser restart. Session storage survives worker suspension, but not a new browser.
  if (!record(stored) || stored.version !== 1 || typeof stored.browserEpoch !== "string") return state;
  state.browserEpoch = stored.browserEpoch;
  const owners = new Map();
  const ambiguous = new Set();
  for (const [sessionId, value] of Object.entries(record(stored.sessions) ? stored.sessions : {})) {
    if (!sessionId || !record(value)) continue;
    const tabOrigins = dictionary();
    for (const [key, source] of Object.entries(record(value.tabOrigins) ? value.tabOrigins : {})) {
      const tabId = Number(key);
      if (!id(tabId) || String(tabId) !== key || !origin(source)) continue;
      if (owners.has(tabId) || ambiguous.has(tabId)) {
        const previous = owners.get(tabId);
        if (previous) delete previous[key];
        ambiguous.add(tabId);
        continue;
      }
      tabOrigins[key] = source;
      owners.set(tabId, tabOrigins);
    }
    state.sessions[sessionId] = {
      chromeGroupId: null,
      title: typeof value.title === "string" ? value.title.slice(0, 120) : WORKSPACE_TITLE,
      activeTabId: id(value.activeTabId) && Object.hasOwn(tabOrigins, value.activeTabId) ? value.activeTabId : null,
      tabOrigins
    };
  }
  for (const [key, value] of Object.entries(record(stored.workspace?.retained) ? stored.workspace.retained : {})) {
    const tabId = Number(key);
    if (!id(tabId) || String(tabId) !== key || !record(value) || !origin(value.origin)
        || typeof value.ownerSessionId !== "string" || !value.ownerSessionId || ambiguous.has(tabId)) continue;
    if (owners.has(tabId)) { delete owners.get(tabId)[key]; ambiguous.add(tabId); continue; }
    state.workspace.retained[key] = { ownerSessionId: value.ownerSessionId, origin: value.origin, status: "deliverable" };
  }
  for (const [key, value] of Object.entries(record(stored.workspace?.groups) ? stored.workspace.groups : {})) {
    if (!id(Number(key)) || !record(value) || !id(value.id)) continue;
    state.workspace.groups[key] = {
      id: value.id, manualExpanded: value.manualExpanded === true,
      lastCollapsed: typeof value.lastCollapsed === "boolean" ? value.lastCollapsed : null
    };
  }
  for (const [targetId, value] of Object.entries(record(stored.workspace?.pendingTargets) ? stored.workspace.pendingTargets : {})) {
    if (targetId && targetId.length <= 200 && record(value) && typeof value.sessionId === "string"
        && Object.hasOwn(state.sessions, value.sessionId) && Number.isFinite(value.expires)
        && value.expires > 0 && value.expires <= Date.now() + 60_000) {
      state.workspace.pendingTargets[targetId] = { sessionId: value.sessionId, expires: value.expires,
        unresolved: value.unresolved === true || value.expires <= Date.now() };
    }
  }
  for (const [token, value] of Object.entries(record(stored.workspace?.creations) ? stored.workspace.creations : {})) {
    if (token && record(value) && typeof value.sessionId === "string" && Object.hasOwn(state.sessions, value.sessionId)) {
      // A worker restart does not prove that a command sent before the restart failed.
      state.workspace.creations[token] = { sessionId: value.sessionId, status: "uncertain" };
    }
  }
  return state;
}

export async function saveWorkspaceState(chrome, state) {
  if (!chrome.storage?.session) throw new Error("Godspeed workspace requires Chrome session storage.");
  await chrome.storage.session.set({ [WORKSPACE_STATE_KEY]: state });
}

export function findTabOwner(state, tabId) {
  if (!id(tabId)) return null;
  for (const [sessionId, session] of Object.entries(state.sessions)) {
    if (Object.hasOwn(session.tabOrigins ?? {}, String(tabId))) {
      return { sessionId, origin: session.tabOrigins[String(tabId)], retained: false };
    }
  }
  const retained = state.workspace.retained[String(tabId)];
  return retained ? { sessionId: retained.ownerSessionId, origin: retained.origin, retained: true } : null;
}

export class GodspeedWorkspace {
  constructor({ chrome, store, onRemoved = () => {} }) {
    this.chrome = chrome;
    this.store = store;
    this.onRemoved = onRemoved;
    this.ready = store.ready;
    this.queue = Promise.resolve();
    this.timer = null;
    this.retry = 0;
    this.reconciling = false;
    this.disposed = false;
    this.listeners = [];
    this.expectedCollapse = new Map();
    this.lastTabs = new Map();
    this.lastError = null;
    this.persistenceFailure = (error) => {
      this.lastError = `Workspace state has not been saved: ${String(error?.message ?? error)}`;
      if (!this.reconciling && this.retry < RETRY_DELAYS.length) this.schedule(RETRY_DELAYS[this.retry++], false);
    };
    this.store.onPersistenceFailure = this.persistenceFailure;
    const listen = (event, callback) => {
      if (!event?.addListener) return;
      event.addListener(callback);
      this.listeners.push([event, callback]);
    };
    const changed = () => this.schedule();
    for (const event of [chrome.tabs.onCreated, chrome.tabs.onMoved, chrome.tabs.onAttached,
      chrome.tabs.onDetached, chrome.tabGroups.onCreated, chrome.tabGroups.onMoved,
      chrome.tabGroups.onRemoved, chrome.windows?.onCreated, chrome.windows?.onRemoved]) listen(event, changed);
    listen(chrome.tabs.onUpdated, (_tabId, changes) => {
      if (Object.hasOwn(changes, "groupId") || Object.hasOwn(changes, "pinned")
          || (Object.keys(this.store.state.workspace.pendingTargets).length > 0
            && (Object.hasOwn(changes, "status") || Object.hasOwn(changes, "url")))) this.schedule();
    });
    listen(chrome.tabs.onRemoved, (tabId) => {
      void this.serial(async () => { this.forget(tabId); await this.store.save(); }).catch(() => {});
      this.schedule();
    });
    listen(chrome.tabs.onReplaced, (added, removed) => {
      void this.serial(async () => {
        const owner = findTabOwner(this.store.state, removed);
        if (owner && !findTabOwner(this.store.state, added)) {
          if (owner.retained) this.store.state.workspace.retained[String(added)] = this.store.state.workspace.retained[String(removed)];
          else {
            const session = this.store.state.sessions[owner.sessionId];
            session.tabOrigins[String(added)] = owner.origin;
            if (session.activeTabId === removed) session.activeTabId = added;
          }
        }
        this.forget(removed);
        await this.store.save();
      }).catch(() => {});
      this.schedule();
    });
    listen(chrome.tabGroups.onUpdated, (group) => { void this.groupUpdated(group).catch(() => {}); });
    listen(chrome.tabs.onActivated, ({ tabId }) => {
      // A user selecting one of the group's tabs is a request to see it. Never select a
      // different tab merely to make a group collapsible.
      void this.serial(async () => {
        const tab = await this.chrome.tabs.get(tabId).catch(() => null);
        const preferences = tab && this.groupPreferences(tab.groupId);
        if (preferences && tab.active && !preferences.manualExpanded) {
          preferences.manualExpanded = true;
          await this.store.save();
        }
      }).catch(() => {}).finally(() => this.schedule());
    });
    void this.ready.then(() => this.schedule()).catch((error) => { this.lastError = String(error); });
  }

  serial(operation) {
    const result = this.queue.then(() => this.ready).then(operation);
    this.queue = result.catch(() => {});
    return result;
  }

  dispose() {
    this.disposed = true;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    for (const [event, callback] of this.listeners) event.removeListener?.(callback);
    this.listeners.length = 0;
    if (this.store.onPersistenceFailure === this.persistenceFailure) this.store.onPersistenceFailure = null;
  }

  groupPreferences(groupId) {
    return Object.values(this.store.state.workspace.groups).find((group) => group.id === groupId);
  }

  async groupUpdated(group) {
    await this.ready;
    const preferences = this.groupPreferences(group.id);
    if (!preferences) return;
    if (this.expectedCollapse.get(group.id) === group.collapsed) this.expectedCollapse.delete(group.id);
    else if (typeof group.collapsed === "boolean" && preferences.lastCollapsed !== null
        && preferences.lastCollapsed !== group.collapsed) preferences.manualExpanded = !group.collapsed;
    preferences.lastCollapsed = group.collapsed;
    // Do not write a snapshot outside the ownership queue.
    await this.serial(() => this.store.save());
    this.schedule();
  }

  schedule(delay = 35, resetRetry = true) {
    if (this.disposed) return;
    if (resetRetry && !this.reconciling) this.retry = 0;
    if (this.timer !== null) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      void this.reconcileNow().catch(() => {});
    }, delay);
    this.timer.unref?.();
  }

  async reconcileNow() {
    if (this.disposed) return;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
    return this.serial(async () => {
      this.reconciling = true;
      try {
        await this.reconcile();
        this.retry = 0;
        this.lastError = null;
      } catch (error) {
        this.lastError = String(error?.message ?? error);
        if (error?.retryable !== false && this.retry < RETRY_DELAYS.length) this.schedule(RETRY_DELAYS[this.retry++], false);
        throw error;
      } finally { this.reconciling = false; }
    });
  }

  forget(tabId) {
    for (const session of Object.values(this.store.state.sessions)) {
      delete session.tabOrigins[String(tabId)];
      if (session.activeTabId === tabId) session.activeTabId = null;
    }
    delete this.store.state.workspace.retained[String(tabId)];
    this.lastTabs.delete(tabId);
    this.onRemoved(tabId);
  }

  async ownedTabs(sessionId) {
    await this.ready;
    const session = await this.store.getSession(sessionId);
    const tabs = await this.chrome.tabs.query({});
    return tabs.filter((tab) => id(tab.id) && Object.hasOwn(session.tabOrigins, String(tab.id))
      && !tab.url?.startsWith("chrome://"));
  }

  async beginCreation(sessionId) {
    return this.serial(async () => {
      await this.store.getSession(sessionId);
      const token = crypto.randomUUID();
      this.store.state.workspace.creations[token] = { sessionId, status: "running" };
      await this.store.save();
      return token;
    });
  }

  async creationFailed(token, uncertain = false) {
    return this.serial(async () => {
      const receipt = this.store.state.workspace.creations[token];
      if (!receipt) return;
      if (uncertain) receipt.status = "uncertain";
      else delete this.store.state.workspace.creations[token];
      await this.store.save();
    });
  }

  async claim(sessionId, tabId, source, creationToken = null) {
    if (!id(tabId) || !origin(source)) throw new Error("Invalid workspace tab ownership.");
    return this.serial(async () => {
      const session = await this.store.getSession(sessionId);
      const owner = findTabOwner(this.store.state, tabId);
      if (owner && owner.sessionId !== sessionId) throw new Error(`Tab ${tabId} is already part of browser session ${owner.sessionId}`);
      if (creationToken && this.store.state.workspace.creations[creationToken]?.sessionId !== sessionId) {
        throw new Error("The tab creation receipt is unavailable");
      }
      const tab = await this.chrome.tabs.get(tabId);
      if (!id(tab.id) || tab.url?.startsWith("chrome://")) throw new Error(`Chrome tab ${tabId} cannot be claimed`);
      // Claiming an existing user tab again must never make cleanup treat it as disposable.
      session.tabOrigins[String(tabId)] = owner?.origin === "user" || source === "user" ? "user" : "agent";
      delete this.store.state.workspace.retained[String(tabId)];
      if (creationToken) {
        delete this.store.state.workspace.creations[creationToken];
      }
      await this.store.save();
      this.schedule();
    });
  }

  async retain(sessionId, tabIds) {
    return this.serial(async () => {
      const session = await this.store.getSession(sessionId);
      for (const tabId of tabIds) {
        if (!Object.hasOwn(session.tabOrigins, String(tabId))) throw new Error(`Cannot retain unowned tab ${tabId}`);
      }
      for (const tabId of tabIds) {
        this.store.state.workspace.retained[String(tabId)] = {
          ownerSessionId: sessionId, origin: session.tabOrigins[String(tabId)], status: "deliverable"
        };
        delete session.tabOrigins[String(tabId)];
      }
      await this.store.save();
      this.schedule();
    });
  }

  async finalize(sessionId, entries, detachMany) {
    return this.serial(async () => {
      if (!Array.isArray(entries)) throw new Error("finalizeTabs requires keep array");
      const session = await this.store.getSession(sessionId);
      const pendingProofs = () => Object.values(this.store.state.workspace.pendingTargets).filter((proof) => proof.sessionId === sessionId);
      if (pendingProofs().length) {
        // Reconcile exact proof locally once before refusing cleanup. Waiting inside this
        // queue for an in-flight command would deadlock its ownership registration.
        await this.reconcile().catch(() => {});
      }
      const creations = Object.values(this.store.state.workspace.creations).filter((receipt) => receipt.sessionId === sessionId);
      if (creations.length || pendingProofs().length) {
        throw new Error("Finalization deferred: a created tab is still registering or its creation outcome is unresolved. Existing tabs and ownership were preserved.");
      }
      const tabs = await this.ownedTabs(sessionId);
      const live = new Map(tabs.map((tab) => [tab.id, tab]));
      const keep = new Map();
      for (const entry of entries) {
        if (!record(entry) || !id(entry.tabId) || !live.has(entry.tabId)) throw new Error("finalizeTabs cannot keep unknown tab");
        if (keep.has(entry.tabId)) throw new Error(`finalizeTabs received duplicate tab ${entry.tabId}`);
        if (entry.status !== "handoff" && entry.status !== "deliverable") throw new Error("finalizeTabs received invalid status");
        keep.set(entry.tabId, entry.status);
      }
      await detachMany([...live.keys()]);
      try {
        for (const [tabId] of live) {
          const status = keep.get(tabId);
          if (status === "handoff") continue;
          if (status === "deliverable") {
            this.store.state.workspace.retained[String(tabId)] = {
              ownerSessionId: sessionId, origin: session.tabOrigins[String(tabId)], status
            };
          } else if (session.tabOrigins[String(tabId)] === "agent") {
            try { await this.chrome.tabs.remove(tabId); }
            catch (error) { if (await this.chrome.tabs.get(tabId).catch(() => null)) throw error; }
          } else {
            const current = await this.chrome.tabs.get(tabId).catch(() => null);
            // If a human moved it into their own group, release ownership in place.
            if (current && this.groupPreferences(current.groupId)) await this.chrome.tabs.ungroup(tabId);
          }
          delete session.tabOrigins[String(tabId)];
          this.onRemoved(tabId);
        }
      } finally {
        const handoff = [...keep].filter(([, status]) => status === "handoff").map(([tabId]) => tabId);
        session.activeTabId = handoff.includes(session.activeTabId) ? session.activeTabId : handoff[0] ?? null;
        // An interrupted cleanup preserves remaining ownership for a later safe retry.
        if (Object.keys(session.tabOrigins).length === 0) delete this.store.state.sessions[sessionId];
        await this.store.save();
        this.schedule();
      }
      return this.store.state.sessions[sessionId]?.activeTabId ?? null;
    });
  }

  async adoptCreatedTarget(sessionId, targetId, creationToken = null) {
    if (typeof targetId !== "string" || !targetId) return;
    // Exact command result -> Chrome target -> tab is creation proof. Neither a matching
    // URL nor openerTabId nor timing proximity grants ownership to an agent.
    await this.serial(async () => {
      await this.store.getSession(sessionId);
      if (creationToken && this.store.state.workspace.creations[creationToken]?.sessionId !== sessionId) {
        throw new Error("The target creation receipt is unavailable");
      }
      this.store.state.workspace.pendingTargets[targetId] = { sessionId, expires: Date.now() + 10_000 };
      if (creationToken) {
        delete this.store.state.workspace.creations[creationToken];
      }
      await this.store.save();
    });
    await this.reconcileNow().catch(() => {});
  }

  async reconcile() {
    const all = await this.chrome.tabs.query({});
    const tabs = all.filter((tab) => id(tab.id));
    this.lastTabs = new Map(tabs.map((tab) => [tab.id, tab]));
    const state = this.store.state;
    let changed = false;
    if (Object.keys(state.workspace.pendingTargets).length) {
      const targets = await this.chrome.debugger.getTargets();
      for (const [targetId, proof] of Object.entries(state.workspace.pendingTargets)) {
        const target = targets.find((candidate) => candidate.id === targetId && id(candidate.tabId));
        const session = state.sessions[proof.sessionId];
        if (!session) continue;
        if (proof.expires <= Date.now() && proof.unresolved !== true) { proof.unresolved = true; changed = true; }
        if (!target || !this.lastTabs.has(target.tabId)) continue;
        const owner = findTabOwner(state, target.tabId);
        if (!owner || owner.sessionId === proof.sessionId) {
          session.tabOrigins[String(target.tabId)] = owner?.origin ?? "agent";
          delete state.workspace.retained[String(target.tabId)];
        } else { proof.unresolved = true; changed = true; continue; }
        delete state.workspace.pendingTargets[targetId];
        changed = true;
      }
    }
    const tracked = new Set([...Object.values(state.sessions).flatMap((session) => Object.keys(session.tabOrigins)),
      ...Object.keys(state.workspace.retained)].map(Number));
    for (const tabId of tracked) {
      if (!this.lastTabs.has(tabId)) { this.forget(tabId); tracked.delete(tabId); changed = true; }
    }
    const normal = new Set((await this.chrome.windows.getAll({ windowTypes: ["normal"] })).map((window) => window.id));
    const groups = dictionary();
    // Chrome can move or recreate a group when a user drags it between windows.
    for (const preferences of Object.values(state.workspace.groups)) {
      const group = await this.chrome.tabGroups.get(preferences.id).catch(() => null);
      if (group && normal.has(group.windowId) && !groups[String(group.windowId)]) groups[String(group.windowId)] = preferences;
    }
    if (JSON.stringify(groups) !== JSON.stringify(state.workspace.groups)) changed = true;
    state.workspace.groups = groups;
    for (const windowId of normal) {
      const owned = tabs.filter((tab) => tab.windowId === windowId && tracked.has(tab.id) && !tab.pinned);
      if (!owned.length) {
        if (groups[String(windowId)]) { delete groups[String(windowId)]; changed = true; }
        continue;
      }
      let preferences = groups[String(windowId)];
      if (!preferences) {
        // A recreated group is adoptable only if every member is explicitly ours. Its
        // title is irrelevant; a user's restored or similarly named group is never seized.
        const candidate = owned.find((tab) => id(tab.groupId)
          && tabs.filter((member) => member.groupId === tab.groupId).every((member) => tracked.has(member.id)));
        const groupId = candidate?.groupId ?? await this.chrome.tabs.group({ tabIds: owned.map((tab) => tab.id), createProperties: { windowId } });
        const group = await this.chrome.tabGroups.get(groupId);
        preferences = { id: groupId, manualExpanded: false, lastCollapsed: group.collapsed };
        groups[String(windowId)] = preferences;
        changed = true;
      }
      const grouped = new Set((await this.chrome.tabs.query({ groupId: preferences.id })).map((tab) => tab.id));
      const missing = owned.filter((tab) => !grouped.has(tab.id)).map((tab) => tab.id);
      if (missing.length) await this.chrome.tabs.group({ groupId: preferences.id, tabIds: missing });
      let group = await this.chrome.tabGroups.get(preferences.id);
      if (group.title !== WORKSPACE_TITLE || group.color !== WORKSPACE_COLOR) {
        group = await this.chrome.tabGroups.update(group.id, { title: WORKSPACE_TITLE, color: WORKSPACE_COLOR });
      }
      const windowTabs = await this.chrome.tabs.query({ windowId });
      const members = windowTabs.filter((tab) => tab.groupId === group.id);
      const index = Math.min(...members.map((tab) => tab.index));
      const left = windowTabs.filter((tab) => tab.pinned).length;
      if (Number.isFinite(index) && index !== left) await this.chrome.tabGroups.move(group.id, { index: left });
      // Re-read immediately before collapse; activation is never part of organization.
      const active = await this.chrome.tabs.query({ groupId: group.id, active: true });
      if (!preferences.manualExpanded && !group.collapsed && active.length === 0) {
        this.expectedCollapse.set(group.id, true);
        try {
          group = await this.chrome.tabGroups.update(group.id, { collapsed: true });
          preferences.lastCollapsed = true;
          changed = true;
        } catch (error) { this.expectedCollapse.delete(group.id); throw error; }
      }
      for (const tab of windowTabs) this.lastTabs.set(tab.id, tab);
    }
    if (changed || this.store.hasUnsavedState) await this.store.save();
    // Target creation can be acknowledged before Chrome exposes its tab ID. Keep the
    // proof across worker suspension, retry only the bounded local schedule, and also
    // wake on the tab's later navigation/creation event. Never create a second tab.
    if (Object.keys(state.workspace.pendingTargets).length) {
      const error = new Error("Waiting for Chrome to expose the newly created target's tab ID; unresolved creation ownership is preserved");
      error.retryable = Object.values(state.workspace.pendingTargets).some((proof) => !proof.unresolved);
      throw error;
    }
  }
}
