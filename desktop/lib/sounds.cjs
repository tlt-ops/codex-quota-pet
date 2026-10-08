"use strict";
const fs = require("node:fs/promises");
const path = require("node:path");
const https = require("node:https");
const { createHash, randomUUID } = require("node:crypto");
const none = () => ({ damageCount: 0, playXP: false });
const finite = (n) => typeof n === "number" && Number.isFinite(n);
function valid(sample) {
  return (
    sample &&
    ["bucketId", "windowKind", "sampleId"].every(
      (k) => typeof sample[k] === "string" && sample[k].length,
    ) &&
    finite(sample.updatedAt) &&
    finite(sample.usedPercent) &&
    Number.isInteger(sample.remainingPercent) &&
    sample.remainingPercent >= 0 &&
    sample.remainingPercent <= 100 &&
    (sample.windowDurationMins == null ||
      (Number.isSafeInteger(sample.windowDurationMins) &&
        sample.windowDurationMins > 0)) &&
    (sample.availableCount == null ||
      (Number.isSafeInteger(sample.availableCount) &&
        sample.availableCount >= 0)) &&
    (sample.resetsAt == null ||
      (finite(sample.resetsAt) && sample.resetsAt > 0))
  );
}
class QuotaSoundDetector {
  constructor(startedAt = Date.now() / 1000) {
    this.startedAt = startedAt;
    this.seen = new Set();
    this.recent = [];
    this.latestUpdatedAt = -Infinity;
    this.resetBaseline();
  }
  resetBaseline() {
    this.previous = null;
    this.consumedBoundaryAt = null;
    this.notifiedResetAt = null;
    this.nextResetAt = null;
  }
  noteFailure(updatedAt) {
    if (finite(updatedAt))
      this.latestUpdatedAt = Math.max(this.latestUpdatedAt, updatedAt);
    this.resetBaseline();
  }
  accept(sample, now = Date.now() / 1000) {
    // Accept the wire snapshot directly as well as a flattened pure sample.
    if (sample?.quota)
      sample = { ...sample.quota, updatedAt: sample.updatedAt };
    if (
      !finite(now) ||
      !valid(sample) ||
      sample.updatedAt < this.startedAt ||
      sample.updatedAt < this.latestUpdatedAt ||
      this.seen.has(sample.sampleId)
    )
      return none();
    this.latestUpdatedAt = sample.updatedAt;
    this.seen.add(sample.sampleId);
    this.recent.push(sample.sampleId);
    if (this.recent.length > 128) this.seen.delete(this.recent.shift());
    const old = this.previous;
    if (
      !old ||
      ["bucketId", "windowKind", "windowDurationMins"].some(
        (k) => sample[k] !== old[k],
      )
    ) {
      this.previous = sample;
      this.notifiedResetAt = null;
      this.consumedBoundaryAt =
        sample.resetsAt != null && sample.resetsAt <= now
          ? sample.resetsAt
          : null;
      this.nextResetAt =
        this.consumedBoundaryAt === null ? sample.resetsAt : null;
      return none();
    }
    const crossed =
      old.resetsAt != null &&
      old.resetsAt <= now &&
      this.consumedBoundaryAt !== old.resetsAt;
    const advanced =
      old.resetsAt != null &&
      sample.resetsAt != null &&
      sample.resetsAt > old.resetsAt;
    const gained = sample.remainingPercent > old.remainingPercent;
    const creditsGained =
      old.availableCount != null &&
      sample.availableCount != null &&
      sample.availableCount > old.availableCount;
    const already =
      old.resetsAt != null &&
      this.notifiedResetAt === old.resetsAt &&
      (old.resetsAt <= now || advanced);
    const playXP = creditsGained || (!already && (crossed || gained));
    const damageCount =
      crossed || (advanced && old.resetsAt <= now) || gained
        ? 0
        : Math.max(0, old.remainingPercent - sample.remainingPercent);
    if ((crossed || advanced) && playXP) this.notifiedResetAt = old.resetsAt;
    this.previous = sample;
    this.consumedBoundaryAt =
      sample.resetsAt != null && sample.resetsAt <= now
        ? sample.resetsAt
        : null;
    this.nextResetAt =
      this.consumedBoundaryAt === null ? sample.resetsAt : null;
    return { damageCount, playXP };
  }
  markResetDue(now = Date.now() / 1000) {
    const deadline = this.nextResetAt;
    if (!finite(now) || deadline == null || now < deadline) return false;
    this.nextResetAt = null;
    this.consumedBoundaryAt = deadline;
    if (this.notifiedResetAt === deadline) return false;
    this.notifiedResetAt = deadline;
    return true;
  }
}
const ASSETS = Object.freeze({
  damage: "c43077ac1f9ceda7e9e1c152f839baf207833aa8",
  xp: "8a04a60d5c28fc60df472a877ca57f37eabc78d7",
});
const hash = (bytes) => createHash("sha1").update(bytes).digest("hex");
const verified = (bytes, sha) =>
  bytes.length <= 1000000 &&
  bytes.subarray(0, 4).toString() === "OggS" &&
  hash(bytes) === sha;
function download(url) {
  return new Promise((resolve, reject) => {
    const req = https.get(url, (res) => {
      if (res.statusCode !== 200) {
        res.resume();
        return reject(new Error("音效下载失败"));
      }
      const chunks = [];
      let size = 0;
      res.on("data", (chunk) => {
        size += chunk.length;
        if (size > 1000000) {
          req.destroy();
          reject(new Error("音效文件过大"));
        } else chunks.push(chunk);
      });
      res.on("end", () => resolve(Buffer.concat(chunks)));
      res.on("error", () => reject(new Error("音效下载失败")));
    });
    req.setTimeout(15000, () => req.destroy(new Error("音效下载超时")));
    req.on("error", () => reject(new Error("音效下载失败")));
  });
}
async function prepareSound(
  kind,
  cacheDir,
  { download: fetch = download } = {},
) {
  const sha = ASSETS[kind];
  if (!sha) throw new Error("未知音效");
  const destination = path.join(cacheDir, `${sha}.ogg`);
  let bytes;
  try {
    const stat = await fs.stat(destination);
    if (stat.size <= 1000000) bytes = await fs.readFile(destination);
  } catch {}
  if (!bytes || !verified(bytes, sha)) {
    bytes = Buffer.from(
      await fetch(
        `https://resources.download.minecraft.net/${sha.slice(0, 2)}/${sha}`,
      ),
    );
    if (!verified(bytes, sha)) throw new Error("音效校验失败");
    await fs.mkdir(cacheDir, { recursive: true });
    const temporary = `${destination}.${randomUUID()}.tmp`;
    try {
      await fs.writeFile(temporary, bytes);
      await fs.rename(temporary, destination);
    } finally {
      await fs.unlink(temporary).catch(() => {});
    }
    bytes = await fs.readFile(destination);
    if (!verified(bytes, sha)) throw new Error("音效校验失败");
  }
  return `data:audio/ogg;base64,${bytes.toString("base64")}`;
}
module.exports = { QuotaSoundDetector, prepareSound, ASSETS };
