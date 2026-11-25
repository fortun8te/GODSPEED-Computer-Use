export class ChromeEvent {
  listeners = new Set();
  addListener(listener) { this.listeners.add(listener); }
  removeListener(listener) { this.listeners.delete(listener); }
  emit(...args) { for (const listener of [...this.listeners]) listener(...structuredClone(args)); }
}

export function fakeChrome({ tabs = [], groups = [], local = {}, session = {}, windows = null } = {}) {
  const calls = [];
  const failures = new Map();
  const tabMap = new Map(tabs.map((tab, index) => [tab.id, {
    windowId: 1, index, groupId: -1, active: false, pinned: false,
    url: `https://example.test/${tab.id}`, title: `Tab ${tab.id}`, ...tab
  }]));
  const groupMap = new Map(groups.map((group) => [group.id, {
    title: "", color: "grey", collapsed: false, windowId: 1, ...group
  }]));
  const windowMap = new Map((windows ?? [...new Set([...tabMap.values()].map((tab) => tab.windowId))]
    .map((windowId) => ({ id: windowId, type: "normal", focused: windowId === 1 }))).map((window) => [window.id, { ...window }]));
  let nextTab = Math.max(100, ...tabMap.keys()) + 1;
  let nextGroup = Math.max(500, ...groupMap.keys()) + 1;
  let nextWindow = Math.max(10, ...windowMap.keys()) + 1;
  let commandHook = null;
  const event = () => new ChromeEvent();
  const nativePort = {
    onMessage: event(), onDisconnect: event(), messages: [],
    postMessage(message) { this.messages.push(structuredClone(message)); }
  };
  function log(name, args) {
    calls.push({ name, args: structuredClone(args) });
    const failure = failures.get(name);
    if (failure?.count > 0) { failure.count--; throw new Error(failure.message); }
  }
  const getTab = (tabId) => {
    const tab = tabMap.get(tabId);
    if (!tab) throw new Error(`No tab with id ${tabId}`);
    return tab;
  };
  const getGroup = (groupId) => {
    const group = groupMap.get(groupId);
    if (!group) throw new Error(`No group with id ${groupId}`);
    return group;
  };
  const list = (windowId) => [...tabMap.values()].filter((tab) => tab.windowId === windowId).sort((a, b) => a.index - b.index);
  const reorder = (ordered) => ordered.forEach((tab, index) => { tab.index = index; });
  const cleanGroups = () => {
    for (const [groupId, group] of groupMap) {
      if (![...tabMap.values()].some((tab) => tab.groupId === groupId)) {
        groupMap.delete(groupId);
        chrome.tabGroups.onRemoved.emit(group);
      }
    }
  };
  function storage(area, values) {
    return {
      async get(key) {
        log(`storage.${area}.get`, key);
        if (key == null) return structuredClone(values);
        return structuredClone(Object.fromEntries((Array.isArray(key) ? key : [key]).map((name) => [name, values[name]])));
      },
      async set(update) {
        log(`storage.${area}.set`, update);
        const changes = {};
        for (const [key, value] of Object.entries(update)) {
          changes[key] = { oldValue: values[key], newValue: structuredClone(value) };
          values[key] = structuredClone(value);
        }
        chrome.storage.onChanged.emit(changes, area);
      }
    };
  }
  const chrome = {
    storage: { local: storage("local", local), session: storage("session", session), onChanged: event() },
    tabs: {
      onCreated: event(), onMoved: event(), onAttached: event(), onDetached: event(), onUpdated: event(),
      onRemoved: event(), onReplaced: event(), onActivated: event(),
      async query(query = {}) {
        log("tabs.query", query);
        return structuredClone([...tabMap.values()].filter((tab) => Object.entries(query).every(([key, value]) => tab[key] === value))
          .sort((a, b) => a.windowId - b.windowId || a.index - b.index));
      },
      async get(tabId) { log("tabs.get", tabId); return structuredClone(getTab(tabId)); },
      async create(options) {
        log("tabs.create", options);
        const windowId = options.windowId ?? windowMap.keys().next().value ?? 1;
        const tab = { id: nextTab++, windowId, index: list(windowId).length, groupId: -1,
          active: options.active ?? true, pinned: false, url: options.url ?? "about:blank", title: "New tab",
          ...(options.openerTabId ? { openerTabId: options.openerTabId } : {}) };
        if (tab.active) for (const other of list(windowId)) other.active = false;
        tabMap.set(tab.id, tab);
        chrome.tabs.onCreated.emit(tab);
        if (tab.active) chrome.tabs.onActivated.emit({ tabId: tab.id, windowId });
        return structuredClone(tab);
      },
      async group({ tabIds, groupId, createProperties }) {
        log("tabs.group", { tabIds, groupId, createProperties });
        const selected = (Array.isArray(tabIds) ? tabIds : [tabIds]).map(getTab);
        const windowId = createProperties?.windowId ?? selected[0]?.windowId;
        if (selected.some((tab) => tab.pinned || tab.windowId !== windowId)) throw new Error("Tabs cannot be edited while dragging or pinned");
        if (groupId == null) {
          groupId = nextGroup++;
          const group = { id: groupId, windowId, title: "", color: "grey", collapsed: false };
          groupMap.set(groupId, group);
          chrome.tabGroups.onCreated.emit(group);
        }
        if (getGroup(groupId).windowId !== windowId) throw new Error("Wrong group window");
        const previous = new Map(selected.map((tab) => [tab.id, tab.groupId]));
        const all = list(windowId);
        const members = all.filter((tab) => tab.groupId === groupId || selected.includes(tab));
        const position = members[0]?.index ?? all.length;
        const remaining = all.filter((tab) => !members.includes(tab));
        for (const tab of selected) tab.groupId = groupId;
        remaining.splice(Math.min(position, remaining.length), 0, ...members);
        reorder(remaining);
        for (const tab of selected) {
          if (previous.get(tab.id) !== groupId) chrome.tabs.onUpdated.emit(tab.id, { groupId }, tab);
        }
        cleanGroups();
        return groupId;
      },
      async ungroup(ids) {
        log("tabs.ungroup", ids);
        for (const tabId of Array.isArray(ids) ? ids : [ids]) {
          const tab = getTab(tabId);
          tab.groupId = -1;
          chrome.tabs.onUpdated.emit(tabId, { groupId: -1 }, tab);
        }
        cleanGroups();
      },
      async remove(ids) {
        log("tabs.remove", ids);
        for (const tabId of Array.isArray(ids) ? ids : [ids]) {
          const tab = getTab(tabId);
          tabMap.delete(tabId);
          reorder(list(tab.windowId));
          chrome.tabs.onRemoved.emit(tabId, { windowId: tab.windowId, isWindowClosing: false });
        }
        cleanGroups();
      },
      async update(tabId, changes) {
        log("tabs.update", { tabId, changes });
        const tab = getTab(tabId);
        Object.assign(tab, changes);
        chrome.tabs.onUpdated.emit(tabId, changes, tab);
        return structuredClone(tab);
      },
      async sendMessage(tabId, message) { log("tabs.sendMessage", { tabId, message }); return { ok: true }; }
    },
    tabGroups: {
      onCreated: event(), onUpdated: event(), onMoved: event(), onRemoved: event(),
      async get(groupId) { log("tabGroups.get", groupId); return structuredClone(getGroup(groupId)); },
      async query(query = {}) {
        log("tabGroups.query", query);
        return structuredClone([...groupMap.values()].filter((group) => Object.entries(query).every(([key, value]) => group[key] === value)));
      },
      async update(groupId, update) {
        log("tabGroups.update", { groupId, update });
        const group = getGroup(groupId);
        if (update.collapsed === true && [...tabMap.values()].some((tab) => tab.groupId === groupId && tab.active)) {
          throw new Error("Would hide the user's active tab");
        }
        Object.assign(group, update);
        chrome.tabGroups.onUpdated.emit(group);
        return structuredClone(group);
      },
      async move(groupId, { index }) {
        log("tabGroups.move", { groupId, index });
        const group = getGroup(groupId);
        const all = list(group.windowId);
        if (index < all.filter((tab) => tab.pinned).length) throw new Error("Cannot move before pinned tabs");
        const selected = all.filter((tab) => tab.groupId === groupId);
        const remaining = all.filter((tab) => tab.groupId !== groupId);
        remaining.splice(Math.min(index, remaining.length), 0, ...selected);
        reorder(remaining);
        chrome.tabGroups.onMoved.emit(group);
        for (const tab of selected) chrome.tabs.onMoved.emit(tab.id, { windowId: tab.windowId, toIndex: tab.index });
        return structuredClone(group);
      }
    },
    windows: {
      onCreated: event(), onRemoved: event(),
      async getAll(options) { log("windows.getAll", options); return structuredClone([...windowMap.values()].filter((window) => !options.windowTypes || options.windowTypes.includes(window.type))); },
      async create(options) {
        log("windows.create", options);
        const window = { id: nextWindow++, focused: options.focused ?? true, type: options.type ?? "normal" };
        windowMap.set(window.id, window);
        const tab = await chrome.tabs.create({ windowId: window.id, active: true, url: options.url });
        chrome.windows.onCreated.emit(window);
        return { ...window, tabs: [tab] };
      }
    },
    debugger: {
      onDetach: event(), onEvent: event(),
      async attach(target, version) { log("debugger.attach", { target, version }); },
      async detach(target) { log("debugger.detach", target); chrome.debugger.onDetach.emit(target, "canceled_by_user"); },
      async getTargets() {
        log("debugger.getTargets", {});
        return [...tabMap.values()].map((tab) => ({ id: `target-${tab.id}`, tabId: tab.id, type: "page", url: tab.url }));
      },
      async sendCommand(target, method, params) {
        log("debugger.sendCommand", { target, method, params });
        if (commandHook) return await commandHook(target, method, params);
        if (method === "Target.createTarget") {
          const tab = await chrome.tabs.create({ url: params.url, active: !params.background,
            windowId: getTab(target.tabId).windowId, openerTabId: target.tabId });
          return { targetId: `target-${tab.id}` };
        }
        return { ok: true };
      }
    },
    runtime: {
      id: "godspeed-workspace-test", onInstalled: event(), onMessage: event(),
      getManifest: () => ({ version: "1.1.0.1" }),
      connectNative: () => nativePort
    },
    alarms: { onAlarm: event(), async create() {} },
    scripting: { async getRegisteredContentScripts() { return []; }, async registerContentScripts() {}, async unregisterContentScripts() {}, async executeScript() { return []; } },
    downloads: { onCreated: event(), onChanged: event() },
    history: { async search() { return []; } }
  };
  return {
    chrome, calls, tabs: tabMap, groups: groupMap, windows: windowMap, local, session, nativePort,
    fail(name, count = 1, message = "Tabs cannot be edited right now (user may be dragging a tab)") { failures.set(name, { count, message }); },
    command(callback) { commandHook = callback; },
    activate(tabId) {
      const tab = getTab(tabId);
      for (const current of list(tab.windowId)) current.active = current.id === tabId;
      if (tab.groupId !== -1) {
        const group = getGroup(tab.groupId);
        if (group.collapsed) { group.collapsed = false; chrome.tabGroups.onUpdated.emit(group); }
      }
      chrome.tabs.onActivated.emit({ tabId, windowId: tab.windowId });
    },
    moveTabToWindow(tabId, windowId) {
      const tab = getTab(tabId);
      chrome.tabs.onDetached.emit(tabId, { oldWindowId: tab.windowId, oldPosition: tab.index });
      tab.windowId = windowId;
      tab.groupId = -1;
      tab.index = list(windowId).length - 1;
      chrome.tabs.onAttached.emit(tabId, { newWindowId: windowId, newPosition: tab.index });
      cleanGroups();
    }
  };
}
