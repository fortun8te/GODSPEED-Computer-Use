import assert from "node:assert/strict";
import test from "node:test";
import { createBrowserPage, countExactControls } from "./page-api.mjs";
import { PersistentJavaScriptSession } from "./open-computer-use-repl.mjs";

// Fake cua.browser: records every call and answers with `respond`.
function fakeBrowser(respond = () => ok("ok")) {
  const calls = [];
  const browser = async (action, args, options = {}) => {
    calls.push({ action, args, options });
    return respond({ action, args, options, count: calls.length });
  };
  browser.calls = calls;
  return browser;
}

function ok(text) {
  return { text, isError: false, pages: [] };
}

function fail(text, errorCode) {
  return { text, isError: true, pages: [], ...(errorCode === undefined ? {} : { errorCode }) };
}

// A `browser read` with find_exact: one line per matching control.
function readWith(...lines) {
  return ok(["Page: https://example.test/", "Controls:", ...lines,
    "(exact-name search; read the page for numbered controls or to verify page content)"].join("\n"));
}

// Answers by action; `read` answers come from `reads`, a function of the find_exact name.
function byAction(handlers) {
  return ({ action, args, count }) => {
    const handler = handlers[action];
    if (!handler) return ok(`${action} ok`);
    return handler({ args, count });
  };
}

function actions(browser) {
  return browser.calls.map(call => call.action);
}

test("page(tabId) validates the tab and pins every call to it", async () => {
  const browser = fakeBrowser();
  assert.throws(() => createBrowserPage(browser, 0), { code: "INVALID_ARGUMENT" });
  assert.throws(() => createBrowserPage(browser, "7"), { code: "INVALID_ARGUMENT" });
  assert.throws(() => createBrowserPage(browser, 1.5), { code: "INVALID_ARGUMENT" });

  const page = createBrowserPage(browser, 7);
  await page.goto("example.test/cart");
  assert.deepEqual(browser.calls.at(-1), {
    action: "go", args: { tab_id: 7, url: "example.test/cart" }, options: { emit: false },
  });

  const implicit = fakeBrowser();
  await createBrowserPage(implicit).goto("example.test");
  assert.equal("tab_id" in implicit.calls[0].args, false);
});

test("goto, press and type map to navigation and key actions", async () => {
  const browser = fakeBrowser();
  const page = createBrowserPage(browser, 3);
  await page.press("Enter");
  await page.type("hello");
  await page.type("", { replace: true });
  assert.deepEqual(browser.calls.map(call => [call.action, call.args]), [
    ["key", { tab_id: 3, key: "Enter" }],
    ["type", { tab_id: 3, text: "hello" }],
    ["type", { tab_id: 3, text: "", replace: true }],
  ]);
  await assert.rejects(page.goto("   "), { code: "INVALID_ARGUMENT" });
  await assert.rejects(page.press(""), { code: "INVALID_ARGUMENT" });
  assert.equal(browser.calls.length, 3, "invalid arguments send nothing");
});

test("click resolves the label exactly before it sends the click", async () => {
  const browser = fakeBrowser(byAction({ read: () => readWith("button Save") }));
  const page = createBrowserPage(browser, 7);
  assert.equal(await page.click("Save", { button: "right", clickCount: 2, modifiers: ["shift"] }), "click ok");
  assert.deepEqual(actions(browser), ["read", "click"]);
  assert.deepEqual(browser.calls[0].args, { tab_id: 7, find_exact: "Save" });
  assert.deepEqual(browser.calls[1].args, {
    tab_id: 7, label: "Save", mouse_button: "right", click_count: 2, modifiers: ["shift"],
  });
});

test("exact: false skips the preflight read and sends the label as given", async () => {
  const browser = fakeBrowser();
  await createBrowserPage(browser, 7).click("Save draft", { exact: false });
  assert.deepEqual(actions(browser), ["click"]);
  assert.equal(browser.calls[0].args.label, "Save draft");
});

