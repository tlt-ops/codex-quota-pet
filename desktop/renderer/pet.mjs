import { ClickSequence } from "./gestures.mjs";
import { clamp, chargeForDuration } from "./physics.mjs";
import { loadImage } from "./sprites.mjs";

const api = window.pet;
const canvas = document.querySelector("#portrait"),
  context = canvas.getContext("2d");
const quota = document.querySelector("#quota"),
  wheel = document.querySelector("#wheel");
const menu = document.querySelector("#bubble-menu"),
  notice = document.querySelector("#notice");
const sequence = new ClickSequence();
const actions = [
  ["show", ["显示"]],
  ["refresh", ["刷新额度"]],
  ["rain", ["GPT 雨"]],
  ["arc", ["抛物线"]],
  ["bounce", ["弹射"]],
  ["testXP", ["测试", "经验音"]],
  ["testDamage", ["测试", "受击音"]],
  ["quit", ["退出"]],
  ["autoOpen", ["自动打开"]],
  ["hide", ["隐藏"]],
];
let state = {
  mode: "arc",
  autoOpen: true,
  snapshot: { lines: ["正在读取额度…"] },
  skin: {},
};
let character = null,
  bubble = null,
  hitPixels = null,
  pointer = null,
  timer = null,
  lastHit = null;
let assetVersion = 0,
  pressFrame = null,
  meshStrength = 0,
  soundTail = Promise.resolve();
const now = () => performance.now() / 1000;
const pointFor = (event) => {
  const r = canvas.getBoundingClientRect();
  return { x: event.clientX - r.left, y: event.clientY - r.top };
};

function bubblePath() {
  const path = new Path2D(),
    scale = 400 / 1254;
  for (const [x, y, w, h] of [
    [26, 54, 732, 467],
    [268, 521, 98, 80],
    [352, 591, 79, 72],
  ]) {
    path.ellipse(
      (x + w / 2) * scale,
      8 + (y + h / 2) * scale,
      (w * scale) / 2,
      (h * scale) / 2,
      0,
      0,
      Math.PI * 2,
    );
  }
  return path;
}
const fixedBubblePath = bubblePath();
function isBubble(point) {
  return context.isPointInPath(fixedBubblePath, point.x, point.y);
}
function isCharacter(point) {
  const x = Math.floor(point.x),
    y = Math.floor(point.y);
  return (
    x >= 0 &&
    y >= 0 &&
    x < 400 &&
    y < 400 &&
    !isBubble(point) &&
    Boolean(hitPixels?.[(y * 400 + x) * 4 + 3] > 20)
  );
}
function updateHit(point) {
  const hit =
    !wheel.hidden ||
    !menu.hidden ||
    Boolean(pointer) ||
    isBubble(point) ||
    isCharacter(point);
  if (hit !== lastHit) {
    lastHit = hit;
    api?.setHitRegion(hit);
  }
}

