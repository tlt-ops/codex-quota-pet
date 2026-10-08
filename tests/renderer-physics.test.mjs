import test from "node:test";
import assert from "node:assert/strict";
import {
  advanceBounce,
  advanceParticle,
  createProjectile,
  chargeForDuration,
  FADE_SECONDS,
} from "../desktop/renderer/physics.mjs";
import { removeEdgeWhite } from "../desktop/renderer/sprites.mjs";

const neutralRandom = () => 0.5;
function bounce(values = {}) {
  return {
    x: 0,
    y: 50,
    vx: -100,
    vy: 1,
    side: 10,
    bounceCount: 0,
    fadeAge: null,
    opacity: 1,
    dead: false,
    ...values,
  };
}

test("charge caps at 1.6 seconds and monotonically controls launch speed and angle", () => {
  assert.equal(chargeForDuration(-1), 0);
  assert.equal(chargeForDuration(0.8), 0.5);
  assert.equal(chargeForDuration(10), 1);
  const weak = createProjectile({ x: 200, y: 200 }, 0),
    strong = createProjectile({ x: 200, y: 200 }, 1);
  assert.ok(Math.hypot(strong.vx, strong.vy) > Math.hypot(weak.vx, weak.vy));
  assert.ok(Math.abs(strong.vy / strong.vx) > Math.abs(weak.vy / weak.vx));
});
test("contact integrates the remaining time and forces departure away from the wall", () => {
  const p = bounce();
  advanceBounce(p, 200, 200, 0.1, neutralRandom);
  assert.equal(p.bounceCount, 1);
  assert.ok(p.x > 0);
  assert.ok(
    p.vx / Math.hypot(p.vx, p.vy) >= Math.sin((18 * Math.PI) / 180) - 1e-9,
  );
});
test("corner contact counts as one rebound and leaves both edges", () => {
  const p = bounce({ y: 0, vx: -100, vy: -100 });
  advanceBounce(p, 200, 200, 0.1, neutralRandom);
  assert.equal(p.bounceCount, 1);
  assert.ok(p.x > 0 && p.y > 0);
  assert.ok(p.vx > 0 && p.vy > 0);
});
test("fifth rebound begins a 1.1 second fade while continuing beyond another edge", () => {
  const p = bounce({ bounceCount: 4, vx: -1000, vy: 0 });
  advanceBounce(p, 100, 100, 0.01, neutralRandom);
  assert.equal(p.bounceCount, 5);
  const x = p.x;
  advanceBounce(p, 100, 100, 0.3, neutralRandom);
  assert.equal(p.bounceCount, 5);
  assert.ok(p.x > x && p.x > 90);
  assert.ok(p.opacity > 0 && p.opacity < 1);
  advanceBounce(p, 100, 100, FADE_SECONDS, neutralRandom);
  assert.equal(p.dead, true);
});
test("partitioned motion agrees at contacts and no speed component sticks to the wall", () => {
  const one = bounce({ x: 50, y: 40, vx: 3000, vy: 510 }),
    parts = { ...one };
  advanceBounce(one, 800, 600, 0.3, neutralRandom);
  for (let i = 0; i < 30; i++)
    advanceBounce(parts, 800, 600, 0.01, neutralRandom);
  assert.equal(one.bounceCount, parts.bounceCount);
  assert.equal(one.bounceCount, 1);
  // Swift applies mild drag once per frame; substep positions differ slightly.
  assert.ok(Math.abs(one.x - parts.x) < 2 && Math.abs(one.y - parts.y) < 2);
  assert.ok(Math.abs(parts.vx) > 0 && Math.abs(parts.vy) > 0);
});
test("arc sprite disappears only when it clears the edge and never fades", () => {
  const p = createProjectile({ x: 100, y: 150 }, 0);
  p.x = -77;
  p.vx = -100;
  p.vy = 0;
  p.gravity = 0;
  advanceParticle(p, 800, 600, 0.005);
  assert.equal(p.dead, false);
  assert.equal(p.opacity, 1);
  advanceParticle(p, 800, 600, 0.02);
  assert.equal(p.dead, true);
  assert.equal(p.opacity, 1);
});
test("edge flood fill preserves white hair enclosed by a nonwhite outline", () => {
  const width = 5,
    height = 5,
    data = new Uint8ClampedArray(width * height * 4).fill(255);
  for (let y = 1; y < 4; y++)
    for (let x = 1; x < 4; x++)
      if (x !== 2 || y !== 2) {
        const offset = (y * width + x) * 4;
        data[offset] = data[offset + 1] = data[offset + 2] = 30;
      }
  removeEdgeWhite({ width, height, data });
  assert.equal(data[3], 0);
  assert.equal(data[(2 * width + 2) * 4 + 3], 255);
});
