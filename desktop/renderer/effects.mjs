import {
  createProjectile,
  createRainParticle,
  advanceParticle,
  clamp,
} from "./physics.mjs";
import { loadSprites } from "./sprites.mjs";

const canvas = document.querySelector("#effects"),
  context = canvas.getContext("2d");
const api = window.pet;
const MAX_PARTICLES = 300,
  RAIN_DURATION = 10,
  RAIN_RATE = 48;
let width = innerWidth,
  height = innerHeight,
  sprites = [],
  particles = [],
  assetVersion = 0;
let sheetURL = null,
  rainRemaining = 0,
  rainAccumulator = 0,
  lastTime = performance.now(),
  frameHandle = null;
const pending = [];
function resize() {
  width = innerWidth;
  height = innerHeight;
  const ratio = Math.min(devicePixelRatio || 1, 2);
  canvas.width = Math.round(width * ratio);
  canvas.height = Math.round(height * ratio);
  context.setTransform(ratio, 0, 0, ratio, 0, 0);
}
resize();
addEventListener("resize", resize);
async function acceptState(state) {
  const url =
    state.skin?.sheetURL ?? "../../assets/mini_gpt_sheet_original.png";
  if (url === sheetURL && sprites.length) return;
  sheetURL = url;
  const version = ++assetVersion,
    loaded = await loadSprites(url);
  if (version !== assetVersion) return;
  sprites = loaded;
  for (const event of pending.splice(0)) effect(event);
}
function add(particle, random = Math.random) {
  if (particles.length >= MAX_PARTICLES) return;
  particle.sprite = Math.floor(random() * sprites.length);
  particles.push(particle);
}
function effect(event) {
  if (event.type === "clear") {
    particles = [];
    rainRemaining = 0;
    rainAccumulator = 0;
    draw();
    return;
  }
  if (event.type === "sound") return;
  if (!sprites.length) {
    if (pending.length < 50) pending.push(event);
    return;
  }
  if (event.type === "launch") {
    const origin = {
      x: Number.isFinite(event.origin?.x) ? event.origin.x : width / 2,
      y: Number.isFinite(event.origin?.y) ? event.origin.y : height / 2,
    };
    add(
      createProjectile(
        origin,
        clamp(Number(event.charge) || 0, 0, 1),
        event.mode === "bounce" ? "bounce" : "arc",
      ),
    );
  } else if (event.type === "rain") {
    rainRemaining = RAIN_DURATION;
    rainAccumulator = 0;
    for (let i = 0; i < 8; i++) add(createRainParticle(width));
  }
}
function draw() {
  context.clearRect(0, 0, width, height);
  for (const p of particles) {
    const sprite = sprites[p.sprite];
    if (!sprite) continue;
    context.globalAlpha = p.opacity;
    context.drawImage(sprite, p.x, p.y, p.side, p.side);
  }
  context.globalAlpha = 1;
}
function tick(time) {
  // Substeps preserve motion after a delayed frame or an unfocused window.
  const realElapsed = Math.max(0, (time - lastTime) / 1000);
  lastTime = time;
  if (rainRemaining > 0) {
    const spawnTime = Math.min(rainRemaining, realElapsed);
    rainRemaining = Math.max(0, rainRemaining - realElapsed);
    // A resumed renderer never emits a large backlog from a sleep/pause.
    rainAccumulator += Math.min(spawnTime, 0.5) * RAIN_RATE;
    while (rainAccumulator >= 1) {
      add(createRainParticle(width));
      rainAccumulator--;
    }
  }
  let elapsed = Math.min(realElapsed, 0.5);
  while (elapsed > 0) {
    const dt = Math.min(elapsed, 1 / 60);
    elapsed -= dt;
    for (const particle of particles)
      advanceParticle(particle, width, height, dt);
    particles = particles.filter((p) => !p.dead);
  }
  draw();
  frameHandle = requestAnimationFrame(tick);
}
api?.onState((state) =>
  acceptState(state).catch((error) =>
    console.error("Sprite load failed:", error.message),
  ),
);
api?.onEffect(effect);
window.__effectsReady = (async () => {
  try {
    await acceptState(api ? await api.getState() : {});
  } catch (error) {
    console.error("Sprite load failed:", error.message);
  }
  return sprites.length;
})();
frameHandle = requestAnimationFrame(tick);

/** Frozen deterministic snapshots allow capture without affecting live IPC state. */
window.__effectsSmoke = async (step = "arc") => {
  await window.__effectsReady;
  cancelAnimationFrame(frameHandle);
  particles = [];
  rainRemaining = 0;
  let seed = 731;
  const random = () => {
    seed = (seed * 1664525 + 1013904223) >>> 0;
    return seed / 4294967296;
  };
  if (step === "rain") {
    for (let i = 0; i < 120; i++) {
      const p = createRainParticle(width, random);
      p.y = random() * height - p.side;
      add(p, random);
    }
  } else if (step === "arc" || step === "bounce") {
    for (let i = 0; i < 14; i++) {
      const p = createProjectile(
        { x: width * 0.72, y: height * 0.72 },
        i / 13,
        step,
        random,
      );
      for (let frame = 0; frame < i * 4; frame++)
        advanceParticle(p, width, height, 1 / 60, random);
      if (!p.dead) add(p, random);
    }
  }
  draw();
  return {
    step,
    assetsLoaded: sprites.length === 24,
    spriteCount: sprites.length,
    particleCount: particles.length,
    maxParticles: MAX_PARTICLES,
    width,
    height,
  };
};
window.__effectsResume = () => {
  cancelAnimationFrame(frameHandle);
  lastTime = performance.now();
  frameHandle = requestAnimationFrame(tick);
};
if (new URLSearchParams(location.search).has("smoke"))
  window.__effectsReady.then(() =>
    window.__effectsSmoke(
      new URLSearchParams(location.search).get("step") ?? "rain",
    ),
  );
