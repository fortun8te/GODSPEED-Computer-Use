// Shared argument mapping for the precise page and app actions.
//
// Each helper checks one JavaScript option against the driver's own limits (ToolDefinitions.swift)
// and returns the driver argument it maps to. Anything the driver cannot do throws UNSUPPORTED;
// a bad value throws INVALID_ARGUMENT. Nothing here sends a call, so a rejected action never reaches
// the native peer.

export class ActionArgumentError extends Error {
  constructor(message, code) {
    super(message);
    this.name = "ActionArgumentError";
    this.code = code;
  }
}

export const invalid = message => new ActionArgumentError(message, "INVALID_ARGUMENT");
export const unsupported = message => new ActionArgumentError(message, "UNSUPPORTED");

export const ANCHORS = Object.freeze(["center", "left", "right", "top", "bottom"]);
export const BUTTONS = Object.freeze(["left", "right", "middle"]);
export const SCROLL_UNITS = Object.freeze(["lines", "pages", "points"]);
export const SCROLL_DIRECTIONS = Object.freeze(["up", "down", "left", "right"]);
export const BROWSER_SCROLL_DIRECTIONS = Object.freeze([...SCROLL_DIRECTIONS, "top", "bottom"]);
export const WAIT_CONDITIONS = Object.freeze(["appears", "disappears", "value_changed"]);
export const GESTURES = Object.freeze([
  "pinch_in", "pinch_out", "zoom_in", "zoom_out", "smart_zoom", "rotate_left", "rotate_right", "swipe_back", "swipe_forward",
]);

// Limits from the driver schemas.
export const LIMITS = Object.freeze({
  dwellMs: [0, 2000],
  holdMs: [0, 1000],
  dragSteps: [2, 30],
  waitSeconds: [1, 30],
  maxSteps: [1, 20],
  clickCount: [1, 32],
  browserClickCount: [1, 3],
});

// Playwright names and the driver's own names both work. Anything else is refused.
const MODIFIERS = new Map([
  ["Meta", "cmd"], ["cmd", "cmd"],
  ["Control", "ctrl"], ["ctrl", "ctrl"],
  ["Alt", "alt"], ["alt", "alt"],
  ["Shift", "shift"], ["shift", "shift"],
]);

export function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function integerIn(value, what, [min, max]) {
  if (!Number.isSafeInteger(value) || value < min || value > max) {
    throw invalid(`${what} must be a whole number from ${min} to ${max}`);
  }
  return value;
}

function finite(value, what) {
  if (typeof value !== "number" || !Number.isFinite(value)) throw invalid(`${what} must be a finite number`);
  return value;
}

export function nonEmpty(value, what) {
  if (typeof value !== "string" || !value.trim()) throw invalid(`${what} must be a nonempty string`);
  return value;
}

export function modifiers(list) {
  if (!Array.isArray(list)) throw invalid("modifiers must be an array such as [\"Meta\"] or [\"Shift\"]");
  return list.map(name => {
    const driver = MODIFIERS.get(name);
    if (!driver) throw invalid(`unknown modifier "${name}"; use Meta, Shift, Alt or Control`);
    return driver;
  });
}

export function dwellMs(value) {
  return integerIn(value, "dwellMs", LIMITS.dwellMs);
}

export function holdMs(value) {
  return integerIn(value, "holdMs", LIMITS.holdMs);
}

export function dragSteps(value) {
  return integerIn(value, "steps", LIMITS.dragSteps);
}

export function anchorAndOffset({ anchor, offset }) {
  const args = {};
  if (anchor !== undefined) {
    if (!ANCHORS.includes(anchor)) throw invalid(`anchor must be ${ANCHORS.join(", ")}`);
    args.anchor = anchor;
  }
  if (offset !== undefined) {
    if (!isPlainObject(offset)) throw invalid("offset must be an object such as { x: 4, y: 0 }");
    args.offset_x = finite(offset.x, "offset.x");
    args.offset_y = finite(offset.y, "offset.y");
  }
  return args;
}

function button(value) {
  if (!BUTTONS.includes(value)) throw invalid(`button must be ${BUTTONS.join(", ")}`);
  return value;
}

// Browser click: a label with anchor, offset, modifiers, button and click count. The browser click
// has no coordinates, so a position is refused rather than guessed at.
export function browserClickArgs(options) {
  if (options.position !== undefined) {
    if (!isPlainObject(options.position)) throw invalid("position must be an object such as { x: 10, y: 4 }");
    finite(options.position.x, "position.x");
    finite(options.position.y, "position.y");
    throw unsupported("click position {x, y} is not supported by the browser click; use anchor and offset on the control");
  }
  const args = anchorAndOffset(options);
  if (options.modifiers !== undefined) args.modifiers = modifiers(options.modifiers);
  if (options.button !== undefined) args.mouse_button = button(options.button);
  if (options.clickCount !== undefined) {
    const count = integerIn(options.clickCount, "clickCount", LIMITS.browserClickCount);
    if (count > 1 && args.mouse_button !== undefined && args.mouse_button !== "left") {
      throw invalid("clickCount 2 or 3 needs the left button");
    }
    args.click_count = count;
  }
  return args;
}