test("ambiguous and missing targets fail before any action is sent", async () => {
  const twoSaves = fakeBrowser(byAction({ read: () => readWith("button Save", "link Save") }));
  await assert.rejects(createBrowserPage(twoSaves, 7).click("Save"), { code: "AMBIGUOUS_TARGET" });
  assert.deepEqual(actions(twoSaves), ["read"]);

  // "Save draft" is not an exact match for "Save".
  const near = fakeBrowser(byAction({ read: () => readWith("button Save draft") }));
  await assert.rejects(createBrowserPage(near, 7).click("Save"), { code: "TARGET_NOT_FOUND" });
  assert.deepEqual(actions(near), ["read"]);
});

test("countExactControls matches names exactly and by role", () => {
  const text = "Page: x\nControls:\nbutton Save\nlink Save\nbutton Save draft (icon:trash)\n(exact-name search)";
  assert.equal(countExactControls(text, "Save", "button"), 1);
  assert.equal(countExactControls(text, "Save"), 2);
  assert.equal(countExactControls(text, "Save draft"), 1, "a hint after the name does not block a match");
  assert.equal(countExactControls("Text:\nWelcome back\n", "Welcome back"), 1, "role-less targets match a whole text line");
  assert.equal(countExactControls("Controls: none\n", "none"), 0, "header lines are skipped");
});

test("CSS selectors and unsupported methods fail with UNSUPPORTED and send nothing", async () => {
  const browser = fakeBrowser();
  const page = createBrowserPage(browser, 7);
  await assert.rejects(page.click("#save"), { code: "UNSUPPORTED" });
  await assert.rejects(page.click(".btn-primary"), { code: "UNSUPPORTED" });
  await assert.rejects(page.hover("text=Save"), { code: "UNSUPPORTED" });
  await assert.rejects(page.fill("div > input", "x"), { code: "UNSUPPORTED" });
  assert.throws(() => page.getByRole("button"), { code: "UNSUPPORTED" });
  assert.throws(() => page.locator("button"), { code: "UNSUPPORTED" });
  assert.throws(() => page.evaluate(), { code: "UNSUPPORTED" });
  assert.throws(() => page.waitForSelector(), { code: "UNSUPPORTED" });
  await assert.rejects(page.click("Save", { force: true }), { code: "UNSUPPORTED" });
  await assert.rejects(page.click("Save", { windowId: 4 }), { code: "UNSUPPORTED" });
  assert.equal(browser.calls.length, 0);
});

test("fill, selectOption, check and uncheck map to their actions", async () => {
  const browser = fakeBrowser(byAction({ read: () => readWith("textbox Email", "combobox Country", "checkbox Terms") }));
  const page = createBrowserPage(browser, 5);
  await page.fill("Email", "a@example.test");
  await page.selectOption("Country", "Canada");
  await page.check("Terms");
  await page.uncheck("Terms");
  await page.hover("Email");
  const calls = browser.calls.filter(call => call.action !== "read");
  assert.deepEqual(calls.map(call => [call.action, call.args]), [
    ["fill_field", { tab_id: 5, label: "Email", text: "a@example.test" }],
    ["select", { tab_id: 5, label: "Country", option: "Canada" }],
    ["check", { tab_id: 5, label: "Terms" }],
    ["uncheck", { tab_id: 5, label: "Terms" }],
    ["hover", { tab_id: 5, label: "Email" }],
  ]);
  await assert.rejects(page.fill("Email", 42), { code: "INVALID_ARGUMENT" });
});

