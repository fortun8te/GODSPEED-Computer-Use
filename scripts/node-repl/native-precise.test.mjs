import assert from "node:assert/strict";
import test from "node:test";
import { PersistentJavaScriptSession } from "./open-computer-use-repl.mjs";

function textResult(text, isError = false) {
  return { content: [{ type: "text", text }], isError };
}

// Records every native call. Each call gets a plain reply named after the tool.
function mockNative() {
  const calls = [];
  return {
    calls,
    async request(method, params) {
      assert.equal(method, "tools/call");
      calls.push(params);
      return textResult(params.name);
    },
  };
}

// Runs `code` in the REPL. A thrown error prints its code (or message) so the test can compare it.
async function failure(session, code) {
  const result = await session.run(`try { await ${code}; } catch (error) { nodeRepl.write(error.code ?? error.message); }`);
  assert.equal(result.isError, false, result.content.at(-1)?.text);
  return result.content.at(-1).text;
}

async function session(t) {
  const native = mockNative();
  const repl = new PersistentJavaScriptSession({ native });
  t.after(() => repl.close?.());
  await repl.run(`var app = cua.app("Notes");`);
  return { native, repl };
}

function lastArgs(native) {
  return native.calls.at(-1);
}

// Calls made inside the REPL come from its own JavaScript realm, so compare plain JSON copies.
function same(actual, expected) {
  assert.deepEqual(JSON.parse(JSON.stringify(actual)), JSON.parse(JSON.stringify(expected)));
}

test("cua.app binds without reading the app state", async t => {
  const { native, repl } = await session(t);
  const result = await repl.run(`await app.click("Send");`);
  assert.equal(result.isError, false, result.content.at(-1)?.text);
  assert.deepEqual(native.calls.map(call => call.name), ["click"]);
  assert.equal(await failure(repl, `cua.app("  ")`), "app requires an app name or bundle ID");
});

test("click maps a label, a button, a count, an anchor, an offset and modifiers", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.click("Send", { button: "right", clickCount: 2, anchor: "right", offset: { x: -4, y: 0 }, modifiers: ["Meta"], windowId: 17, strictBackground: true });`);
  same(lastArgs(native), {
    name: "click",
    arguments: {
      app: "Notes", label: "Send", mouse_button: "right", click_count: 2, anchor: "right", offset_x: -4, offset_y: 0,
      modifiers: ["cmd"], window_id: 17, strict_background: true,
    },
  });
  await repl.run(`await app.click(12, { button: "left" });`);
  assert.equal(lastArgs(native).arguments.element_index, 12);
  await repl.run(`await app.click([30, 40], { button: "middle" });`);
  same(lastArgs(native).arguments, { app: "Notes", x: 30, y: 40, mouse_button: "middle" });
});

test("click refuses bad values and an anchor on coordinates before any call", async t => {
  const { native, repl } = await session(t);
  const before = native.calls.length;
  for (const code of [
    `app.click("Send", { anchor: "middle" })`,
    `app.click([1, 2], { anchor: "left" })`,
    `app.click([1, 2], { offset: { x: 1, y: 0 } })`,
    `app.click("Send", { clickCount: 33 })`,
    `app.click("Send", { button: "side" })`,
    `app.click("Send", { modifiers: ["Hyper"] })`,
  ]) {
    assert.notEqual(await failure(repl, code), "", code);
  }
  assert.equal(native.calls.length, before);
});

test("hover maps a label and dwellMs up to 2000 ms", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.hover("Info", { dwellMs: 2000 });`);
  same(lastArgs(native).arguments, { app: "Notes", label: "Info", dwell_ms: 2000 });
  assert.equal(await failure(repl, `app.hover("Info", { dwellMs: 2001 })`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, 1);
});

