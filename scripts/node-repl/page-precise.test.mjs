import assert from "node:assert/strict";
import test from "node:test";
import { createBrowserPage } from "./page-api.mjs";

// Fake cua.browser: records every call. Reads answer with the controls named in `readWith`.
function fakeBrowser(respond = () => ok("ok")) {
  const calls = [];
  const browser = async (action, args, options = {}) => {
    calls.push({ action, args, options });
    return respond({ action, args, options });
  };
  browser.calls = calls;
  return browser;
}

function ok(text) {
  return { text, isError: false, pages: [] };
}

function readWith(...lines) {
  return ok(["Page: https://example.test/", "Controls:", ...lines, "(exact-name search)"].join("\n"));
}

function reading(...lines) {
  return fakeBrowser(({ action }) => (action === "read" ? readWith(...lines) : ok(`${action} ok`)));
}

// Every call except the preflight reads, as [action, args] pairs.
function sent(browser) {
  return browser.calls.filter(call => call.action !== "read").map(call => [call.action, call.args]);
}

async function rejects(promise, code) {
  await assert.rejects(promise, { code });
}

test("locator.click maps anchor, offset, modifiers, button and click count", async () => {
  const browser = reading("button Save");
  const save = createBrowserPage(browser, 7).getByRole("button", { name: "Save" });
  await save.click({ anchor: "right", offset: { x: -4, y: 2 }, modifiers: ["Meta", "Shift"], button: "left", clickCount: 2 });
  assert.deepEqual(browser.calls.at(-1), {
    action: "click",
    args: { tab_id: 7, label: "Save", anchor: "right", offset_x: -4, offset_y: 2, modifiers: ["cmd", "shift"], mouse_button: "left", click_count: 2 },
    options: { emit: false },
  });
});

test("locator.click refuses a position and bad values before reading or clicking", async () => {
  const browser = reading("button Save");
  const save = createBrowserPage(browser, 7).getByRole("button", { name: "Save" });
  await rejects(save.click({ position: { x: 4, y: 4 } }), "UNSUPPORTED");
  await rejects(save.click({ anchor: "top-left" }), "INVALID_ARGUMENT");
  await rejects(save.click({ modifiers: ["Super"] }), "INVALID_ARGUMENT");
  await rejects(save.click({ button: "right", clickCount: 2 }), "INVALID_ARGUMENT");
  await rejects(save.click({ clickCount: 4 }), "INVALID_ARGUMENT");
  assert.equal(browser.calls.length, 0, "invalid clicks send nothing and read nothing");
});

test("locator.hover maps dwellMs within the 2000 ms limit", async () => {
  const browser = reading("button Tooltip");
  const tip = createBrowserPage(browser, 3).getByRole("button", { name: "Tooltip" });
  await tip.hover({ dwellMs: 800 });
  assert.deepEqual(sent(browser), [["hover", { tab_id: 3, label: "Tooltip", dwell_ms: 800 }]]);
  await rejects(tip.hover({ dwellMs: 2001 }), "INVALID_ARGUMENT");
  await rejects(tip.hover({ dwellMs: -5 }), "INVALID_ARGUMENT");
  assert.equal(sent(browser).length, 1);
});

test("locator.dragTo maps steps, hold and verify, and needs two locators", async () => {
  const browser = reading("button Card A", "button Drop zone");
  const page = createBrowserPage(browser, 4);
  const card = page.getByRole("button", { name: "Card A" });
  const zone = page.getByRole("button", { name: "Drop zone" });
  await card.dragTo(zone, { steps: 6, holdMs: 150, verify: { label: "Card A", condition: "appears", timeout: 3 }, strictBackground: true });
  assert.deepEqual(browser.calls.at(-1), {
    action: "drag",
    args: {
      tab_id: 4, label: "Card A", to_label: "Drop zone", drag_steps: 6, hold_ms: 150,
      verify: { label: "Card A", condition: "appears", timeout: 3 },
    },
    options: { emit: false, strictBackground: true },
  });

  const before = browser.calls.length;
  await rejects(card.dragTo("Drop zone"), "INVALID_ARGUMENT");
  await rejects(card.dragTo(zone, { steps: 1 }), "INVALID_ARGUMENT");
  await rejects(card.dragTo(zone, { steps: 31 }), "INVALID_ARGUMENT");
  await rejects(card.dragTo(zone, { holdMs: 1200 }), "INVALID_ARGUMENT");
  await rejects(card.dragTo(zone, { verify: { label: "Card A", condition: "visible" } }), "INVALID_ARGUMENT");
  assert.equal(browser.calls.length, before, "invalid drags read and send nothing");
});

test("locator.dragTo stops on an ambiguous destination before dragging", async () => {
  const browser = reading("button Card A", "button Drop zone", "link Drop zone");
  const page = createBrowserPage(browser, 4);
  // Role-less getByText counts the button and the link, so the destination is ambiguous.
  await rejects(page.getByRole("button", { name: "Card A" }).dragTo(page.getByText("Drop zone")), "AMBIGUOUS_TARGET");
  assert.deepEqual(sent(browser), []);
});

test("locator.scrollIntoViewIfNeeded reveals the control by its label", async () => {
  const browser = reading("button Checkout");
  await createBrowserPage(browser, 2).getByRole("button", { name: "Checkout" }).scrollIntoViewIfNeeded();
  assert.deepEqual(sent(browser), [["scroll_into_view", { tab_id: 2, label: "Checkout" }]]);
});