test("waits convert milliseconds to driver seconds and reject waits the driver cannot honour", async () => {
  const browser = fakeBrowser();
  const page = createBrowserPage(browser, 2);
  await page.waitForText("Order placed", { timeout: 2500 });
  await page.waitForURL("/thanks");
  await page.waitForLoadState({ timeout: 4000 });
  assert.deepEqual(browser.calls.map(call => [call.action, call.args]), [
    ["wait_for", { tab_id: 2, text: "Order placed", timeout: 3 }],
    ["wait_for", { tab_id: 2, url_contains: "/thanks", timeout: 10 }],
    ["wait_load", { tab_id: 2, timeout: 4 }],
  ]);
  await assert.rejects(page.waitForText("x", { timeout: 31_000 }), { code: "INVALID_ARGUMENT" });
  await assert.rejects(page.waitForText("x", { timeout: 0 }), { code: "INVALID_ARGUMENT" });
  assert.equal(browser.calls.length, 3, "rejected waits send nothing");
});

test("a wait the driver cannot confirm throws TIMEOUT with the driver error as cause", async () => {
  const browser = fakeBrowser(byAction({
    wait_for: () => fail("browser: could not confirm \"Done\"", "state_unavailable"),
    wait_load: () => fail("still loading", undefined),
  }));
  const page = createBrowserPage(browser, 9);
  await assert.rejects(page.waitForText("Done", { timeout: 1000 }), error => {
    assert.equal(error.code, "TIMEOUT");
    assert.equal(error.cause.code, "state_unavailable");
    return true;
  });
  await assert.rejects(page.waitForLoadState(), { code: "TIMEOUT" });
});

test("textContent, title and url read the info and location actions", async () => {
  const browser = fakeBrowser(byAction({
    info: () => ok("Example — https://example.test/\nHello world"),
    location: () => ok("URL: https://example.test/a\nTitle: Example\nReady state: complete"),
  }));
  const page = createBrowserPage(browser, 4);
  assert.equal(await page.textContent(), "Hello world");
  assert.equal(await page.title(), "Example");
  assert.equal(await page.url(), "https://example.test/a");
  assert.deepEqual(browser.calls.map(call => call.action), ["info", "location", "location"]);
});

test("screenshot is sent only on an explicit call and emits its image", async () => {
  const browser = fakeBrowser(byAction({ read: () => readWith("button Save") }));
  const page = createBrowserPage(browser, 6);
  await page.click("Save");
  assert.equal(actions(browser).includes("screenshot"), false);
  await page.screenshot();
  const shot = browser.calls.at(-1);
  assert.equal(shot.action, "screenshot");
  assert.equal(shot.options.emit, true);
});

test("locators resolve lazily: each action reads the page again", async () => {
  let reads = 0;
  const browser = fakeBrowser(byAction({
    // The control appears on the second read, as after a page update.
    read: () => (++reads === 1 ? readWith() : readWith("button Save")),
    click: () => ok("clicked"),
  }));
  const save = createBrowserPage(browser, 8).getByRole("button", { name: "Save" });
  await assert.rejects(save.click(), { code: "TARGET_NOT_FOUND" });
  assert.equal(await save.click(), "clicked");
  assert.deepEqual(actions(browser), ["read", "read", "click"]);
  assert.deepEqual(browser.calls[1].args, { tab_id: 8, find_exact: "Save" });
  assert.equal(browser.calls[2].args.label, "Save");
});

test("locator isVisible and textContent", async () => {
  let present = false;
  const browser = fakeBrowser(byAction({
    read: () => (present ? readWith("button Save") : readWith()),
    control_state: () => ok("Visible: true\nEnabled: true"),
    read_text: () => ok("Text: (empty)"),
  }));
  const save = createBrowserPage(browser, 1).getByRole("button", { name: "Save" });
  assert.equal(await save.isVisible(), false);
  assert.equal(actions(browser).includes("control_state"), false, "a missing control is not visible and needs no state read");
  present = true;
  assert.equal(await save.isVisible(), true);
  assert.equal(await createBrowserPage(browser, 1).getByText("Save").textContent(), "");
  assert.equal(browser.calls.at(-1).action, "read_text");
  assert.equal(browser.calls.at(-1).args.label, "Save");
});