function showError(error) {
  notice.textContent = String(error?.message ?? error);
  notice.hidden = false;
  setTimeout(() => {
    notice.hidden = true;
  }, 5000);
}
async function action(name, payload) {
  closeMenus();
  try {
    if (!api) throw new Error("桌宠服务未连接");
    const result = await api.action(name, payload);
    if (result?.ok === false)
      throw new Error(result.error ?? result.message ?? "操作失败");
    return result;
  } catch (error) {
    showError(error);
  }
}
function closeMenus() {
  wheel.hidden = true;
  menu.hidden = true;
  updateHit(pointer?.point ?? { x: -1, y: -1 });
}
function renderText() {
  const lines = Array.isArray(state.snapshot?.lines)
    ? state.snapshot.lines.slice(0, 3)
    : ["正在读取额度…"];
  quota.replaceChildren(
    ...lines.map((line) => {
      const element = document.createElement("div");
      element.className = "quota-line";
      element.textContent = String(line).replace(/\s*\n\s*/g, " ");
      element.title = String(line);
      return element;
    }),
  );
  quota.classList.toggle("single", lines.length === 1);
  quota.classList.toggle("error", state.snapshot?.status === "error");
  quota.title = state.snapshot?.detail ?? "";
}
async function loadPortrait(url) {
  const version = ++assetVersion,
    image = await loadImage(url);
  if (version !== assetVersion) return;
  const full = document.createElement("canvas");
  full.width = full.height = 400;
  const fullContext = full.getContext("2d");
  fullContext.drawImage(image, 0, 8, 400, 400);
  bubble = document.createElement("canvas");
  bubble.width = bubble.height = 400;
  const bubbleContext = bubble.getContext("2d");
  bubbleContext.save();
  bubbleContext.clip(fixedBubblePath);
  bubbleContext.drawImage(full, 0, 0);
  bubbleContext.restore();
  character = document.createElement("canvas");
  character.width = character.height = 400;
  const charContext = character.getContext("2d", { willReadFrequently: true });
  charContext.drawImage(full, 0, 0);
  charContext.save();
  charContext.clip(fixedBubblePath);
  charContext.clearRect(0, 0, 400, 400);
  charContext.restore();
  hitPixels = charContext.getImageData(0, 0, 400, 400).data;
  draw();
}