test("locator.selectText maps a text match, a UTF-16 range, and text with a prefix", async () => {
  const browser = reading("textbox Notes");
  const notes = createBrowserPage(browser, 6).getByRole("textbox", { name: "Notes" });
  await notes.selectText({ start: 2, length: 4 });
  await notes.selectText("cart");
  await notes.selectText({ text: "cart", prefix: "the " });
  assert.deepEqual(sent(browser), [
    ["select_text", { tab_id: 6, label: "Notes", start: 2, length: 4 }],
    ["select_text", { tab_id: 6, label: "Notes", text: "cart" }],
    ["select_text", { tab_id: 6, label: "Notes", text: "cart", prefix: "the " }],
  ]);
  await rejects(notes.selectText({ start: 1 }), "INVALID_ARGUMENT");
  await rejects(notes.selectText({ start: 1, length: 2, text: "x" }), "INVALID_ARGUMENT");
  await rejects(notes.selectText({ start: -1, length: 2 }), "INVALID_ARGUMENT");
  await rejects(notes.selectText(5), "INVALID_ARGUMENT");
  assert.equal(sent(browser).length, 3);
});

test("page.mouse.wheel sends one point chunk per axis and nothing for a zero turn", async () => {
  const browser = reading();
  const page = createBrowserPage(browser, 9);
  await page.mouse.wheel(0, 240, { strictBackground: true });
  assert.deepEqual(browser.calls.at(-1), {
    action: "scroll",
    args: { tab_id: 9, direction: "down", unit: "points", step_size: 240, max_steps: 1 },
    options: { emit: false, strictBackground: true },
  });
  await page.mouse.wheel(40, -10);
  assert.deepEqual(sent(browser).slice(-2), [
    ["scroll", { tab_id: 9, direction: "up", unit: "points", step_size: 10, max_steps: 1 }],
    ["scroll", { tab_id: 9, direction: "right", unit: "points", step_size: 40, max_steps: 1 }],
  ]);
  const before = browser.calls.length;
  await page.mouse.wheel(0, 0);
  assert.equal(browser.calls.length, before);
  await rejects(page.mouse.wheel(0, 2.5), "INVALID_ARGUMENT");
  assert.equal(browser.calls.length, before);
});

test("page.scroll maps direction, unit, amount, maxSteps and untilVisible", async () => {
  const browser = reading();
  const page = createBrowserPage(browser, 5);
  await page.scroll({ direction: "down", unit: "pages", maxSteps: 3, untilVisible: "Checkout" });
  await page.scroll({ direction: "bottom" });
  await page.scroll({ direction: "up", unit: "lines", amount: 2, strictBackground: false });
  assert.deepEqual(sent(browser), [
    ["scroll", { tab_id: 5, direction: "down", unit: "pages", max_steps: 3, until_visible: "Checkout" }],
    ["scroll", { tab_id: 5, direction: "bottom" }],
    ["scroll", { tab_id: 5, direction: "up", unit: "lines", step_size: 2 }],
  ]);
  await rejects(page.scroll({ direction: "sideways" }), "INVALID_ARGUMENT");
  await rejects(page.scroll({ amount: 2 }), "INVALID_ARGUMENT");
  await rejects(page.scroll({ direction: "down", amount: 2 }), "INVALID_ARGUMENT");
  await rejects(page.scroll({ direction: "down", unit: "pages", amount: 2 }), "INVALID_ARGUMENT");
  await rejects(page.scroll({ direction: "down", maxSteps: 21 }), "INVALID_ARGUMENT");
  await rejects(page.scroll({ direction: "down", force: true }), "UNSUPPORTED");
  assert.equal(sent(browser).length, 3);
});

test("keyboard.press holds a key for up to 1000 ms", async () => {
  const browser = reading();
  const page = createBrowserPage(browser, 8);
  await page.keyboard.press("Shift", { holdMs: 250 });
  await page.keyboard.press("Enter");
  assert.deepEqual(sent(browser), [
    ["key", { tab_id: 8, key: "Shift", hold_ms: 250 }],
    ["key", { tab_id: 8, key: "Enter" }],
  ]);
  await rejects(page.keyboard.press("Shift", { holdMs: 1200 }), "INVALID_ARGUMENT");
  assert.equal(sent(browser).length, 2);
});

test("page.zoom, goBack and goForward map to the browser's gesture and history actions", async () => {
  const browser = reading();
  const page = createBrowserPage(browser, 1);
  await page.zoom("in");
  await page.zoom("out");
  await page.goBack();
  await page.goForward({ strictBackground: true });
  assert.deepEqual(sent(browser), [
    ["gesture", { tab_id: 1, kind: "zoom_in" }],
    ["gesture", { tab_id: 1, kind: "zoom_out" }],
    ["back", { tab_id: 1 }],
    ["forward", { tab_id: 1 }],
  ]);
  assert.equal(browser.calls.at(-1).options.strictBackground, true);
  await rejects(page.zoom("sideways"), "INVALID_ARGUMENT");
  assert.equal(sent(browser).length, 4);
});

test("page.hover passes dwellMs through and refuses windowId", async () => {
  const browser = reading("button Save");
  const page = createBrowserPage(browser, 2);
  await page.hover("Save", { dwellMs: 2000 });
  assert.deepEqual(sent(browser), [["hover", { tab_id: 2, label: "Save", dwell_ms: 2000 }]]);
  await rejects(page.hover("Save", { dwellMs: 2001 }), "INVALID_ARGUMENT");
  await rejects(page.hover("Save", { windowId: 4 }), "UNSUPPORTED");
});
