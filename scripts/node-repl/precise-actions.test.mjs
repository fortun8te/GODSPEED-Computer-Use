import assert from "node:assert/strict";
import test from "node:test";
import * as precise from "./precise-actions.mjs";

const {
  anchorAndOffset, browserClickArgs, dragSteps, dwellMs, gestureKind, holdMs, modifiers, nativeClickArgs, scrollArgs,
  selectionArgs, verifyArgs, waitCondition, waitTimeout, wheelArgs, BROWSER_SCROLL_DIRECTIONS, SCROLL_DIRECTIONS,
} = precise;

test("modifiers accept Playwright and driver names and refuse anything else", () => {
  assert.deepEqual(modifiers(["Meta", "Control", "Alt", "Shift"]), ["cmd", "ctrl", "alt", "shift"]);
  assert.deepEqual(modifiers(["cmd", "shift"]), ["cmd", "shift"]);
  assert.throws(() => modifiers(["Super"]), { code: "INVALID_ARGUMENT" });
  assert.throws(() => modifiers("Shift"), { code: "INVALID_ARGUMENT" });
});

test("dwell, hold, drag steps and wait limits match the driver schemas", () => {
  assert.equal(dwellMs(0), 0);
  assert.equal(dwellMs(2000), 2000);
  assert.throws(() => dwellMs(2001), { code: "INVALID_ARGUMENT" });
  assert.throws(() => dwellMs(-1), { code: "INVALID_ARGUMENT" });
  assert.throws(() => dwellMs(1.5), { code: "INVALID_ARGUMENT" });

  assert.equal(holdMs(1000), 1000);
  assert.throws(() => holdMs(1001), { code: "INVALID_ARGUMENT" });

  assert.equal(dragSteps(2), 2);
  assert.equal(dragSteps(30), 30);
  assert.throws(() => dragSteps(1), { code: "INVALID_ARGUMENT" });
  assert.throws(() => dragSteps(31), { code: "INVALID_ARGUMENT" });

  assert.equal(waitTimeout(1), 1);
  assert.equal(waitTimeout(30), 30);
  assert.throws(() => waitTimeout(0), { code: "INVALID_ARGUMENT" });
  assert.throws(() => waitTimeout(31), { code: "INVALID_ARGUMENT" });
  assert.throws(() => waitTimeout(2.5), { code: "INVALID_ARGUMENT" });
});