test("drag maps labels, coordinates and element numbers at either end, with steps, hold and verify", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.drag("Card A", "Drop zone", { steps: 5, holdMs: 120, verify: { label: "Card A", condition: "disappears", timeout: 4 } });`);
  same(lastArgs(native).arguments, {
    app: "Notes", from_label: "Card A", to_label: "Drop zone", drag_steps: 5, hold_ms: 120,
    verify: { label: "Card A", condition: "disappears", timeout: 4 },
  });
  await repl.run(`await app.drag([10, 20], 7);`);
  same(lastArgs(native).arguments, { app: "Notes", from_x: 10, from_y: 20, to_index: 7 });
  await repl.run(`await app.drag(3, [5, 6], { modifiers: ["shift"], windowId: 9 });`);
  same(lastArgs(native).arguments, { app: "Notes", from_index: 3, to_x: 5, to_y: 6, modifiers: ["shift"], window_id: 9 });

  const before = native.calls.length;
  assert.equal(await failure(repl, `app.drag("A", "B", { steps: 1 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.drag("A", "B", { holdMs: 1001 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.drag("A", "B", { verify: { label: "A", condition: "visible" } })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.drag([1], "B")`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, before);
});

test("pressKey holds a key for up to 1000 ms", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.pressKey("cmd+s", { holdMs: 300 });`);
  same(lastArgs(native).arguments, { app: "Notes", key: "cmd+s", hold_ms: 300 });
  assert.equal(await failure(repl, `app.pressKey("cmd+s", { holdMs: 1001 })`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, 1);
});

test("gesture maps a zoom target or a menu path and needs one of them", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.gesture("zoom_in", { target: "Canvas", windowId: 5 });`);
  same(lastArgs(native).arguments, { app: "Notes", kind: "zoom_in", label: "Canvas", window_id: 5 });
  await repl.run(`await app.gesture("rotate_left", { menuPath: "View > Rotate Left" });`);
  same(lastArgs(native).arguments, { app: "Notes", kind: "rotate_left", menu_path: "View > Rotate Left" });
  await repl.run(`await app.gesture("swipe_back", { target: 4 });`);
  same(lastArgs(native).arguments, { app: "Notes", kind: "swipe_back", element_index: 4 });

  const before = native.calls.length;
  assert.equal(await failure(repl, `app.gesture("tap", { target: "X" })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.gesture("zoom_in")`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.gesture("zoom_in", { target: "X", ref: "y" })`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, before);
});

test("waitFor maps condition, timeout and fromValue and returns the reply text", async t => {
  const { native, repl } = await session(t);
  const result = await repl.run(`nodeRepl.write(await app.waitFor("Saved", { timeout: 5 }));`);
  assert.equal(result.isError, false);
  same(lastArgs(native).arguments, { app: "Notes", label: "Saved", condition: "appears", timeout: 5 });
  assert.equal(result.content.at(-1).text, "wait_for");

  await repl.run(`await app.waitFor("Total", { condition: "value_changed", fromValue: "2", timeout: 30 });`);
  same(lastArgs(native).arguments, {
    app: "Notes", label: "Total", condition: "value_changed", from_value: "2", timeout: 30,
  });

  const before = native.calls.length;
  assert.equal(await failure(repl, `app.waitFor("Saved", { timeout: 31 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.waitFor("Saved", { timeout: 0 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.waitFor("Saved", { condition: "visible" })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.waitFor("Saved", { fromValue: "x" })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.waitFor("Saved", { typo: true })`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, before);
});

test("scroll takes an options object with unit, amount, maxSteps, untilVisible and an optional area", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.scroll({ direction: "down", unit: "lines", amount: 3, maxSteps: 4, untilVisible: "Total" });`);
  same(lastArgs(native).arguments, {
    app: "Notes", direction: "down", unit: "lines", step_size: 3, max_steps: 4, until_visible: "Total",
  });
  await repl.run(`await app.scroll({ direction: "down", unit: "pages", maxSteps: 2, target: "Sidebar", windowId: 6 });`);
  same(lastArgs(native).arguments, {
    app: "Notes", label: "Sidebar", direction: "down", unit: "pages", max_steps: 2, window_id: 6,
  });
  await repl.run(`await app.scroll({ direction: "up", target: { ref: "r1" } });`);
  same(lastArgs(native).arguments, { app: "Notes", ref: "r1", direction: "up" });

  const before = native.calls.length;
  assert.equal(await failure(repl, `app.scroll({ direction: "top" })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.scroll({ direction: "down", unit: "pages", amount: 2 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.scroll({ direction: "down", amount: 2 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.scroll({ direction: "down", maxSteps: 21 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.scroll({ direction: "down", pages: 2 })`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, before);
});

test("scroll keeps the older positional form", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.scroll(3, "down", 2);`);
  same(lastArgs(native).arguments, { app: "Notes", element_index: 3, direction: "down", pages: 2 });
});

test("selectText takes a range or text with prefix and suffix, and a label target", async t => {
  const { native, repl } = await session(t);
  await repl.run(`await app.selectText({ label: "Body" }, { start: 2, length: 3 });`);
  same(lastArgs(native).arguments, { app: "Notes", label: "Body", start: 2, length: 3, selection: undefined });
  await repl.run(`await app.selectText(1, { text: "cart", prefix: "the " }, { selection: "cursor_after" });`);
  same(lastArgs(native).arguments, {
    app: "Notes", element_index: 1, text: "cart", prefix: "the ", suffix: undefined, selection: "cursor_after",
  });
  await repl.run(`await app.selectText(1, "cart", { prefix: "the " });`);
  assert.equal(lastArgs(native).arguments.text, "cart");

  const before = native.calls.length;
  assert.equal(await failure(repl, `app.selectText(1, { start: 2 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.selectText(1, { start: 2, length: 1, text: "x" })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.selectText(1, { text: "x" }, { prefix: "a" })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.selectText({ label: "Body", ref: "r" }, "x")`), "Use { label } as the only element target.");
  assert.equal(native.calls.length, before);
});

test("unknown options are refused before a native call", async t => {
  const { native, repl } = await session(t);
  const before = native.calls.length;
  assert.equal(await failure(repl, `app.gesture("zoom_in", { target: "X", bogus: 1 })`), "INVALID_ARGUMENT");
  assert.equal(await failure(repl, `app.waitFor("Saved", { bogus: 1 })`), "INVALID_ARGUMENT");
  assert.equal(native.calls.length, before);
});
