"use strict";
const {
  app,
  BrowserWindow,
  Tray,
  Menu,
  ipcMain,
  screen,
  nativeImage,
  dialog,
  shell,
  session,
} = require("electron");
const fs = require("node:fs/promises");
const path = require("node:path");
const { pathToFileURL } = require("node:url");
const { spawn } = require("node:child_process");
const { randomUUID } = require("node:crypto");
const { readQuota, normalizeQuota } = require("./lib/quota.cjs");
const { getCodexProcesses } = require("./lib/process.cjs");
const { VisibilityIntent } = require("./lib/visibility.cjs");
const { QuotaSoundDetector, prepareSound } = require("./lib/sounds.cjs");
const smokeArgument = process.argv.find((v) => v.startsWith("--smoke-test="));
const smokeDir = smokeArgument ? path.resolve(smokeArgument.slice(13)) : null;
const watcherMode = process.argv.includes("--watcher") && !smokeDir;
const root = smokeDir
  ? path.join(smokeDir, "isolated-data")
  : path.join(app.getPath("appData"), "CodexQuotaPet");
require("node:fs").mkdirSync(path.join(root, watcherMode ? "watcher" : "ui"), { recursive: true });
app.setPath("userData", path.join(root, watcherMode ? "watcher" : "ui"));
app.commandLine.appendSwitch("autoplay-policy", "no-user-gesture-required");
const acquired = app.requestSingleInstanceLock();
if (!acquired) app.quit();
const assets = path.resolve(__dirname, "..", "assets");
const renderer = path.join(__dirname, "renderer");
const settingsPath = path.join(root, "settings.json");
const visibility = new VisibilityIntent(path.join(root, "visibility.json"));
const launchPath = process.env.PORTABLE_EXECUTABLE_FILE || process.execPath;
let settings = { mode: "arc", autoOpen: true },
  snapshot = {
    status: "error",
    updatedAt: Date.now() / 1000,
    lines: ["额度暂不可用"],
    detail: "正在读取 Codex 额度",
  };
let petWindow,
  effectsWindow,
  tray,
  visible = false,
  quitting = false,
  refreshing = null,
  effectsReady;