test("anchor and offset map to the driver names and reject other values", () => {
  assert.deepEqual(anchorAndOffset({ anchor: "top", offset: { x: 2, y: -3 } }), { anchor: "top", offset_x: 2, offset_y: -3 });
  assert.deepEqual(anchorAndOffset({}), {});
  assert.throws(() => anchorAndOffset({ anchor: "middle" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => anchorAndOffset({ offset: "2,3" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => anchorAndOffset({ offset: { x: "1", y: 0 } }), { code: "INVALID_ARGUMENT" });
});

test("browser click maps button, count, modifiers and anchor, and refuses a position", () => {
  assert.deepEqual(
    browserClickArgs({ button: "left", clickCount: 3, modifiers: ["Meta"], anchor: "center", offset: { x: 1, y: 1 } }),
    { anchor: "center", offset_x: 1, offset_y: 1, modifiers: ["cmd"], mouse_button: "left", click_count: 3 },
  );
  assert.deepEqual(browserClickArgs({}), {});
  assert.throws(() => browserClickArgs({ button: "right", clickCount: 2 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => browserClickArgs({ clickCount: 4 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => browserClickArgs({ position: { x: 1, y: 2 } }), { code: "UNSUPPORTED" });
  assert.throws(() => browserClickArgs({ position: { x: "a", y: 2 } }), { code: "INVALID_ARGUMENT" });
});

test("native click maps its options and refuses an anchor on screenshot coordinates", () => {
  assert.deepEqual(
    nativeClickArgs({ button: "right", clickCount: 32, anchor: "left", modifiers: ["Control"] }),
    { anchor: "left", modifiers: ["ctrl"], mouse_button: "right", click_count: 32 },
  );
  assert.throws(() => nativeClickArgs({ clickCount: 33 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => nativeClickArgs({ button: "side" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => nativeClickArgs({ anchor: "left" }, { coordinates: true }), { code: "UNSUPPORTED" });
  assert.throws(() => nativeClickArgs({ offset: { x: 1, y: 0 } }, { coordinates: true }), { code: "UNSUPPORTED" });
  assert.deepEqual(nativeClickArgs({ modifiers: ["Shift"] }, { coordinates: true }), { modifiers: ["shift"] });
});

test("verify maps to the driver's drop check and refuses unknown conditions", () => {
  assert.deepEqual(verifyArgs({ label: "Card A", condition: "appears" }), { label: "Card A", condition: "appears" });
  assert.deepEqual(
    verifyArgs({ label: "Count", condition: "value_changed", fromValue: "2", timeout: 5 }),
    { label: "Count", condition: "value_changed", from_value: "2", timeout: 5 },
  );
  assert.throws(() => verifyArgs({ label: "Card A", condition: "visible" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => verifyArgs({ condition: "appears" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => verifyArgs({ label: "A", condition: "appears", fromValue: "x" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => verifyArgs({ label: "A", condition: "appears", timeout: 31 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => verifyArgs({ label: "A", condition: "appears", typo: 1 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => verifyArgs("A"), { code: "INVALID_ARGUMENT" });
});

test("scroll chunks map to the driver's unit, step, cap and label fields", () => {
  assert.deepEqual(
    scrollArgs({ direction: "down", unit: "lines", amount: 3, maxSteps: 4, untilVisible: "Total" }, SCROLL_DIRECTIONS),
    { direction: "down", unit: "lines", step_size: 3, max_steps: 4, until_visible: "Total" },
  );
  assert.deepEqual(scrollArgs({ direction: "up" }, SCROLL_DIRECTIONS), { direction: "up" });
  assert.deepEqual(scrollArgs({ direction: "down", unit: "pages", amount: 1 }, SCROLL_DIRECTIONS), { direction: "down", unit: "pages", step_size: 1 });
  assert.deepEqual(scrollArgs({ direction: "top", unit: "points", amount: 10 }, BROWSER_SCROLL_DIRECTIONS).direction, "top");
  assert.throws(() => scrollArgs({ direction: "top" }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
  assert.throws(() => scrollArgs({ direction: "down", unit: "pages", amount: 2 }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
  assert.throws(() => scrollArgs({ direction: "down", amount: 2 }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
  assert.throws(() => scrollArgs({ direction: "down", unit: "rows" }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
  assert.throws(() => scrollArgs({ direction: "down", maxSteps: 0 }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
  assert.throws(() => scrollArgs({ direction: "down", maxSteps: 21 }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
  assert.throws(() => scrollArgs({ direction: "down", untilVisible: "" }, SCROLL_DIRECTIONS), { code: "INVALID_ARGUMENT" });
});

test("a mouse wheel turn becomes one point chunk per axis, vertical first", () => {
  assert.deepEqual(wheelArgs(0, 120), [{ direction: "down", unit: "points", step_size: 120, max_steps: 1 }]);
  assert.deepEqual(wheelArgs(0, -40), [{ direction: "up", unit: "points", step_size: 40, max_steps: 1 }]);
  assert.deepEqual(wheelArgs(30, 0), [{ direction: "right", unit: "points", step_size: 30, max_steps: 1 }]);
  assert.deepEqual(wheelArgs(-10, -5).map(chunk => chunk.direction), ["up", "left"]);
  assert.deepEqual(wheelArgs(), []);
  assert.throws(() => wheelArgs(0, 1.5), { code: "INVALID_ARGUMENT" });
  assert.throws(() => wheelArgs(Number.NaN, 0), { code: "INVALID_ARGUMENT" });
});

test("gesture kinds, wait conditions and selection arguments are checked before use", () => {
  assert.equal(gestureKind("zoom_in"), "zoom_in");
  assert.equal(gestureKind("rotate_left"), "rotate_left");
  assert.throws(() => gestureKind("tap"), { code: "INVALID_ARGUMENT" });

  assert.equal(waitCondition(), "appears");
  assert.equal(waitCondition("value_changed"), "value_changed");
  assert.throws(() => waitCondition("visible"), { code: "INVALID_ARGUMENT" });

  assert.deepEqual(selectionArgs("Total"), { text: "Total" });
  assert.deepEqual(selectionArgs({ start: 0, length: 0 }), { start: 0, length: 0 });
  assert.deepEqual(selectionArgs({ text: "cart", prefix: "the ", suffix: "!" }), { text: "cart", prefix: "the ", suffix: "!" });
  assert.throws(() => selectionArgs({ start: 1 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs({ start: -1, length: 1 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs({ start: 1, length: 2, text: "x" }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs({ text: "x", prefix: 2 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs({}), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs({ typo: 1 }), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs(3), { code: "INVALID_ARGUMENT" });
  assert.throws(() => selectionArgs(""), { code: "INVALID_ARGUMENT" });
});
