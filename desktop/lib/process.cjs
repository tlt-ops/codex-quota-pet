"use strict";
const { execFile } = require("node:child_process");
const path = require("node:path");
const SCRIPT = `Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe' OR Name='Codex.exe'" | Select-Object ProcessId,ExecutablePath,CommandLine,@{Name='StartedAt';Expression={$_.CreationDate.ToUniversalTime().ToString('o')}} | ConvertTo-Json -Compress`;
function parseProcesses(text) {
  const data = JSON.parse(text.replace(/^\uFEFF/, "").trim() || "[]");
  return (Array.isArray(data) ? data : [data]).flatMap((p) => {
    if (
      !p ||
      !Number.isSafeInteger(p.ProcessId) ||
      p.ProcessId <= 0 ||
      typeof p.ExecutablePath !== "string"
    )
      return [];
    if (!/^(chatgpt|codex)\.exe$/i.test(path.win32.basename(p.ExecutablePath)))
      return [];
    const executable = p.ExecutablePath.replace(/\//g, "\\");
    if (/(?:^|\\)(?:vendor|node_modules|codex-cli)(?:\\|$)/i.test(executable))
      return [];
    // Main Electron applications reside in a named installation directory.
    if (
      !/(?:^|\\)(?:OpenAI\.)?(?:Codex|ChatGPT)(?:_[^\\]+)?(?:\\|$)/i.test(
        path.win32.dirname(executable),
      )
    )
      return [];
    // Unknown command lines cannot reliably distinguish Electron helpers.
    if (
      typeof p.CommandLine !== "string" ||
      /(?:^|\s)--type(?:=|\s)|(?:^|\s)app-server(?:\s|$)/i.test(p.CommandLine)
    )
      return [];
    const startedAt = Date.parse(p.StartedAt) / 1000;
    return [
      {
        pid: p.ProcessId,
        startedAt: Number.isFinite(startedAt) ? startedAt : null,
        executable: p.ExecutablePath,
      },
    ];
  });
}
async function getCodexProcesses({
  platform = process.platform,
  execFile: run = execFile,
  timeoutMs = 8000,
} = {}) {
  if (platform !== "win32") return [];
  return new Promise((resolve, reject) =>
    run(
      "powershell.exe",
      ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", SCRIPT],
      {
        windowsHide: true,
        timeout: timeoutMs,
        maxBuffer: 2 * 1024 * 1024,
        encoding: "utf8",
      },
      (err, out) => {
        if (err) return reject(new Error("无法确认 Codex 桌面进程"));
        try {
          resolve(parseProcesses(out));
        } catch {
          reject(new Error("无法确认 Codex 桌面进程"));
        }
      },
    ),
  );
}
module.exports = { getCodexProcesses, parseProcesses };
