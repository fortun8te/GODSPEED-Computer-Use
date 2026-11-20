// Playwright-style page API for the Chrome browser actions.
//
// Every method becomes one or more `browser(action, args, options)` calls, where `browser`
// is cua.browser. Those calls keep the native policy gates, approval checks and
// strictBackground handling exactly as they are; nothing here talks to the native peer.
//
// Targets are visible labels (or locators built from role, label or text). The browser
// actions take no CSS selectors and no role filter, so selector strings are refused, and
// role or text locators are checked by a read before acting (exact by default).

import {
  browserClickArgs, dragSteps, dwellMs, holdMs, scrollArgs, selectionArgs, verifyArgs, wheelArgs, BROWSER_SCROLL_DIRECTIONS,
} from "./precise-actions.mjs";

const DEFAULT_WAIT_MS = 10_000;
const MAX_WAIT_MS = 30_000;
const NAME_LIMIT = 100; // the browser read clips control names to this many characters
// A visible label is never a selector. Strings that look like one are refused, not guessed at.
const SELECTOR_LIKE = /^(?:[#.[]|\/\/|(?:css|xpath|text|role)=)|\s>\s|:(?:nth|has|not|visible)\b/u;

const PAGE_OPTIONS = ["strictBackground"];
const LABEL_OPTIONS = ["strictBackground", "exact"];
const CLICK_OPTIONS = ["strictBackground", "exact", "button", "clickCount", "modifiers", "anchor", "offset", "position"];
const LOCATOR_CLICK_OPTIONS = ["strictBackground", "button", "clickCount", "modifiers", "anchor", "offset", "position"];
const HOVER_OPTIONS = ["strictBackground", "exact", "dwellMs"];
const LOCATOR_HOVER_OPTIONS = ["strictBackground", "dwellMs"];
const WAIT_OPTIONS = ["strictBackground", "timeout"];
const TYPE_OPTIONS = ["strictBackground", "replace"];
const LOCATOR_OPTIONS = ["strictBackground"];
const DRAG_TO_OPTIONS = ["strictBackground", "steps", "holdMs", "verify"];
const SELECT_TEXT_OPTIONS = ["strictBackground"];
const SCROLL_OPTIONS = ["strictBackground", "direction", "unit", "amount", "maxSteps", "untilVisible"];
const KEY_OPTIONS = ["strictBackground", "holdMs"];
const ZOOM_DIRECTIONS = { in: "zoom_in", out: "zoom_out" };

const locatorDescriptions = new WeakMap();

export class BrowserPageError extends Error {
  constructor(message, code, { action, cause } = {}) {
    super(message, cause === undefined ? undefined : { cause });
    this.name = "BrowserPageError";
    // Driver codes (STALE_REF, APPROVAL_REQUIRED, BACKGROUND_UNSUPPORTED, ...) pass through unchanged.
    // Codes this layer adds: UNSUPPORTED, INVALID_ARGUMENT, TARGET_NOT_FOUND, AMBIGUOUS_TARGET,
    // TIMEOUT, PARSE_FAILED, TOOL_ERROR (a driver failure with no code).
    this.code = code;
    if (action !== undefined) this.action = action;
  }
}

const invalid = message => new BrowserPageError(message, "INVALID_ARGUMENT");
const unsupported = message => new BrowserPageError(message, "UNSUPPORTED");

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function collapse(text) {
  return String(text).replace(/\s+/gu, " ").trim();
}

function nonEmptyString(value, what) {
  if (typeof value !== "string" || !collapse(value)) throw invalid(`${what} must be a nonempty string`);
  return value;
}

function checkOptions(method, options, allowed) {
  if (options === undefined) return {};
  if (!isPlainObject(options)) throw invalid(`${method} expects an options object`);
  for (const key of Object.keys(options)) {
    if (key === "windowId") {
      throw unsupported(`${method}: browser actions target tabs, not windows; use cua.browser.page(tabId)`);
    }
    if (!allowed.includes(key)) throw unsupported(`${method}: option "${key}" has no browser action equivalent`);
  }
  if (options.strictBackground !== undefined && typeof options.strictBackground !== "boolean") {
    throw invalid("strictBackground must be a boolean");
  }
  if (options.exact !== undefined && typeof options.exact !== "boolean") throw invalid("exact must be a boolean");
  return options;
}

function waitSeconds(options) {
  const ms = options.timeout ?? DEFAULT_WAIT_MS;
  if (typeof ms !== "number" || !Number.isFinite(ms) || ms <= 0) {
    throw invalid("timeout must be a positive number of milliseconds");
  }
  if (ms > MAX_WAIT_MS) throw invalid(`timeout must be at most ${MAX_WAIT_MS} ms; the browser waits at most 30 s`);
  return Math.max(1, Math.ceil(ms / 1000));
}

function field(text, name) {
  const match = new RegExp(`^${name}: (.*)$`, "mu").exec(text);
  if (!match) throw new BrowserPageError(`could not read the page ${name.toLowerCase()}`, "PARSE_FAILED");
  return match[1];
}

// Counts controls whose name is exactly `name` in a `browser read` with find_exact. Lines look like
// `button Save (hint) [states] = value → url`; header lines ("Page:", "Controls:", "(...)") are skipped.
// A role-less target (getByText, getByLabel) also accepts a whole text line equal to the name.
export function countExactControls(text, name, role) {
  const wanted = collapse(name).slice(0, NAME_LIMIT);
  const wantedRole = role?.toLowerCase();
  let count = 0;
  for (const raw of String(text).split("\n")) {
    const line = collapse(raw);
    if (!line || line.startsWith("(")) continue;
    if (!wantedRole && line === wanted) {
      count += 1;
      continue;
    }
    const space = line.indexOf(" ");
    if (space < 0) continue;
    const lineRole = line.slice(0, space).toLowerCase();
    if (lineRole.endsWith(":")) continue;
    if (wantedRole && lineRole !== wantedRole) continue;
    const rest = line.slice(space + 1);
    // After the name only a hint, state or value may follow: " (", " [", " =" or " →". Another word is part of the name.
    if (rest === wanted || (rest.startsWith(wanted) && /^ [([=→]/u.test(rest.slice(wanted.length)))) count += 1;
  }
  return count;
}

// createBrowserPage(browser, tabId?, options?) backs cua.browser.page(tabId, options).
// `browser` is cua.browser itself. Pass a tab ID to pin every call to one tab; without one the
// driver uses the current tab, as it does for raw browser calls.
export function createBrowserPage(browser, tabId, pageOptions = {}) {
  if (tabId !== undefined && !(Number.isSafeInteger(tabId) && tabId > 0)) {
    throw invalid("cua.browser.page(tabId) needs a positive integer tab ID from cua.browser(\"tabs\")");
  }
  const defaults = checkOptions("page", pageOptions, PAGE_OPTIONS);
  const tabArgs = tabId === undefined ? {} : { tab_id: tabId };

  // One browser call. Returns the driver's text; a driver error becomes a typed error with its code.
  async function run(action, args = {}, options = {}, { emit = false } = {}) {
    const strictBackground = options.strictBackground ?? defaults.strictBackground;
    const callOptions = { emit };
    if (strictBackground !== undefined) callOptions.strictBackground = strictBackground;
    const reply = await browser(action, { ...tabArgs, ...args }, callOptions);
    if (reply.isError) {
      throw new BrowserPageError(reply.text || `browser ${action} failed`, reply.errorCode ?? "TOOL_ERROR", { action });
    }
    return reply.text;
  }

  // Lazy and exact: each call reads the page again. Nothing is cached, so a locator never acts on a stale reference.
  async function matchCount(desc, options) {
    const text = await run("read", { find_exact: desc.name }, options);
    return countExactControls(text, desc.name, desc.role);
  }

  function ambiguous(desc, count) {
    return new BrowserPageError(`${count} controls match "${desc.name}"; use a narrower role or exact: false`, "AMBIGUOUS_TARGET");
  }

  async function labelFor(desc, options) {
    if (!desc.exact) return desc.name;
    const count = await matchCount(desc, options);
    if (count === 0) {
      const role = desc.role ? ` with role ${desc.role}` : "";
      throw new BrowserPageError(`no control named "${desc.name}"${role}`, "TARGET_NOT_FOUND");
    }
    if (count > 1) throw ambiguous(desc, count);
    return desc.name;
  }

  function describeTarget(target, method, exact = true) {
    const located = typeof target === "object" && target !== null ? locatorDescriptions.get(target) : undefined;
    if (located) return located;
    if (typeof target !== "string") {
      throw invalid(`${method} needs a label string or a locator from getByRole, getByLabel or getByText`);
    }
    const name = nonEmptyString(target, `${method} label`);
    if (SELECTOR_LIKE.test(collapse(name))) {
      throw unsupported(`${method}: CSS and selector strings are not supported by the browser actions; pass the visible label or use getByRole, getByLabel or getByText`);
    }
    return { kind: "label", name: collapse(name), exact };
  }

  // Arguments are checked before the preflight read, so an invalid action reads nothing and sends nothing.
  async function clickOf(desc, options) {
    const args = browserClickArgs(options);
    return run("click", { label: await labelFor(desc, options), ...args }, options);
  }

  async function fillOf(desc, value, options) {
    return run("fill_field", { label: await labelFor(desc, options), text: value }, options);
  }

  // Waits surface a driver state_unavailable (the condition was not seen before the wait ended) as TIMEOUT.
  async function waitFor(args, seconds, what, options) {
    try {
      return await run("wait_for", { ...args, timeout: seconds }, options);
    } catch (error) {
      if (error.code === "state_unavailable") {
        throw new BrowserPageError(`${what} was not confirmed within ${seconds} s`, "TIMEOUT", { action: "wait_for", cause: error });
      }
      throw error;
    }
  }

  function makeLocator(desc) {
    const locator = Object.freeze({
      async click(options) {
        return clickOf(desc, checkOptions("locator.click", options, LOCATOR_CLICK_OPTIONS));
      },
      async fill(value, options) {
        const opts = checkOptions("locator.fill", options, LOCATOR_OPTIONS);
        if (typeof value !== "string") throw invalid("fill value must be a string");
        return fillOf(desc, value, opts);
      },
      async isVisible(options) {
        const opts = checkOptions("locator.isVisible", options, LOCATOR_OPTIONS);
        if (desc.exact) {
          const count = await matchCount(desc, opts);
          if (count === 0) return false;
          if (count > 1) throw ambiguous(desc, count);
        }
        const text = await run("control_state", { label: desc.name }, opts);
        const match = /^Visible: (true|false)$/mu.exec(text);
        if (!match) throw new BrowserPageError("could not read control visibility", "PARSE_FAILED", { action: "control_state" });
        return match[1] === "true";
      },
      async textContent(options) {
        const opts = checkOptions("locator.textContent", options, LOCATOR_OPTIONS);
        const text = await run("read_text", { label: await labelFor(desc, opts) }, opts);
        return text === "Text: (empty)" ? "" : text;
      },
      async hover(options) {
        const opts = checkOptions("locator.hover", options, LOCATOR_HOVER_OPTIONS);
        const args = opts.dwellMs === undefined ? {} : { dwell_ms: dwellMs(opts.dwellMs) };
        return run("hover", { label: await labelFor(desc, opts), ...args }, opts);
      },
      // Drags this control onto `target`, another locator in the same tab. `verify` is checked after the drop.
      async dragTo(target, options) {
        const opts = checkOptions("locator.dragTo", options, DRAG_TO_OPTIONS);
        const destination = typeof target === "object" && target !== null ? locatorDescriptions.get(target) : undefined;
        if (!destination) throw invalid("dragTo needs a locator from getByRole, getByLabel or getByText");
        const args = {};
        if (opts.steps !== undefined) args.drag_steps = dragSteps(opts.steps);
        if (opts.holdMs !== undefined) args.hold_ms = holdMs(opts.holdMs);
        if (opts.verify !== undefined) args.verify = verifyArgs(opts.verify);
        const from = await labelFor(desc, opts);
        const to = await labelFor(destination, opts);
        return run("drag", { label: from, to_label: to, ...args }, opts);
      },
      async scrollIntoViewIfNeeded(options) {
        const opts = checkOptions("locator.scrollIntoViewIfNeeded", options, LOCATOR_OPTIONS);
        return run("scroll_into_view", { label: await labelFor(desc, opts) }, opts);
      },
      // selectText("exact text") or selectText({ start, length }) in UTF-16 units, or { text, prefix, suffix }.
      async selectText(selection, options) {
        const opts = checkOptions("locator.selectText", options, SELECT_TEXT_OPTIONS);
        const args = selectionArgs(selection);
        return run("select_text", { label: await labelFor(desc, opts), ...args }, opts);
      },
    });
    locatorDescriptions.set(locator, desc);
    return locator;
  }

  function locatorFor(kind, name, options, method, role) {
    const opts = checkOptions(method, options, ["exact"]);
    return makeLocator({ kind, role, name: collapse(nonEmptyString(name, `${method} name`)), exact: opts.exact ?? true });
  }

  const page = {
    async goto(url, options) {
      const opts = checkOptions("goto", options, PAGE_OPTIONS);
      return run("go", { url: nonEmptyString(url, "goto url") }, opts);
    },

    async click(target, options) {
      const opts = checkOptions("click", options, CLICK_OPTIONS);
      return clickOf(describeTarget(target, "click", opts.exact ?? true), opts);
    },

    async fill(target, value, options) {
      const opts = checkOptions("fill", options, LABEL_OPTIONS);
      if (typeof value !== "string") throw invalid("fill value must be a string");
      return fillOf(describeTarget(target, "fill", opts.exact ?? true), value, opts);
    },

    async type(text, options) {
      const opts = checkOptions("type", options, TYPE_OPTIONS);
      if (typeof text !== "string") throw invalid("type text must be a string");
      const args = { text };
      if (opts.replace !== undefined) args.replace = opts.replace;
      return run("type", args, opts);
    },

    async press(key, options) {
      const opts = checkOptions("press", options, PAGE_OPTIONS);
      return run("key", { key: nonEmptyString(key, "press key") }, opts);
    },

    // Playwright-style keyboard: keyboard.press(key, { holdMs }) holds the key for up to 1000 ms.
    keyboard: Object.freeze({
      async press(key, options) {
        const opts = checkOptions("keyboard.press", options, KEY_OPTIONS);
        const args = opts.holdMs === undefined ? {} : { hold_ms: holdMs(opts.holdMs) };
        return run("key", { key: nonEmptyString(key, "keyboard.press key"), ...args }, opts);
      },
    }),

    // Playwright-style mouse: mouse.wheel(dx, dy) scrolls by points, one chunk per axis.
    mouse: Object.freeze({
      async wheel(dx, dy, options) {
        const opts = checkOptions("mouse.wheel", options, PAGE_OPTIONS);
        const chunks = wheelArgs(dx, dy);
        let text = "";
        for (const chunk of chunks) text = await run("scroll", chunk, opts);
        return text;
      },
    }),

    // scroll({ direction, unit, amount, maxSteps, untilVisible }): amount is the size of each chunk in
    // the chosen unit, and maxSteps caps the chunks (up to 20). untilVisible stops at that exact label.
    async scroll(options) {
      const opts = checkOptions("scroll", options, SCROLL_OPTIONS);
      const args = scrollArgs(opts, BROWSER_SCROLL_DIRECTIONS);
      return run("scroll", args, opts);
    },

    // zoom("in") or zoom("out") changes the page scale through the browser's gesture equivalent.
    async zoom(direction, options) {
      const opts = checkOptions("zoom", options, PAGE_OPTIONS);
      if (!Object.hasOwn(ZOOM_DIRECTIONS, direction)) throw invalid("zoom takes \"in\" or \"out\"");
      return run("gesture", { kind: ZOOM_DIRECTIONS[direction] }, opts);
    },

    async goBack(options) {
      return run("back", {}, checkOptions("goBack", options, PAGE_OPTIONS));
    },

    async goForward(options) {
      return run("forward", {}, checkOptions("goForward", options, PAGE_OPTIONS));
    },

    async hover(target, options) {
      const opts = checkOptions("hover", options, HOVER_OPTIONS);
      const desc = describeTarget(target, "hover", opts.exact ?? true);
      const args = opts.dwellMs === undefined ? {} : { dwell_ms: dwellMs(opts.dwellMs) };
      return run("hover", { label: await labelFor(desc, opts), ...args }, opts);
    },

    async selectOption(target, value, options) {
      const opts = checkOptions("selectOption", options, LABEL_OPTIONS);
      const desc = describeTarget(target, "selectOption", opts.exact ?? true);
      return run("select", { label: await labelFor(desc, opts), option: nonEmptyString(value, "option") }, opts);
    },

    async check(target, options) {
      const opts = checkOptions("check", options, LABEL_OPTIONS);
      const desc = describeTarget(target, "check", opts.exact ?? true);
      return run("check", { label: await labelFor(desc, opts) }, opts);
    },

    async uncheck(target, options) {
      const opts = checkOptions("uncheck", options, LABEL_OPTIONS);
      const desc = describeTarget(target, "uncheck", opts.exact ?? true);
      return run("uncheck", { label: await labelFor(desc, opts) }, opts);
    },

    async waitForText(text, options) {
      const opts = checkOptions("waitForText", options, WAIT_OPTIONS);
      const wanted = nonEmptyString(text, "waitForText text");
      return waitFor({ text: wanted }, waitSeconds(opts), `"${wanted}"`, opts);
    },

    async waitForURL(part, options) {
      const opts = checkOptions("waitForURL", options, WAIT_OPTIONS);
      const wanted = nonEmptyString(part, "waitForURL part");
      return waitFor({ url_contains: wanted }, waitSeconds(opts), `URL containing "${wanted}"`, opts);
    },

    async waitForLoadState(options) {
      const opts = checkOptions("waitForLoadState", options, WAIT_OPTIONS);
      const seconds = waitSeconds(opts);
      try {
        return await run("wait_load", { timeout: seconds }, opts);
      } catch (error) {
        // wait_load fails only when the page is still loading after its wait.
        if (error.code === "TOOL_ERROR" || error.code === "state_unavailable") {
          throw new BrowserPageError(`page still loading after ${seconds} s`, "TIMEOUT", { action: "wait_load", cause: error });
        }
        throw error;
      }
    },

    async textContent(options) {
      const opts = checkOptions("textContent", options, PAGE_OPTIONS);
      // The info action returns the title on its first line, then the page text.
      return (await run("info", {}, opts)).split("\n").slice(1).join("\n");
    },

    async title(options) {
      return field(await run("location", {}, checkOptions("title", options, PAGE_OPTIONS)), "Title");
    },

    async url(options) {
      return field(await run("location", {}, checkOptions("url", options, PAGE_OPTIONS)), "URL");
    },

    // Only on an explicit call: no other method takes a screenshot. The image is emitted to the REPL output.
    async screenshot(options) {
      return run("screenshot", {}, checkOptions("screenshot", options, PAGE_OPTIONS), { emit: true });
    },

    getByRole(role, options) {
      const opts = checkOptions("getByRole", options, ["name", "exact"]);
      if (opts.name === undefined) {
        throw unsupported("getByRole without a name is not supported: the browser finds controls by name. Pass { name }");
      }
      return makeLocator({
        kind: "role",
        role: nonEmptyString(role, "getByRole role").trim().toLowerCase(),
        name: collapse(nonEmptyString(opts.name, "getByRole name")),
        exact: opts.exact ?? true,
      });
    },

    getByLabel(label, options) {
      return locatorFor("label", label, options, "getByLabel");
    },

    getByText(text, options) {
      return locatorFor("text", text, options, "getByText");
    },

    locator() {
      throw unsupported("locator(selector) is not supported: the browser actions take visible labels, not CSS selectors; use getByRole, getByLabel or getByText");
    },

    evaluate() {
      throw unsupported("evaluate is not exposed; read the page with textContent(), title(), url() or cua.browser(\"read\")");
    },

    waitForSelector() {
      throw unsupported("waitForSelector is not supported; use waitForText(), waitForURL() or waitForLoadState()");
    },
  };
  return Object.freeze(page);
}
