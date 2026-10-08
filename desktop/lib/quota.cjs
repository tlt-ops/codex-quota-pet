"use strict";
const fs = require("node:fs");
const path = require("node:path");
const cp = require("node:child_process");
const { randomUUID } = require("node:crypto");
const MAX = 2 * 1024 * 1024;
class QuotaReadError extends Error {}
const finite = (n) => typeof n === "number" && Number.isFinite(n);
const roundEven = (n) => {
  const lower = Math.floor(n);
  return n - lower === 0.5 ? lower + (lower % 2 === 0 ? 0 : 1) : Math.round(n);
};
function resolveCLI(candidate, { platform, exists, arch: nodeArch }) {
  if (!exists(candidate)) return null;
  if (!/\.(cmd|ps1)$/i.test(candidate)) return candidate;
  // Never execute a npm shell wrapper. Resolve its installed native vendor binary.
  const p = platform === "win32" ? path.win32 : path;
  const roots = [
    p.join(p.dirname(candidate), "node_modules", "@openai", "codex"),
    p.join(
      p.dirname(candidate),
      "..",
      "lib",
      "node_modules",
      "@openai",
      "codex",
    ),
  ];
  const arch = nodeArch === "arm64" ? "aarch64" : "x86_64";
  for (const root of roots) {
    const packages = [
      root,
      p.join(root, "node_modules", "@openai", `codex-win32-${nodeArch}`),
      p.join(p.dirname(root), `codex-win32-${nodeArch}`),
    ];
    for (const pkg of packages)
      for (const bin of ["bin", "codex"]) {
        const native = p.join(
          pkg,
          "vendor",
          `${arch}-pc-windows-msvc`,
          bin,
          "codex.exe",
        );
        if (exists(native)) return native;
      }
  }
  return null;
}
async function discoverCodexCLI({
  platform = process.platform,
  arch = process.arch,
  env = process.env,
  exists = (f) => {
    try {
      return fs.statSync(f).isFile();
    } catch {
      return false;
    }
  },
  processes = [],
  getProcesses,
} = {}) {
  const p = platform === "win32" ? path.win32 : path;
  const resolve = (candidate) =>
    resolveCLI(candidate, { platform, exists, arch });
  if (env.CODEX_QUOTA_PET_CLI) {
    const found = resolve(env.CODEX_QUOTA_PET_CLI);
    if (found) return found;
    throw new QuotaReadError("指定的 Codex CLI 不可用");
  }
  const pathValue = env.PATH || env.Path || "";
  for (const dir of pathValue
    .split(platform === "win32" ? ";" : ":")
    .filter(Boolean)) {
    for (const name of platform === "win32"
      ? ["codex.exe", "codex.cmd"]
      : ["codex"]) {
      const found = resolve(p.join(dir.replace(/^"|"$/g, ""), name));
      if (found) return found;
    }
  }
  if (getProcesses) {
    try {
      processes = await getProcesses();
    } catch {}
  }
  const roots = processes.map((v) => p.dirname(v.executable));
  if (platform === "win32")
    for (const base of [
      env.LOCALAPPDATA && p.join(env.LOCALAPPDATA, "Programs"),
      env.ProgramFiles,
    ])
      if (base)
        for (const name of ["Codex", "ChatGPT"]) roots.push(p.join(base, name));
  for (const root of roots)
    for (const relative of [
      "resources/codex.exe",
      "resources/codex-cli/codex.exe",
      "resources/codex-cli/bin/codex.exe",
      "resources/app.asar.unpacked/codex.exe",
      "resources/app.asar.unpacked/node_modules/@openai/codex/vendor/x86_64-pc-windows-msvc/codex/codex.exe",
    ]) {
      const found = resolve(p.join(root, ...relative.split("/")));
      if (found) return found;
    }
  throw new QuotaReadError("找不到 Codex CLI");
}
function normalizeQuota(
  result,
  { now = Date.now() / 1000, sampleId = randomUUID() } = {},
) {
  const by = result?.rateLimitsByLimitId?.codex;
  const bucket = by && typeof by === "object" ? by : result?.rateLimits;
  const primary = bucket?.primary;
  const window =
    primary && typeof primary === "object" ? primary : bucket?.secondary;
  if (!window || !finite(window.usedPercent))
    throw new QuotaReadError("Codex 暂无可显示的额度");
  const duration =
    Number.isSafeInteger(window.windowDurationMins) &&
    window.windowDurationMins > 0
      ? window.windowDurationMins
      : null;
  const reset =
    finite(window.resetsAt) &&
    window.resetsAt > 0 &&
    Number.isFinite(new Date(window.resetsAt * 1000).getTime())
      ? window.resetsAt
      : null;
  const count = result?.rateLimitResetCredits?.availableCount;
  const quota = {
    bucketId: by ? "codex" : "legacy",
    windowKind: window === primary ? "primary" : "secondary",
    windowDurationMins: duration,
    usedPercent: window.usedPercent,
    remainingPercent: Math.max(
      0,
      Math.min(100, roundEven(100 - window.usedPercent)),
    ),
    resetsAt: reset,
    availableCount: Number.isSafeInteger(count) && count >= 0 ? count : null,
    sampleId,
  };
  const durationText = !duration
    ? ""
    : duration % 1440 === 0
      ? `${duration / 1440}天`
      : duration % 60 === 0
        ? `${duration / 60}小时`
        : `${duration}分钟`;
  const pad = (n) => String(n).padStart(2, "0");
  const date = reset === null ? null : new Date(reset * 1000);
  return {
    status: "ok",
    updatedAt: now,
    lines: [
      `额度 ${quota.remainingPercent}%${durationText ? `（${durationText}）` : ""}`,
      `重置 ${date ? `${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${pad(date.getHours())}:${pad(date.getMinutes())}` : "未知"}`,
      `重置次数 ${quota.availableCount === null ? "未知" : `${quota.availableCount}次`}`,
    ],
    quota,
  };
}
function transient(error) {
  return (
    error?.code === -32603 &&
    !/auth|unauthorized|forbidden|login|log in|sign in|credential|access token|refresh token|401|403/i.test(
      String(error.message),
    )
  );
}
async function readQuota({
  cli,
  timeoutMs = 20000,
  spawn = cp.spawn,
  ...discovery
} = {}) {
  if (!finite(timeoutMs) || timeoutMs <= 0)
    throw new QuotaReadError("额度读取参数无效");
  cli ||= await discoverCodexCLI(discovery);
  let child;
  try {
    child = spawn(cli, ["app-server", "--listen", "stdio://"], {
      stdio: ["pipe", "pipe", "ignore"],
      windowsHide: true,
      shell: false,
      env: discovery.env || process.env,
    });
  } catch {
    throw new QuotaReadError("无法启动 Codex CLI");
  }
  let buffer = Buffer.alloc(0),
    waiter,
    fatal;
  const fail = (message) => {
    fatal = new QuotaReadError(message);
    if (waiter) {
      waiter.reject(fatal);
      waiter = null;
    }
  };
  const timer = setTimeout(() => fail("连接 Codex 超时"), timeoutMs);
  child.on("error", () => fail("无法启动 Codex CLI"));
  child.on("close", () => fail("Codex 连接已断开"));
  child.stdin.on("error", () => fail("Codex 连接已断开"));
  child.stdout.on("error", () => fail("无法读取 Codex 响应"));
  child.stdout.on("data", (chunk) => {
    if (fatal) return;
    buffer = Buffer.concat([buffer, Buffer.from(chunk)]);
    if (buffer.length > MAX) return fail("Codex 响应过长");
    let end;
    while ((end = buffer.indexOf(10)) >= 0) {
      const line = buffer.subarray(0, end).toString("utf8");
      buffer = buffer.subarray(end + 1);
      if (!line.trim()) continue;
      let message;
      try {
        message = JSON.parse(line);
      } catch {
        return fail("Codex 响应格式错误");
      }
      if (waiter && message?.id === waiter.id) {
        const active = waiter;
        waiter = null;
        active.resolve(message);
      }
    }
  });
  const request = (id, method, params) =>
    new Promise((resolve, reject) => {
      if (fatal) return reject(fatal);
      waiter = { id, resolve, reject };
      try {
        child.stdin.write(
          JSON.stringify({
            id,
            method,
            ...(params === undefined ? {} : { params }),
          }) + "\n",
        );
      } catch {
        fail("Codex 连接已断开");
      }
    });
  const resultOf = (message) => {
    if (message.error) throw new QuotaReadError("Codex 未能读取额度");
    if (!message.result || typeof message.result !== "object")
      throw new QuotaReadError("Codex 额度响应格式不支持");
    return message.result;
  };
  try {
    resultOf(
      await request(1, "initialize", {
        clientInfo: { name: "codex-quota-pet", version: "1.0.0" },
        capabilities: {},
      }),
    );
    child.stdin.write('{"method":"initialized"}\n');
    let message = await request(2, "account/rateLimits/read");
    if (transient(message.error)) {
      const account = resultOf(await request(3, "account/read", {}));
      if (!account.account || typeof account.account !== "object")
        throw new QuotaReadError("请先登录 Codex");
      message = await request(4, "account/rateLimits/read");
    }
    return normalizeQuota(resultOf(message));
  } finally {
    clearTimeout(timer);
    waiter = null;
    child.stdin.end();
    if (child.exitCode === null) {
      child.kill();
      const forced = setTimeout(() => {
        if (child.exitCode === null) child.kill("SIGKILL");
      }, 1000);
      forced.unref();
    }
  }
}
module.exports = {
  discoverCodexCLI,
  readQuota,
  normalizeQuota,
  QuotaReadError,
};
