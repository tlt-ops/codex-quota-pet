"use strict";
const { test } = require("node:test");
const assert = require("node:assert/strict");
const { EventEmitter } = require("node:events");
const { PassThrough, Writable } = require("node:stream");
const fs = require("node:fs/promises");
const os = require("node:os");
const path = require("node:path");
const {
  readQuota,
  normalizeQuota,
  discoverCodexCLI,
} = require("../desktop/lib/quota.cjs");
const { parseProcesses } = require("../desktop/lib/process.cjs");
const { VisibilityIntent } = require("../desktop/lib/visibility.cjs");
const {
  QuotaSoundDetector,
  prepareSound,
} = require("../desktop/lib/sounds.cjs");
const limits = {
  rateLimitsByLimitId: {
    codex: {
      primary: { usedPercent: 42, windowDurationMins: 300, resetsAt: 200 },
    },
  },
  rateLimitResetCredits: { availableCount: 2 },
};
function fakeSpawn(respond) {
  const child = new EventEmitter();
  child.stdout = new PassThrough();
  child.exitCode = null;
  child.killed = false;
  child.kill = () => {
    child.killed = true;
    child.exitCode = 0;
    child.emit("exit", 0);
    child.emit("close", 0);
  };
  child.stdin = new Writable({
    write(bytes, enc, cb) {
      const message = JSON.parse(bytes.toString());
      if (message.id)
        setImmediate(() => {
          const response = JSON.stringify(respond(message)) + "\n";
          child.stdout.write(response.slice(0, 5));
          child.stdout.write(response.slice(5));
        });
      cb();
    },
  });
  return child;
}
test("NDJSON handshake, notifications and cleanup", async () => {
  const methods = [];
  const child = fakeSpawn((m) => {
    methods.push(m.method);
    return { id: m.id, result: m.id === 1 ? {} : limits };
  });
  const snapshot = await readQuota({
    cli: "codex.exe",
    spawn: (file, args, options) => {
      assert.equal(options.shell, false);
      return child;
    },
  });
  assert.equal(snapshot.quota.remainingPercent, 58);
  assert.equal(snapshot.lines.length, 3);
  assert.equal(child.killed, true);
  assert.deepEqual(methods, ["initialize", "account/rateLimits/read"]);
});
test("transient internal error refreshes account exactly once; auth errors never retry or leak", async () => {
  const methods = [];
  const child = fakeSpawn((m) => {
    methods.push(m.method);
    return m.id === 2
      ? { id: 2, error: { code: -32603, message: "temporary private detail" } }
      : {
          id: m.id,
          result: m.id === 3 ? { account: {} } : m.id === 4 ? limits : {},
        };
  });
  await readQuota({ cli: "codex.exe", spawn: () => child });
  assert.deepEqual(methods, [
    "initialize",
    "account/rateLimits/read",
    "account/read",
    "account/rateLimits/read",
  ]);
  const auth = fakeSpawn((m) => ({
    id: m.id,
    ...(m.id === 1
      ? { result: {} }
      : { error: { code: -32603, message: "401 SECRET" } }),
  }));
  await assert.rejects(
    readQuota({ cli: "codex.exe", spawn: () => auth }),
    (e) => !e.message.includes("SECRET"),
  );
  assert.equal(auth.killed, true);
});
test("timeout and oversized output kill subprocess", async () => {
  const child = fakeSpawn(() => ({ id: 900, result: {} }));
  await assert.rejects(
    readQuota({ cli: "codex.exe", spawn: () => child, timeoutMs: 15 }),
    /超时/,
  );
  assert.equal(child.killed, true);
  const big = fakeSpawn(() => ({ id: 1, result: {} }));
  setImmediate(() => big.stdout.write("x".repeat(2 * 1024 * 1024 + 1)));
  await assert.rejects(
    readQuota({ cli: "codex.exe", spawn: () => big }),
    /过长/,
  );
  assert.equal(big.killed, true);
});
test("invalid numeric fields cannot silently report zero", () => {
  assert.equal(
    normalizeQuota({ rateLimits: { primary: { usedPercent: 1.5 } } }).quota
      .remainingPercent,
    98,
  );
  for (const usedPercent of [true, null, "5", NaN, Infinity])
    assert.throws(() =>
      normalizeQuota({ rateLimits: { primary: { usedPercent } } }),
    );
  const value = normalizeQuota({
    rateLimits: {
      secondary: { usedPercent: -20, windowDurationMins: true, resetsAt: 1e99 },
    },
    rateLimitResetCredits: { availableCount: true },
  });
  assert.equal(value.quota.remainingPercent, 100);
  assert.equal(value.quota.availableCount, null);
  assert.equal(value.quota.resetsAt, null);
});
test("Windows npm wrapper resolves native vendor executable without running cmd", async () => {
  const native =
    "C:\\npm\\node_modules\\@openai\\codex\\vendor\\x86_64-pc-windows-msvc\\bin\\codex.exe";
  const available = new Set(["C:\\npm\\codex.cmd", native]);
  assert.equal(
    await discoverCodexCLI({
      platform: "win32",
      arch: "x64",
      env: { PATH: "C:\\npm" },
      exists: (f) => available.has(f),
    }),
    native,
  );
});
test("process parsing filters helpers, CLI and unknown command lines", () => {
  const rows = [
    {
      ProcessId: 3,
      ExecutablePath: "C:\\Codex\\Codex.exe",
      CommandLine: '"C:\\Codex\\Codex.exe"',
      StartedAt: "2026-10-08T10:00:00Z",
    },
    {
      ProcessId: 4,
      ExecutablePath: "C:\\Codex\\Codex.exe",
      CommandLine: "Codex.exe --type=renderer",
    },
    {
      ProcessId: 5,
      ExecutablePath: "C:\\CLI\\codex.exe",
      CommandLine: "codex.exe app-server",
    },
    {
      ProcessId: 6,
      ExecutablePath: "C:\\ChatGPT\\ChatGPT.exe",
      CommandLine: null,
    },
  ];
  assert.deepEqual(
    parseProcesses(JSON.stringify(rows)).map((p) => p.pid),
    [3],
  );
});
test("visibility survives restart, unknown processes, PID reuse, malformed records and concurrent hide", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "pet-visibility-"));
  const file = path.join(dir, "state.json");
  const now = Date.now() / 1000;
  try {
    const intent = await new VisibilityIntent(file).load();
    await intent.hide([{ pid: 1, startedAt: now - 10 }], now);
    const restarted = await new VisibilityIntent(file).load();
    assert.equal(
      await restarted.shouldShowOnReopen([{ pid: 1, startedAt: now - 10 }]),
      false,
    );
    assert.equal(await restarted.shouldShowOnReopen(null), false);
    assert.equal(
      await restarted.shouldShowOnReopen([{ pid: 1, startedAt: now + 4 }]),
      true,
    );
    await fs.writeFile(file, "bad");
    const malformed = await new VisibilityIntent(file).load();
    assert.equal(
      await malformed.shouldShowOnReopen([{ pid: 2, startedAt: now }]),
      false,
    );
    assert.equal(
      await malformed.shouldShowOnReopen([{ pid: 2, startedAt: now + 5 }]),
      true,
    );
    await intent.hide([], now);
    const older = await new VisibilityIntent(file).load();
    await intent.hide([], now + 1);
    assert.equal(
      await older.shouldShowOnReopen([{ pid: 2, startedAt: now + 5 }]),
      false,
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
const sample = (
  id,
  remaining,
  updatedAt,
  resetsAt = 20,
  availableCount = 1,
) => ({
  sampleId: id,
  bucketId: "codex",
  windowKind: "primary",
  windowDurationMins: 300,
  usedPercent: 100 - remaining,
  remainingPercent: remaining,
  resetsAt,
  availableCount,
  updatedAt,
});
test("sound baseline, dedup, deadline coalescing and independent credit gain", () => {
  const detector = new QuotaSoundDetector(1);
  assert.deepEqual(detector.accept(sample("a", 80, 1), 1), {
    damageCount: 0,
    playXP: false,
  });
  assert.equal(detector.accept(sample("b", 77, 2), 2).damageCount, 3);
  assert.equal(detector.accept(sample("b", 50, 3), 3).damageCount, 0);
  assert.equal(detector.markResetDue(20), true);
  assert.equal(detector.markResetDue(20), false);
  assert.equal(detector.accept(sample("c", 100, 21), 21).playXP, false);
  assert.equal(detector.accept(sample("d", 100, 22, 20, 2), 22).playXP, true);
  assert.equal(detector.accept(sample("e", 99, 23), 23).damageCount, 1);
  detector.noteFailure(24);
  assert.equal(detector.accept(sample("f", 50, 25), 25).damageCount, 0);
  assert.equal(detector.accept(sample("old", 1, 23), 26).damageCount, 0);
});
test("sound download integrity rejection prevents caching", async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "pet-sound-"));
  try {
    await assert.rejects(
      prepareSound("damage", dir, {
        download: async () => Buffer.from("OggSbad"),
      }),
      /校验/,
    );
    assert.deepEqual(await fs.readdir(dir), []);
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});

