"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const { randomUUID } = require("node:crypto");
const queues = new Map();
async function lockFile(file) {
  await fs.mkdir(path.dirname(file), { recursive: true });
  const lock = `${file}.lock`,
    deadline = Date.now() + 2500;
  while (true) {
    try {
      const handle = await fs.open(lock, "wx", 0o600);
      await handle.writeFile(JSON.stringify({ pid: process.pid }));
      return async () => {
        await handle.close();
        await fs.unlink(lock).catch(() => {});
      };
    } catch (error) {
      if (error.code !== "EEXIST") throw error;
    }
    try {
      const owner = JSON.parse(await fs.readFile(lock, "utf8"));
      let dead = false;
      if (Number.isSafeInteger(owner.pid) && owner.pid > 0)
        try {
          process.kill(owner.pid, 0);
        } catch (e) {
          dead = e.code === "ESRCH";
        }
      if (dead) {
        // Serialize dead-owner cleanup too: a second contender must not unlink
        // the live lock acquired after the first contender removed a stale one.
        let reaper;
        try {
          reaper = await fs.open(`${lock}.reap`, "wx", 0o600);
          const current = JSON.parse(await fs.readFile(lock, "utf8"));
          let stillDead = false;
          if (Number.isSafeInteger(current.pid) && current.pid > 0)
            try {
              process.kill(current.pid, 0);
            } catch (e) {
              stillDead = e.code === "ESRCH";
            }
          if (stillDead) await fs.unlink(lock).catch(() => {});
        } catch {
        } finally {
          if (reaper) {
            await reaper.close();
            await fs.unlink(`${lock}.reap`).catch(() => {});
          }
        }
      }
    } catch {}
    if (Date.now() >= deadline) throw new Error("无法确认桌宠显示设置");
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
}
function serialize(file, operation) {
  const key = path.resolve(file);
  const previous = queues.get(key) || Promise.resolve();
  const next = previous
    .catch(() => {})
    .then(async () => {
      const release = await lockFile(key);
      try {
        return await operation();
      } finally {
        await release();
      }
    });
  queues.set(key, next);
  return next.finally(() => {
    if (queues.get(key) === next) queues.delete(key);
  });
}
const validTime = (n) => typeof n === "number" && Number.isFinite(n) && n > 0;
const validProcess = (p) =>
  p && Number.isSafeInteger(p.pid) && p.pid > 0 && validTime(p.startedAt);
class VisibilityIntent {
  constructor(storePath) {
    this.storePath = storePath;
    this.state = null;
    this.generation = null;
  }
  load() {
    return serialize(this.storePath, () => this._load());
  }
  hide(processes = [], now = Date.now() / 1000) {
    return serialize(this.storePath, () => this._hide(processes, now));
  }
  showExplicitly() {
    return serialize(this.storePath, () => this._showExplicitly());
  }
  shouldShowOnReopen(processes) {
    return serialize(this.storePath, () => this._shouldShowOnReopen(processes));
  }
  async _load() {
    try {
      const stat = await fs.stat(this.storePath);
      const bytes = await fs.readFile(this.storePath, "utf8");
      this.generation = bytes;
      let saved;
      try {
        saved = JSON.parse(bytes);
      } catch {}
      const recordedAt = Math.max(
        stat.mtimeMs / 1000,
        validTime(saved?.recordedAt) ? saved.recordedAt : 0,
      );
      this.state = {
        recordedAt,
        suppressedProcesses:
          Array.isArray(saved?.suppressedProcesses) &&
          saved.suppressedProcesses.every(validProcess)
            ? saved.suppressedProcesses
            : [],
      };
    } catch (e) {
      if (e.code === "ENOENT") {
        this.state = null;
        this.generation = null;
      } else {
        this.state = { recordedAt: null, suppressedProcesses: [] };
        this.generation = null;
      }
    }
    return this;
  }
  async _hide(processes = [], now = Date.now() / 1000) {
    const saved = {
      suppressedProcesses: processes
        .filter(validProcess)
        .map(({ pid, startedAt }) => ({ pid, startedAt })),
      recordedAt: now,
    };
    await fs.mkdir(path.dirname(this.storePath), { recursive: true });
    const temporary = `${this.storePath}.${randomUUID()}.tmp`;
    try {
      await fs.writeFile(temporary, JSON.stringify(saved), { mode: 0o600 });
      await fs.rename(temporary, this.storePath);
    } finally {
      await fs.unlink(temporary).catch(() => {});
    }
    await this._load();
  }
  async _showExplicitly() {
    await fs.unlink(this.storePath).catch((e) => {
      if (e.code !== "ENOENT") throw e;
    });
    this.state = null;
    this.generation = null;
  }
  async _shouldShowOnReopen(processes) {
    // The UI and watcher are separate processes. Reload under the shared
    // lock, including when an earlier load saw no suppression file.
    const previousGeneration = this.generation;
    await this._load();
    if (this.state && this.generation !== previousGeneration) return false;
    if (!this.state) return true;
    if (!Array.isArray(processes)) return false;
    const known = processes.filter(validProcess);
    const restored = known.some(
      (p) =>
        !this.state.suppressedProcesses.some(
          (old) => old.pid === p.pid && old.startedAt === p.startedAt,
        ) &&
        validTime(this.state.recordedAt) &&
        p.startedAt >= this.state.recordedAt + 2,
    );
    if (!restored || this.generation === null) return false;
    try {
      if ((await fs.readFile(this.storePath, "utf8")) !== this.generation)
        return false;
      await this._showExplicitly();
      return true;
    } catch {
      return false;
    }
  }
}
module.exports = { VisibilityIntent };