function triangle(source, target) {
  const [s0, s1, s2] = source,
    [d0, d1, d2] = target;
  const sx1 = s1.x - s0.x,
    sy1 = s1.y - s0.y,
    sx2 = s2.x - s0.x,
    sy2 = s2.y - s0.y;
  const dx1 = d1.x - d0.x,
    dy1 = d1.y - d0.y,
    dx2 = d2.x - d0.x,
    dy2 = d2.y - d0.y;
  const determinant = sx1 * sy2 - sx2 * sy1;
  const a = (dx1 * sy2 - dx2 * sy1) / determinant,
    c = (sx1 * dx2 - sx2 * dx1) / determinant;
  const b = (dy1 * sy2 - dy2 * sy1) / determinant,
    d = (sx1 * dy2 - sx2 * dy1) / determinant;
  const center = { x: (d0.x + d1.x + d2.x) / 3, y: (d0.y + d1.y + d2.y) / 3 };
  // Slight overlap covers antialiased mesh seams without changing silhouettes.
  const expanded = target.map((p) => {
    const length = Math.hypot(p.x - center.x, p.y - center.y);
    return {
      x: p.x + ((p.x - center.x) / length) * 0.35,
      y: p.y + ((p.y - center.y) / length) * 0.35,
    };
  });
  context.save();
  context.beginPath();
  context.moveTo(expanded[0].x, expanded[0].y);
  context.lineTo(expanded[1].x, expanded[1].y);
  context.lineTo(expanded[2].x, expanded[2].y);
  context.closePath();
  context.clip();
  context.transform(
    a,
    b,
    c,
    d,
    d0.x - a * s0.x - c * s0.y,
    d0.y - b * s0.x - d * s0.y,
  );
  context.drawImage(character, 0, 0);
  context.restore();
}
function drawMesh(center, strength) {
  const steps = 24,
    cell = 400 / steps,
    radius = (170 * 400) / 1254;
  const x0 = clamp(Math.floor((center.x - radius) / cell), 0, steps - 1),
    x1 = clamp(Math.ceil((center.x + radius) / cell), 1, steps);
  const y0 = clamp(Math.floor((center.y - radius) / cell), 0, steps - 1),
    y1 = clamp(Math.ceil((center.y + radius) / cell), 1, steps);
  context.drawImage(character, 0, 0);
  context.clearRect(x0 * cell, y0 * cell, (x1 - x0) * cell, (y1 - y0) * cell);
  const deform = (p) => {
    if (p.x > 400 - (14 * 400) / 1254 || p.y > 408 - (30 * 400) / 1254)
      return p;
    const distance = Math.hypot(p.x - center.x, p.y - center.y);
    const contraction =
      distance < radius ? strength * (1 - distance / radius) ** 2 : 0;
    return {
      x: center.x + (p.x - center.x) * (1 - contraction),
      y: center.y + (p.y - center.y) * (1 - contraction),
    };
  };
  for (let y = y0; y < y1; y++)
    for (let x = x0; x < x1; x++) {
      const a = { x: x * cell, y: y * cell },
        b = { x: (x + 1) * cell, y: y * cell };
      const c = { x: (x + 1) * cell, y: (y + 1) * cell },
        d = { x: x * cell, y: (y + 1) * cell };
      for (const vertices of [
        [a, b, c],
        [a, c, d],
      ])
        triangle(vertices, vertices.map(deform));
    }
}
function draw(
  pressedPoint = pointer?.kind === "character" ? pointer.point : null,
  strength = meshStrength,
) {
  context.clearRect(0, 0, 400, 400);
  if (!character) return;
  if (pressedPoint && strength > 0) drawMesh(pressedPoint, strength);
  else context.drawImage(character, 0, 0);
  // The fixed layer is painted after the character mesh on every frame.
  context.save();
  context.clip(fixedBubblePath);
  context.clearRect(0, 0, 400, 400);
  context.restore();
  context.drawImage(bubble, 0, 0);
}
function animatePress() {
  if (pointer?.kind !== "character") return;
  meshStrength = 0.06 + 0.22 * chargeForDuration(now() - pointer.start);
  draw();
  pressFrame = requestAnimationFrame(animatePress);
}
function showWheel(point = { x: 220, y: 220 }) {
  menu.hidden = true;
  wheel.replaceChildren();
  wheel.hidden = false;
  const center = { x: clamp(point.x, 176, 224), y: clamp(point.y, 176, 224) };
  const disc = document.createElement("div");
  disc.className = "wheel-disc";
  disc.style.left = `${center.x - 174}px`;
  disc.style.top = `${center.y - 174}px`;
  wheel.append(disc);
  actions.forEach(([name, labels], index) => {
    const angle = -Math.PI / 2 + (index * Math.PI * 2) / 10;
    const spoke = document.createElement("div");
    spoke.className = "wheel-spoke";
    spoke.style.left = `${center.x}px`;
    spoke.style.top = `${center.y}px`;
    spoke.style.transform = `rotate(${angle}rad)`;
    wheel.append(spoke);
    const button = document.createElement("button");
    button.className = "wheel-button";
    button.dataset.action = name;
    button.setAttribute("role", "menuitem");
    button.setAttribute("aria-label", labels.join(""));
    button.classList.toggle("selected", name === state.mode);
    button.style.left = `${center.x + Math.cos(angle) * 141 - 32}px`;
    button.style.top = `${center.y + Math.sin(angle) * 141 - 32}px`;
    for (const label of labels) {
      const span = document.createElement("span");
      span.textContent = label;
      button.append(span);
    }
    if (name === "autoOpen") {
      const small = document.createElement("small");
      small.textContent = state.autoOpen ? "已开启" : "已关闭";
      button.append(small);
    }
    button.addEventListener("click", () => action(name));
    wheel.append(button);
  });
  const hub = document.createElement("button");
  hub.className = "wheel-hub";
  hub.textContent = "收起";
  hub.style.left = `${center.x - 28}px`;
  hub.style.top = `${center.y - 28}px`;
  hub.addEventListener("click", closeMenus);
  wheel.append(hub);
  updateHit(center);
}
function showBubbleMenu(point) {
  wheel.hidden = true;
  menu.replaceChildren();
  menu.hidden = false;
  const entries = [
    ["refresh", "刷新额度"],
    ["rain", "GPT 雨"],
    ["arc", "抛物线模式"],
    ["bounce", "弹射模式"],
    ["autoOpen", `自动打开：${state.autoOpen ? "开启" : "关闭"}`],
    ["testDamage", "测试受击音"],
    ["testXP", "测试经验音"],
    ["importSkin", "导入外观图片…"],
    ["openData", "打开数据目录"],
    ["hide", "隐藏桌宠"],
    ["quit", "退出"],
  ];
  for (const [name, title] of entries) {
    const button = document.createElement("button");
    button.className = "menu-button";
    button.setAttribute("role", "menuitem");
    button.textContent = title;
    button.addEventListener("click", () => action(name));
    menu.append(button);
  }
  menu.style.left = `${clamp(point.x, 6, 206)}px`;
  menu.style.top = `${clamp(point.y, 6, 394 - menu.offsetHeight)}px`;
  updateHit(point);
}
function perform(list) {
  for (const event of list) {
    if (event.type === "wheel") showWheel(event.origin);
    else
      api?.launch({
        duration: Math.min(1.6, Math.max(0, event.duration)),
        charge: chargeForDuration(event.duration),
        origin: event.origin,
      });
  }
  clearTimeout(timer);
  if (sequence.deadline !== null && !sequence.active)
    timer = setTimeout(
      () => {
        perform(sequence.resolve(now()));
      },
      Math.max(1, (sequence.deadline - now()) * 1000),
    );
}
canvas.addEventListener("pointerdown", (event) => {
  if (event.button !== 0) return;
  const point = pointFor(event),
    kind = isBubble(point)
      ? "bubble"
      : isCharacter(point)
        ? "character"
        : "empty";
  closeMenus();
  const time = now();
  perform(
    kind === "character"
      ? sequence.begin(time, point, event.detail)
      : sequence.interrupt(time),
  );
  if (kind === "empty") return;
  pointer = { point, start: time, kind, moved: false, id: event.pointerId };
  canvas.setPointerCapture(event.pointerId);
  if (kind === "character") animatePress();
  updateHit(point);
});
canvas.addEventListener("pointermove", (event) => {
  const point = pointFor(event);
  if (
    pointer &&
    Math.hypot(point.x - pointer.point.x, point.y - pointer.point.y) > 5
  )
    pointer.moved = true;
  updateHit(point);
});
canvas.addEventListener("pointerup", (event) => {
  if (!pointer || event.pointerId !== pointer.id) return;
  const released = pointer,
    point = pointFor(event),
    time = now();
  pointer = null;
  cancelAnimationFrame(pressFrame);
  meshStrength = 0;
  draw();
  if (released.kind === "character")
    perform(
      sequence.end(
        time,
        released.point,
        time - released.start,
        !released.moved && isCharacter(point),
      ),
    );
  else if (!released.moved && isBubble(point)) showBubbleMenu(point);
  updateHit(point);
});
canvas.addEventListener("pointercancel", () => {
  pointer = null;
  cancelAnimationFrame(pressFrame);
  meshStrength = 0;
  draw();
  perform(sequence.interrupt(now()));
});
document.addEventListener("contextmenu", (event) => {
  event.preventDefault();
  const point = { x: event.clientX, y: event.clientY };
  perform(sequence.interrupt(now()));
  if (!wheel.hidden || !menu.hidden) closeMenus();
  else if (isCharacter(point)) showWheel(point);
  else showBubbleMenu(point);
});
wheel.addEventListener("pointerdown", (event) => {
  if (event.target === wheel || event.target.classList.contains("wheel-disc"))
    closeMenus();
});
document.addEventListener("keydown", (event) => {
  if (event.key === "Escape") closeMenus();
});