test("visibility lock coordinates another OS process and stale generations stay hidden", async () => {
  const { spawn } = require("node:child_process");
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), "pet-lock-")),
    file = path.join(dir, "state.json"),
    now = Date.now() / 1000;
  try {
    const old = await new VisibilityIntent(file).load();
    await old.hide([], now);
    await fs.writeFile(`${file}.lock`, JSON.stringify({ pid: process.pid }));
    const source = `const {VisibilityIntent}=require(process.argv[1]);(async()=>{process.stdout.write('ready');const v=await new VisibilityIntent(process.argv[2]).load();await v.hide([],Number(process.argv[3]));})().catch(()=>process.exit(1));`;
    const child = spawn(
      process.execPath,
      [
        "-e",
        source,
        path.resolve("desktop/lib/visibility.cjs"),
        file,
        String(now + 1),
      ],
      { stdio: ["ignore", "pipe", "pipe"] },
    );
    const completion = new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("exit", (code) =>
        code === 0 ? resolve() : reject(new Error("child failed")),
      );
    });
    await new Promise((resolve) => child.stdout.once("data", resolve));
    assert.equal(JSON.parse(await fs.readFile(file, "utf8")).recordedAt, now);
    await fs.unlink(`${file}.lock`);
    await completion;
    assert.equal(
      JSON.parse(await fs.readFile(file, "utf8")).recordedAt,
      now + 1,
    );
    assert.equal(
      await old.shouldShowOnReopen([{ pid: 3, startedAt: now + 5 }]),
      false,
    );
  } finally {
    await fs.rm(dir, { recursive: true, force: true });
  }
});
