import test from "node:test";
import assert from "node:assert/strict";
import { ClickSequence } from "../desktop/renderer/gestures.mjs";
const point = { x: 270, y: 240 };
const tap = (sequence, time, count = 0, origin = point) => [
  ...sequence.begin(time, origin, count),
  ...sequence.end(time + 0.05, origin, 0.05),
];

test("one quick tap launches after the quiet interval", () => {
  const sequence = new ClickSequence();
  assert.deepEqual(tap(sequence, 0), []);
  assert.deepEqual(sequence.resolve(0.4), []);
  assert.equal(sequence.resolve(0.6)[0].type, "launch");
});
test("exactly two quick taps open one wheel at the second point after quiet", () => {
  const sequence = new ClickSequence();
  tap(sequence, 0, 1);
  tap(sequence, 0.2, 2);
  assert.deepEqual(sequence.resolve(0.5), []);
  assert.deepEqual(sequence.resolve(0.8), [{ type: "wheel", origin: point }]);
});
test("triple and longer rapid sequences launch every tap and never show a wheel", () => {
  for (const count of [3, 4, 8]) {
    const sequence = new ClickSequence(),
      output = [];
    for (let i = 0; i < count; i++)
      output.push(...tap(sequence, i * 0.15, i + 1));
    output.push(...sequence.resolve(3));
    assert.equal(output.length, count);
    assert.ok(output.every((item) => item.type === "launch"));
  }
});
test("a third continuing click cancels a wheel even if its quiet timer ran late", () => {
  const sequence = new ClickSequence();
  tap(sequence, 0, 1);
  tap(sequence, 0.2, 2);
  const output = tap(sequence, 0.81, 3);
  assert.equal(output.length, 3);
  assert.ok(output.every((item) => item.type === "launch"));
});
test("long press immediately launches and releases buffered quick taps", () => {
  const sequence = new ClickSequence();
  tap(sequence, 0);
  sequence.begin(0.2, point);
  const output = sequence.end(0.9, point, 0.7);
  assert.equal(output.length, 2);
  assert.ok(output.every((item) => item.type === "launch"));
  assert.equal(output[1].duration, 0.7);
});
test("interruption and spatially separate clicks cannot create a wheel", () => {
  const sequence = new ClickSequence();
  tap(sequence, 0);
  const interrupted = sequence.interrupt(0.1);
  assert.equal(interrupted[0].type, "launch");
  const output = [...tap(sequence, 0.2), ...sequence.resolve(1)];
  assert.ok(output.every((item) => item.type === "launch"));
  const spatial = new ClickSequence();
  tap(spatial, 0);
  const far = [
    ...tap(spatial, 0.2, 0, { x: 310, y: 200 }),
    ...spatial.resolve(1),
  ];
  assert.equal(far.length, 2);
  assert.ok(far.every((item) => item.type === "launch"));
});
test("active presses cannot resolve a pending wheel", () => {
  const sequence = new ClickSequence();
  tap(sequence, 0);
  tap(sequence, 0.2);
  sequence.begin(0.4, point);
  assert.deepEqual(sequence.resolve(0.9), []);
});