async function acceptState(next) {
  const oldURL = state.skin?.petURL;
  state = { ...state, ...next };
  renderText();
  const url = state.skin?.petURL ?? "../../assets/gpt_quota_pet.png";
  if (!character || oldURL !== state.skin?.petURL) await loadPortrait(url);
}
function playSound(event) {
  if (!/^data:audio\//.test(event.dataURL ?? "")) return;
  const count = clamp(Number(event.count) || 1, 1, 100);
  for (let i = 0; i < count; i++)
    soundTail = soundTail.then(
      () =>
        new Promise((resolve) => {
          const audio = new Audio(event.dataURL);
          audio.volume = 0.45;
          const timeout = setTimeout(resolve, 4000);
          const done = () => {
            clearTimeout(timeout);
            resolve();
          };
          audio.addEventListener("ended", done, { once: true });
          audio.addEventListener("error", done, { once: true });
          audio.play().catch(done);
        }),
    );
}
api?.onState((next) => acceptState(next).catch(showError));
api?.onEffect((event) => {
  if (event.type === "sound") playSound(event);
  else if (event.type === "wheel") showWheel(event.origin);
});
window.__petReady = (async () => {
  try {
    await acceptState(api ? await api.getState() : state);
  } catch (error) {
    showError(error);
  }
  return Boolean(character);
})();

/** Local fixtures never dispatch IPC actions, change settings, or play audio. */
window.__petSmoke = async (step = "normal") => {
  await window.__petReady;
  closeMenus();
  pointer = null;
  meshStrength = 0;
  if (step === "longLines") {
    state.snapshot = {
      status: "ready",
      lines: [
        "5小时额度：剩余 100% · 较长文字自动省略且保持在气泡内",
        "每周额度：剩余 83% · 附加验证文字",
        "下次重置：10月10日 08:30",
      ],
    };
    renderText();
  } else if (step === "wheel") {
    showWheel({ x: 312, y: 291 });
    wheel.querySelector(".wheel-disc").style.animation = "none";
  } else if (step === "menu") showBubbleMenu({ x: 126, y: 84 });
  draw(null, 0);
  const normal = context.getImageData(0, 0, 400, 400).data;
  draw(
    step === "pressed" ? { x: 279, y: 231 } : null,
    step === "pressed" ? 0.28 : 0,
  );
  const rendered = context.getImageData(0, 0, 400, 400).data;
  let bubbleChangedPixels = 0,
    changedCharacterPixels = 0;
  for (let y = 0; y < 400; y++)
    for (let x = 0; x < 400; x++) {
      const offset = (y * 400 + x) * 4;
      if (
        normal[offset] !== rendered[offset] ||
        normal[offset + 1] !== rendered[offset + 1] ||
        normal[offset + 2] !== rendered[offset + 2] ||
        normal[offset + 3] !== rendered[offset + 3]
      ) {
        if (isBubble({ x: x + 0.5, y: y + 0.5 })) bubbleChangedPixels++;
        else changedCharacterPixels++;
      }
    }
  const quotaRects = [...quota.children].map((element) => {
    const r = element.getBoundingClientRect();
    return { x: r.x, y: r.y, width: r.width, height: r.height };
  });
  const textWithinBubble = quotaRects.every((r) =>
    [
      [r.x, r.y],
      [r.x + r.width, r.y],
      [r.x, r.y + r.height],
      [r.x + r.width, r.y + r.height],
    ].every(([x, y]) => isBubble({ x, y })),
  );
  const wheelContained = [...wheel.querySelectorAll("button")].every(
    (element) => {
      const r = element.getBoundingClientRect();
      return r.left >= 0 && r.top >= 0 && r.right <= 400 && r.bottom <= 400;
    },
  );
  return {
    ready: Boolean(character),
    step,
    lines: quota.children.length,
    wheelButtons: wheel.hidden
      ? 0
      : wheel.querySelectorAll(".wheel-button").length,
    bubble: {
      x: 34,
      y: quota.classList.contains("single") ? 91 : 59,
      width: 201,
      height: 96,
    },
    portraitLoaded: Boolean(character),
    bubbleChangedPixels,
    changedCharacterPixels,
    textWithinBubble,
    quotaRects,
    wheelContained,
    characterAlpha:
      hitPixels?.reduce(
        (n, value, i) => n + (i % 4 === 3 && value > 20 ? 1 : 0),
        0,
      ) ?? 0,
  };
};
if (new URLSearchParams(location.search).has("smoke"))
  window.__petReady.then(() =>
    window.__petSmoke(
      new URLSearchParams(location.search).get("step") ?? "longLines",
    ),
  );
