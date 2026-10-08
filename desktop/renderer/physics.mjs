export const clamp = (value, low, high) => Math.min(high, Math.max(low, value));
export const MAX_CHARGE_SECONDS = 1.6;
export const MAX_BOUNCES = 5;
export const FADE_SECONDS = 1.1;
export const chargeForDuration = (seconds) =>
  clamp(seconds / MAX_CHARGE_SECONDS, 0, 1);

export function createProjectile(
  origin,
  charge = 0,
  mode = "arc",
  random = Math.random,
) {
  charge = clamp(charge, 0, 1);
  const bounce = mode === "bounce";
  const speed =
    (320 + 440 * charge) * (bounce ? 1.5 * (0.94 + random() * 0.12) : 1);
  const angle =
    ((30 + 40 * charge + (bounce ? random() * 12 - 6 : 0)) * Math.PI) / 180;
  const vy = -speed * Math.sin(angle);
  return {
    x: origin.x - 39,
    y: origin.y - 39,
    vx: -speed * Math.cos(angle),
    vy,
    side: 78,
    mode,
    gravity: bounce ? 0 : (-2 * vy) / (1 + 0.5 * charge),
    age: 0,
    bounceCount: 0,
    fadeAge: null,
    opacity: 1,
    dead: false,
  };
}

function reflect(p, hitX, hitY, random) {
  const oldX = p.vx,
    oldY = p.vy;
  const speed = Math.hypot(oldX, oldY) * (0.84 + random() * 0.1);
  const angle =
    Math.atan2(hitY ? -oldY : oldY, hitX ? -oldX : oldX) +
    ((random() * 18 - 9) * Math.PI) / 180;
  let x = speed * Math.cos(angle),
    y = speed * Math.sin(angle);
  const normal = speed * Math.sin((18 * Math.PI) / 180);
  if (hitX && hitY) {
    const mag = clamp(
      Math.abs(x),
      normal,
      speed * Math.cos((18 * Math.PI) / 180),
    );
    x = oldX > 0 ? -mag : mag;
    y = (oldY > 0 ? -1 : 1) * Math.sqrt(Math.max(0, speed * speed - mag * mag));
  } else if (hitX) {
    const mag = Math.max(Math.abs(x), normal);
    x = oldX > 0 ? -mag : mag;
    y = (y < 0 ? -1 : 1) * Math.sqrt(Math.max(0, speed * speed - mag * mag));
  } else if (hitY) {
    const mag = Math.max(Math.abs(y), normal);
    y = oldY > 0 ? -mag : mag;
    x = (x < 0 ? -1 : 1) * Math.sqrt(Math.max(0, speed * speed - mag * mag));
  }
  p.vx = x;
  p.vy = y;
  p.bounceCount++;
}

/** Integrate to contact, reflect, and consume the remaining frame time. */
export function advanceBounce(p, width, height, dt, random = Math.random) {
  if (!(dt > 0)) return p;
  const xmax = Math.max(0, width - p.side),
    ymax = Math.max(0, height - p.side);
  if (!xmax || !ymax) {
    p.dead = true;
    return p;
  }
  const drag = Math.exp(-0.008 * dt);
  p.vx *= drag;
  p.vy *= drag;
  if (p.bounceCount < MAX_BOUNCES) {
    p.x = clamp(p.x, 0, xmax);
    p.y = clamp(p.y, 0, ymax);
  }
  let remaining = dt;
  while (remaining > 1e-10) {
    if (p.bounceCount >= MAX_BOUNCES) {
      p.x += p.vx * remaining;
      p.y += p.vy * remaining;
      p.fadeAge = (p.fadeAge ?? 0) + remaining;
      break;
    }
    const tx =
      p.vx > 0 ? (xmax - p.x) / p.vx : p.vx < 0 ? -p.x / p.vx : Infinity;
    const ty =
      p.vy > 0 ? (ymax - p.y) / p.vy : p.vy < 0 ? -p.y / p.vy : Infinity;
    const contact = Math.max(0, Math.min(tx, ty));
    const travel = Math.min(contact, remaining);
    p.x += p.vx * travel;
    p.y += p.vy * travel;
    remaining -= travel;
    if (contact > travel || !Number.isFinite(contact)) break;
    const hitX = Math.abs(tx - contact) <= 1e-9,
      hitY = Math.abs(ty - contact) <= 1e-9;
    if (hitX) p.x = p.vx > 0 ? xmax : 0;
    if (hitY) p.y = p.vy > 0 ? ymax : 0;
    reflect(p, hitX, hitY, random);
    if (p.bounceCount === MAX_BOUNCES) p.fadeAge = 0;
  }
  p.opacity =
    p.fadeAge === null ? 1 : Math.max(0, 1 - p.fadeAge / FADE_SECONDS);
  p.dead = p.opacity <= 0;
  return p;
}

export function advanceParticle(p, width, height, dt, random = Math.random) {
  p.age += dt;
  if (p.mode === "bounce") return advanceBounce(p, width, height, dt, random);
  p.x += p.vx * dt;
  p.y += p.vy * dt + 0.5 * p.gravity * dt * dt;
  p.vy += p.gravity * dt;
  // Arc sprites disappear only once the entire sprite clears an edge.
  p.dead = p.x + p.side < 0 || p.x > width || p.y > height || p.y + p.side < 0;
  return p;
}

export function createRainParticle(width, random = Math.random) {
  const side = 35 + random() * 40;
  return {
    x: random() * Math.max(0, width - side),
    y: -side,
    vx: random() * 20 - 10,
    vy: 180 + random() * 120,
    side,
    gravity: 0,
    mode: "rain",
    age: 0,
    opacity: 1,
    dead: false,
  };
}