test("getByText and getByLabel send the name as the label", async () => {
  const browser = fakeBrowser(byAction({ read: () => readWith("textbox Email address") }));
  const page = createBrowserPage(browser, 1);
  await assert.rejects(page.getByLabel("Email").fill("x"), { code: "TARGET_NOT_FOUND" });
  await page.getByLabel("Email address").fill("a@example.test");
  assert.deepEqual(browser.calls.at(-1).args, { tab_id: 1, label: "Email address", text: "a@example.test" });
});

test("driver error codes pass through as typed errors", async () => {
  for (const code of ["STALE_REF", "APPROVAL_REQUIRED", "BACKGROUND_UNSUPPORTED"]) {
    const browser = fakeBrowser(byAction({
      read: () => readWith("button Save"),
      click: () => fail(`${code} message`, code),
    }));
    await assert.rejects(createBrowserPage(browser, 2).click("Save"), error => {
      assert.equal(error.code, code);
      assert.equal(error.action, "click");
      assert.match(error.message, new RegExp(`${code} message`));
      return true;
    });
  }
  const browser = fakeBrowser(byAction({ key: () => fail("no code here") }));
  await assert.rejects(createBrowserPage(browser, 2).press("Enter"), { code: "TOOL_ERROR" });
});

test("strictBackground and the tab pass through every call, including the preflight read", async () => {
  const browser = fakeBrowser(byAction({ read: () => readWith("button Save") }));
  const page = createBrowserPage(browser, 7, { strictBackground: true });
  await page.click("Save");
  assert.deepEqual(browser.calls.map(call => [call.action, call.options.strictBackground, call.args.tab_id]), [
    ["read", true, 7], ["click", true, 7],
  ]);

  await page.click("Save", { strictBackground: false });
  assert.equal(browser.calls.at(-1).options.strictBackground, false, "a per-call value overrides the page default");

  const plain = fakeBrowser();
  await createBrowserPage(plain, 7).goto("example.test");
  assert.equal("strictBackground" in plain.calls[0].options, false, "no value is sent when none is given");

  assert.throws(() => createBrowserPage(fakeBrowser(), 7, { strictBackground: "yes" }), { code: "INVALID_ARGUMENT" });
  await assert.rejects(page.click("Save", { strictBackground: "yes" }), { code: "INVALID_ARGUMENT" });
});

test("cua.browser.page works in the REPL through the native peer", async () => {
  const sent = [];
  const native = {
    async request(method, params) {
      assert.equal(method, "tools/call");
      sent.push(params);
      const args = params.arguments;
      if (params.name !== "browser") return { content: [{ type: "text", text: params.name }], isError: false };
      if (args.action === "read") {
        const text = args.find_exact === "Save" ? "button Save" : "";
        return { content: [{ type: "text", text: `Controls:\n${text}` }], isError: false };
      }
      return { content: [{ type: "text", text: "clicked" }], isError: false };
    },
  };
  const session = new PersistentJavaScriptSession({ native });
  const result = await session.run(`
    const page = cua.browser.page(7, { strictBackground: true });
    nodeRepl.write(await page.click("Save"));
    try { await page.click("#save"); } catch (error) { nodeRepl.write(error.code); }
    try { await page.fill("Missing", "x"); } catch (error) { nodeRepl.write(error.code); }
  `);
  assert.equal(result.isError, false);
  assert.deepEqual(result.content.map(item => item.text), ["clicked", "UNSUPPORTED", "TARGET_NOT_FOUND"]);
  assert.deepEqual(sent.map(({ name, arguments: args }) => [name, args.action, args.strict_background, args.tab_id]), [
    ["browser", "read", true, 7],
    ["browser", "click", true, 7],
    ["browser", "read", true, 7],
  ]);
  assert.equal(sent[1].arguments.label, "Save");
});