// Native click. Screenshot coordinates (an array target) cannot take an anchor or offset: the driver
// anchors only to a control.
export function nativeClickArgs(options, { coordinates = false } = {}) {
  const args = anchorAndOffset(options);
  if (coordinates && (args.anchor !== undefined || args.offset_x !== undefined)) {
    throw unsupported("anchor and offset need a control target, not screenshot coordinates");
  }
  if (options.modifiers !== undefined) args.modifiers = modifiers(options.modifiers);
  if (options.button !== undefined) args.mouse_button = button(options.button);
  if (options.clickCount !== undefined) args.click_count = integerIn(options.clickCount, "clickCount", LIMITS.clickCount);
  return args;
}

// verify: { label, condition, fromValue?, timeout? }. The timeout is in seconds, as the driver takes it.
export function verifyArgs(verify) {
  if (!isPlainObject(verify)) throw invalid("verify must be an object such as { label: \"Card A\", condition: \"appears\" }");
  for (const key of Object.keys(verify)) {
    if (!["label", "condition", "fromValue", "timeout"].includes(key)) throw invalid(`verify option "${key}" is not supported`);
  }
  const args = { label: nonEmpty(verify.label, "verify.label") };
  if (!WAIT_CONDITIONS.includes(verify.condition)) throw invalid(`verify.condition must be ${WAIT_CONDITIONS.join(", ")}`);
  args.condition = verify.condition;
  if (verify.fromValue !== undefined) {
    if (verify.condition !== "value_changed") throw invalid("verify.fromValue only applies to condition value_changed");
    if (typeof verify.fromValue !== "string") throw invalid("verify.fromValue must be a string");
    args.from_value = verify.fromValue;
  }
  if (verify.timeout !== undefined) args.timeout = integerIn(verify.timeout, "verify.timeout (seconds)", LIMITS.waitSeconds);
  return args;
}

// Scroll chunks. `amount` is the size of each chunk in the chosen unit; `maxSteps` caps the chunks.
// Callers refuse unknown option keys before calling this.
export function scrollArgs({ direction, unit, amount, maxSteps, untilVisible }, directions) {
  if (!directions.includes(direction)) throw invalid(`direction must be ${directions.join(", ")}`);
  const args = { direction };
  if (unit !== undefined) {
    if (!SCROLL_UNITS.includes(unit)) throw invalid(`unit must be ${SCROLL_UNITS.join(", ")}`);
    args.unit = unit;
  }
  if (amount !== undefined) {
    if (unit === undefined) throw invalid("amount needs a unit: lines, pages or points");
    const size = integerIn(amount, "amount", [1, Number.MAX_SAFE_INTEGER]);
    if (unit === "pages" && size !== 1) throw invalid("amount must be 1 for pages: one page is one viewport chunk");
    args.step_size = size;
  }
  if (maxSteps !== undefined) args.max_steps = integerIn(maxSteps, "maxSteps", LIMITS.maxSteps);
  if (untilVisible !== undefined) args.until_visible = nonEmpty(untilVisible, "untilVisible");
  return args;
}

// A mouse wheel turn in points: one vertical chunk and one horizontal chunk, each a single step.
export function wheelArgs(dx = 0, dy = 0) {
  const vertical = wheelDelta(dy, "dy", "down", "up");
  const horizontal = wheelDelta(dx, "dx", "right", "left");
  return [vertical, horizontal].filter(Boolean);
}

function wheelDelta(delta, what, positive, negative) {
  const value = finite(delta, what);
  if (!Number.isInteger(value)) throw invalid(`${what} must be whole points`);
  if (value === 0) return null;
  return { direction: value > 0 ? positive : negative, unit: "points", step_size: Math.abs(value), max_steps: 1 };
}

export function gestureKind(name) {
  if (!GESTURES.includes(name)) throw invalid(`gesture must be ${GESTURES.join(", ")}`);
  return name;
}

export function waitCondition(condition = "appears") {
  if (!WAIT_CONDITIONS.includes(condition)) throw invalid(`condition must be ${WAIT_CONDITIONS.join(", ")}`);
  return condition;
}

export function waitTimeout(timeout) {
  return integerIn(timeout, "timeout (seconds)", LIMITS.waitSeconds);
}

// The locator.selectText argument: exact text, a UTF-16 range, or text with a prefix or suffix.
export function selectionArgs(selection) {
  if (typeof selection === "string") return { text: nonEmpty(selection, "selectText text") };
  if (!isPlainObject(selection)) throw invalid("selectText takes a string or an object such as { start, length }");
  for (const key of Object.keys(selection)) {
    if (!["start", "length", "text", "prefix", "suffix"].includes(key)) throw invalid(`selectText option "${key}" is not supported`);
  }
  const max = Number.MAX_SAFE_INTEGER;
  if (selection.start !== undefined || selection.length !== undefined) {
    if (selection.text !== undefined || selection.prefix !== undefined || selection.suffix !== undefined) {
      throw invalid("a range takes start and length, not text, prefix or suffix");
    }
    if (selection.start === undefined || selection.length === undefined) throw invalid("a range needs both start and length");
    return { start: integerIn(selection.start, "start", [0, max]), length: integerIn(selection.length, "length", [0, max]) };
  }
  if (selection.text === undefined) throw invalid("selectText needs text, or a start and length");
  const args = { text: nonEmpty(selection.text, "selectText text") };
  for (const key of ["prefix", "suffix"]) {
    if (selection[key] === undefined) continue;
    if (typeof selection[key] !== "string") throw invalid(`${key} must be a string`);
    args[key] = selection[key];
  }
  return args;
}