const detector = new QuotaSoundDetector(Date.now() / 1000);
const errors = [];
let transitionQueue = Promise.resolve();
function transition(operation) {
  const next = transitionQueue.catch(() => {}).then(operation);
  transitionQueue = next;
  return next;
}
async function atomicJSON(file, value) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const tmp = `${file}.${randomUUID()}.tmp`;
  try {
    await fs.writeFile(tmp, JSON.stringify(value), { mode: 0o600 });
    await fs.rename(tmp, file);
  } finally {
    await fs.unlink(tmp).catch(() => {});
  }
}
async function readSettings() {
  try {
    const saved = JSON.parse(await fs.readFile(settingsPath, "utf8"));
    return {
      mode: saved.mode === "bounce" ? "bounce" : "arc",
      autoOpen: saved.autoOpen !== false,
      ...(typeof saved.petPath === "string" ? { petPath: saved.petPath } : {}),
    };
  } catch {
    return { mode: "arc", autoOpen: true };
  }
}
const url = (file) => pathToFileURL(file).href;
function state(kind = "pet") {
  const bounds = screen.getPrimaryDisplay().bounds;
  return {
    visible,
    mode: settings.mode,
    autoOpen: settings.autoOpen,
    snapshot,
    skin: {
      petURL: url(settings.petPath || path.join(assets, "gpt_quota_pet.png")),
      sheetURL: url(path.join(assets, "mini_gpt_sheet_original.png")),
    },
    screen: { width: bounds.width, height: bounds.height },
    kind,
  };
}
function emitState() {
  for (const [win, kind] of [
    [petWindow, "pet"],
    [effectsWindow, "effects"],
  ])
    if (win && !win.isDestroyed())
      win.webContents.send("pet:state-update", state(kind));
  updateTray();
}
function positionWindows() {
  const b = screen.getPrimaryDisplay().bounds;
  if (petWindow && !petWindow.isDestroyed())
    petWindow.setBounds(
      {
        x: b.x + b.width - 400,
        y: b.y + b.height - 400,
        width: 400,
        height: 400,
      },
      false,
    );
  if (effectsWindow && !effectsWindow.isDestroyed())
    effectsWindow.setBounds({ ...b }, false);
  emitState();
}
function trusted(event, petOnly = false) {
  return (
    (!!event.senderFrame &&
      event.senderFrame === event.sender.mainFrame &&
      event.sender === petWindow?.webContents) ||
    (!petOnly &&
      !!event.senderFrame &&
      event.senderFrame === event.sender.mainFrame &&
      event.sender === effectsWindow?.webContents)
  );
}
function secureWindow(win) {
  win.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
  win.webContents.on("will-navigate", (event) => event.preventDefault());
  win.webContents.on("will-attach-webview", (event) => event.preventDefault());
  win.webContents.on("console-message", (event) => {
    if (smokeDir && event.level === "error")
      errors.push(String(event.message).slice(0, 500));
  });
  win.webContents.on("render-process-gone", () => {
    if (smokeDir) errors.push("Renderer terminated");
  });
}
async function effect(value) {
  await effectsReady;
  if (effectsWindow && !effectsWindow.isDestroyed()) {
    effectsWindow.showInactive();
    effectsWindow.webContents.send("pet:effect", value);
  }
}
async function sound(kind, count = 1) {
  if (smokeDir) return;
  try {
    const dataURL = await prepareSound(kind, path.join(root, "sounds"));
    if (petWindow && !petWindow.isDestroyed())
      petWindow.webContents.send("pet:effect", {
        type: "sound",
        dataURL,
        count: Math.max(1, Math.min(100, count)),
      });
  } catch {}
}
async function refreshQuota() {
  if (refreshing) return refreshing;
  refreshing = (async () => {
    try {
      snapshot = smokeDir
        ? normalizeQuota({
            rateLimits: {
              primary: {
                usedPercent: 0,
                windowDurationMins: 300,
                resetsAt: Date.now() / 1000 + 3600,
              },
            },
            rateLimitResetCredits: { availableCount: 2 },
          })
        : await readQuota({ getProcesses: getCodexProcesses });
      const events = detector.accept(snapshot);
      if (events.damageCount) void sound("damage", events.damageCount);
      if (events.playXP) void sound("xp");
    } catch (e) {
      snapshot = {
        status: "error",
        updatedAt: Date.now() / 1000,
        lines: ["额度暂不可用"],
        detail:
          e.name === "QuotaReadError" ? e.message : "Codex 暂时无法读取额度",
      };
      detector.noteFailure(snapshot.updatedAt);
    }
    await atomicJSON(path.join(root, "quota.json"), snapshot).catch(() => {});
    emitState();
    return snapshot;
  })().finally(() => {
    refreshing = null;
  });
  return refreshing;
}
async function processesSafely() {
  if (smokeDir) return [];
  try {
    return await getCodexProcesses();
  } catch {
    return null;
  }
}
async function stopEffects() {
  await effectsReady;
  effectsWindow.webContents.send("pet:effect", { type: "clear" });
  effectsWindow.hide();
}
async function hidePet() {
  await visibility.hide((await processesSafely()) || []);
  await stopEffects();
  visible = false;
  if (tray) petWindow.hide();
  else petWindow.minimize();
  emitState();
}
async function showPet(explicit = false) {
  if (explicit) await visibility.showExplicitly();
  visible = true;
  petWindow.restore();
  petWindow.showInactive();
  emitState();
}
function configureLogin() {
  if (smokeDir || process.platform !== "win32" || !app.isPackaged) return;
  try {
    app.setLoginItemSettings({
      openAtLogin: settings.autoOpen,
      path: launchPath,
      args: ["--watcher"],
      name: "CodexQuotaPetWatcher",
    });
  } catch {
    snapshot = {
      ...snapshot,
      startupError: "无法设置 Windows 登录启动，请通过托盘重新启用自动出现",
    };
    emitState();
  }
}
function startWatcher() {
  if (
    smokeDir ||
    process.platform !== "win32" ||
    !app.isPackaged ||
    !settings.autoOpen
  )
    return;
  const child = spawn(launchPath, ["--watcher"], {
    detached: true,
    stdio: "ignore",
    windowsHide: true,
  });
  child.on("error", () => {});
  child.unref();
}
async function importSkin() {
  const result = await dialog.showOpenDialog(petWindow, {
    title: "导入 GPT 娘 PNG 皮肤",
    properties: ["openFile"],
    filters: [{ name: "PNG 图片", extensions: ["png"] }],
  });
  if (result.canceled) return false;
  const source = result.filePaths[0];
  const stat = await fs.stat(source);
  if (stat.size > 20 * 1024 * 1024) throw new Error("皮肤文件过大");
  const bytes = await fs.readFile(source);
  if (
    !bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  )
    throw new Error("请选择 PNG 图片");
  const image = nativeImage.createFromBuffer(bytes);
  if (image.isEmpty()) throw new Error("无法读取 PNG 图片");
  const destination = path.join(root, `skin-${randomUUID()}.png`);
  await fs.mkdir(root, { recursive: true });
  await fs.writeFile(destination, bytes);
  settings.petPath = destination;
  await atomicJSON(settingsPath, settings);
  emitState();
  return true;
}
const actions = new Set([
  "show",
  "hide",
  "refresh",
  "rain",
  "autoOpen",
  "quit",
  "arc",
  "bounce",
  "testDamage",
  "testXP",
  "importSkin",
  "openData",
  "wheel",
]);
function action(name, payload) {
  return ["show", "hide", "quit"].includes(name)
    ? transition(() => runAction(name, payload))
    : runAction(name, payload);
}
async function runAction(name, payload) {
  if (!actions.has(name)) throw new Error("不支持的操作");
  if (
    name === "autoOpen" &&
    payload !== undefined &&
    typeof payload !== "boolean"
  )
    throw new Error("无效的设置");
  switch (name) {
    case "show":
      await showPet(true);
      break;
    case "hide":
      await hidePet();
      break;
    case "refresh":
      await refreshQuota();
      break;
    case "rain":
      await effect({ type: "rain" });
      break;
    case "arc":
    case "bounce":
      settings.mode = name;
      await atomicJSON(settingsPath, settings);
      emitState();
      break;
    case "autoOpen":
      settings.autoOpen = payload === undefined ? !settings.autoOpen : payload;
      await atomicJSON(settingsPath, settings);
      configureLogin();
      startWatcher();
      emitState();
      break;
    case "testDamage":
      await sound("damage");
      break;
    case "testXP":
      await sound("xp");
      break;
    case "importSkin":
      return importSkin();
    case "openData":
      await fs.mkdir(root, { recursive: true });
      await shell.openPath(root);
      break;
    case "wheel":
      petWindow.webContents.send("pet:effect", { type: "wheel" });
      break;
    case "quit":
      await visibility.hide((await processesSafely()) || []);
      await stopEffects();
      quitting = true;
      app.quit();
      break;
  }
  return state();
}
function updateTray() {
  if (!tray) return;
  const click = (name) => () => void action(name).catch(() => {});
  tray.setContextMenu(
    Menu.buildFromTemplate([
      {
        label: visible ? "隐藏 GPT 娘" : "显示 GPT 娘",
        click: click(visible ? "hide" : "show"),
      },
      { label: "刷新额度", click: click("refresh") },
      { label: "GPT 雨", click: click("rain") },
      {
        label: "发射模式",
        submenu: [
          {
            label: "抛物线",
            type: "radio",
            checked: settings.mode === "arc",
            click: click("arc"),
          },
          {
            label: "弹来弹去",
            type: "radio",
            checked: settings.mode === "bounce",
            click: click("bounce"),
          },
        ],
      },
      {
        label: "音效测试",
        submenu: [
          { label: "受伤音效", click: click("testDamage") },
          { label: "经验音效", click: click("testXP") },
        ],
      },
      {
        label: "随 Codex 自动出现",
        type: "checkbox",
        checked: settings.autoOpen,
        click: (item) => void action("autoOpen", item.checked).catch(() => {}),
      },
      { label: "导入皮肤", click: click("importSkin") },
      { type: "separator" },
      { label: "退出", click: click("quit") },
    ]),
  );
}
function installIPC() {
  ipcMain.handle("pet:state", (event) => {
    if (!trusted(event)) throw new Error("不可信的请求");
    return state(
      event.sender === effectsWindow.webContents ? "effects" : "pet",
    );
  });
  ipcMain.handle("pet:action", (event, name, payload) => {
    if (!trusted(event, true) || typeof name !== "string")
      throw new Error("不可信的请求");
    return action(name, payload);
  });
  ipcMain.on("pet:hit", (event, hit) => {
    if (trusted(event, true) && typeof hit === "boolean")
      petWindow.setIgnoreMouseEvents(!hit, { forward: true });
  });
  ipcMain.on("pet:launch", (event, value) => {
    if (!trusted(event, true) || !value || typeof value !== "object") return;
    const { origin } = value;
    if (
      value.charge !== undefined &&
      (typeof value.charge !== "number" ||
        !Number.isFinite(value.charge) ||
        value.charge < 0 ||
        value.charge > 1)
    )
      return;
    const duration =
      typeof value.charge === "number" && Number.isFinite(value.charge)
        ? value.charge * 1.6
        : value.duration;
    if (
      !origin ||
      ![origin.x, origin.y, duration].every(
        (v) => typeof v === "number" && Number.isFinite(v),
      ) ||
      origin.x < 0 ||
      origin.x > 400 ||
      origin.y < 0 ||
      origin.y > 400 ||
      duration < 0 ||
      duration > 60
    )
      return;
    const b = screen.getPrimaryDisplay().bounds,
      p = petWindow.getBounds();
    void effect({
      type: "launch",
      origin: { x: p.x - b.x + origin.x, y: p.y - b.y + origin.y },
      duration: Math.min(duration, 1.6),
      charge: Math.min(duration / 1.6, 1),
      mode: settings.mode,
    });
  });
}
async function createWindows() {
  const prefs = {
    preload: path.join(__dirname, "preload.cjs"),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
    webSecurity: true,
    backgroundThrottling: false,
  };
  petWindow = new BrowserWindow({
    width: 400,
    height: 400,
    frame: false,
    transparent: true,
    show: false,
    resizable: false,
    hasShadow: false,
    skipTaskbar: true,
    backgroundColor: "#00000000",
    webPreferences: prefs,
  });
  effectsWindow = new BrowserWindow({
    width: 800,
    height: 600,
    frame: false,
    transparent: true,
    show: false,
    resizable: false,
    hasShadow: false,
    skipTaskbar: true,
    focusable: false,
    backgroundColor: "#00000000",
    webPreferences: prefs,
  });
  for (const win of [petWindow, effectsWindow]) {
    win.setAlwaysOnTop(true, "screen-saver");
    secureWindow(win);
  }
  effectsWindow.setIgnoreMouseEvents(true, { forward: true });
  petWindow.setIgnoreMouseEvents(true, { forward: true });
  installIPC();
  positionWindows();
  petWindow.on("close", (event) => {
    if (!quitting && !smokeDir) {
      event.preventDefault();
      void transition(hidePet);
    }
  });
  petWindow.on("restore", () => {
    if (!tray && !visible) void transition(() => showPet(true));
  });
  const opts = smokeDir ? { query: { smoke: "1" } } : undefined;
  effectsReady = effectsWindow.loadFile(
    path.join(renderer, "effects.html"),
    opts,
  );
  await Promise.all([
    effectsReady,
    petWindow.loadFile(path.join(renderer, "pet.html"), opts),
  ]);
  effectsWindow.showInactive();
  if (!smokeDir)
    try {
      const icon = nativeImage.createFromPath(
        path.join(assets, "gpt_quota_pet.png"),
      );
      if (icon.isEmpty()) throw new Error("Missing tray");
      tray = new Tray(icon.resize({ width: 16, height: 16 }));
      tray.setToolTip("GPT 娘 · Codex 额度");
      tray.on("double-click", () => void showPet(true));
      updateTray();
    } catch {
      petWindow.setSkipTaskbar(false);
    }
  screen.on("display-metrics-changed", positionWindows);
  screen.on("display-added", positionWindows);
  screen.on("display-removed", positionWindows);
}
async function watcher() {
  const launched = new Set();
  let busy = false;
  const check = async () => {
    if (busy) return;
    busy = true;
    try {
      settings = await readSettings();
      if (!settings.autoOpen) {
        app.quit();
        return;
      }
      const processes = await processesSafely();
      if (!processes || !processes.length) return;
      await visibility.load();
      if (!(await visibility.shouldShowOnReopen(processes))) return;
      const newProcesses = processes.filter(
        (p) =>
          Number.isFinite(p.startedAt) &&
          !launched.has(`${p.pid}:${p.startedAt}`),
      );
      if (!newProcesses.length) return;
      for (const p of processes)
        if (Number.isFinite(p.startedAt))
          launched.add(`${p.pid}:${p.startedAt}`);
      const child = spawn(launchPath, ["--auto-open"], {
        detached: true,
        stdio: "ignore",
        windowsHide: true,
      });
      child.on("error", () => {});
      child.unref();
    } finally {
      busy = false;
    }
  };
  await check();
  setInterval(() => void check().catch(() => {}), 2000);
}
async function runSmoke() {
  await fs.mkdir(smokeDir, { recursive: true });
  await showPet();
  await refreshQuota();
  const result = {
    ok: false,
    platform: process.platform,
    primary: screen.getPrimaryDisplay(),
    petBounds: petWindow.getBounds(),
    effectsBounds: effectsWindow.getBounds(),
    steps: [],
    errors,
  };
  try {
    await petWindow.webContents.executeJavaScript("window.__petReady", true);
    await effectsWindow.webContents.executeJavaScript(
      "window.__effectsReady",
      true,
    );
    for (const step of ["normal", "pressed", "wheel", "longLines"]) {
      const metadata = await petWindow.webContents.executeJavaScript(
        `window.__petSmoke(${JSON.stringify(step)})`,
        true,
      );
      result.steps.push({ surface: "pet", step, metadata });
      await petWindow.webContents.executeJavaScript(
        "new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))",
      );
      await fs.writeFile(
        path.join(smokeDir, `pet-${step}.png`),
        (await petWindow.webContents.capturePage()).toPNG(),
      );
    }
    for (const step of ["arc", "bounce", "rain"]) {
      const metadata = await effectsWindow.webContents.executeJavaScript(
        `window.__effectsSmoke(${JSON.stringify(step)})`,
        true,
      );
      result.steps.push({ surface: "effects", step, metadata });
      await effectsWindow.webContents.executeJavaScript(
        "new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))",
      );
      await fs.writeFile(
        path.join(smokeDir, `effects-${step}.png`),
        (await effectsWindow.webContents.capturePage()).toPNG(),
      );
    }
    const b = result.primary.bounds,
      p = result.petBounds,
      e = result.effectsBounds;
    result.petAnchored =
      p.width === 400 &&
      p.height === 400 &&
      p.x + p.width === b.x + b.width &&
      p.y + p.height === b.y + b.height;
    result.effectsOriginMatchesDisplay = ["x", "y", "width", "height"].every(
      (k) => e[k] === b[k],
    );
    result.geometryOK =
      result.petAnchored &&
      (process.platform === "darwin"
        ? e.width === b.width && e.height === b.height
        : result.effectsOriginMatchesDisplay);
    result.targetGeometryVerified =
      process.platform === "win32" && result.geometryOK;
    result.bubble = await petWindow.webContents.executeJavaScript(
      `(()=>{const q=document.getElementById('quota');const r=q.getBoundingClientRect();return {x:r.x,y:r.y,width:r.width,height:r.height,fits:r.x>=0&&r.y>=0&&r.right<=400&&r.bottom<=400&&q.scrollWidth<=q.clientWidth&&q.scrollHeight<=q.clientHeight};})()`,
    );
    result.ok =
      result.geometryOK &&
      result.bubble.fits &&
      errors.length === 0 &&
      result.steps.some(
        (s) =>
          s.step === "wheel" &&
          s.metadata?.wheelButtons === 10 &&
          s.metadata?.wheelContained,
      ) &&
      result.steps
        .filter((s) => s.surface === "pet")
        .every(
          (s) =>
            s.metadata?.portraitLoaded &&
            s.metadata?.textWithinBubble &&
            s.metadata?.bubbleChangedPixels === 0,
        ) &&
      result.steps
        .filter((s) => s.surface === "effects")
        .every(
          (s) => s.metadata?.assetsLoaded && s.metadata?.spriteCount === 24,
        );
  } catch (e) {
    errors.push(String(e.message).slice(0, 500));
  }
  await atomicJSON(path.join(smokeDir, "report.json"), result);
  app.exit(result.ok ? 0 : 1);
}
app.on("second-instance", (_event, argv) => {
  if (watcherMode || !petWindow) return;
  void transition(async () => {
    if (argv.includes("--show")) return showPet(true);
    if (!argv.includes("--auto-open")) return;
    const processes = await processesSafely();
    if (!processes?.some((p) => Number.isFinite(p.startedAt))) return;
    await visibility.load();
    if (await visibility.shouldShowOnReopen(processes)) await showPet();
  }).catch(() => {});
});
app.on("window-all-closed", () => {
  if (!watcherMode) app.quit();
});
if (acquired)
  app
    .whenReady()
    .then(async () => {
      session.defaultSession.setPermissionRequestHandler(
        (_contents, _permission, callback) => callback(false),
      );
      session.defaultSession.setPermissionCheckHandler(() => false);
      settings = await readSettings();
      await visibility.load();
      if (watcherMode) {
        await watcher();
        return;
      }
      await createWindows();
      if (smokeDir) {
        await runSmoke();
        return;
      }
      configureLogin();
      startWatcher();
      const shouldShow =
        process.argv.includes("--show") ||
        (await visibility.shouldShowOnReopen(await processesSafely()));
      if (shouldShow) await showPet(process.argv.includes("--show"));
      void refreshQuota();
      setInterval(() => void refreshQuota(), 60000);
      setInterval(() => {
        if (detector.markResetDue()) void sound("xp");
      }, 1000);
    })
    .catch(async () => {
      if (smokeDir) {
        await fs.mkdir(smokeDir, { recursive: true });
        await atomicJSON(path.join(smokeDir, "report.json"), {
          ok: false,
          errors: ["Main initialization failed"],
        });
      }
      app.exit(1);
    });
module.exports = { runSmoke };
