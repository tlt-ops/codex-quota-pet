#!/usr/bin/env python3
"""Read Codex's own rate-limit API and publish a small, local UI snapshot.

No credential files are read here. The installed Codex CLI handles its own
authentication inside a short-lived app-server subprocess.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import select
import shutil
import subprocess
import sys
import tempfile
import time
import uuid
from datetime import datetime, tzinfo
from pathlib import Path
from typing import Any


DEFAULT_OUTPUT = (
    Path.home() / "Library" / "Application Support" / "CodexQuotaPet" / "quota.json"
)
MAX_LINE_BYTES = 2 * 1024 * 1024


class QuotaReadError(Exception):
    """A short, safe message suitable for the UI or command line."""


class TransientServerError(QuotaReadError):
    """A rate-limit read returned an internal error without an auth indicator."""


def _is_transient_internal_error(error: Any) -> bool:
    if not isinstance(error, dict) or error.get("code") != -32603:
        return False
    message = str(error.get("message", "")).lower()
    auth_markers = (
        "auth", "unauthorized", "forbidden", "login", "log in", "sign in",
        "credential", "access token", "refresh token", "401", "403",
    )
    return not any(marker in message for marker in auth_markers)


def find_codex_cli() -> str:
    candidates = [
        shutil.which("codex"),
        str(Path.home() / ".local" / "bin" / "codex"),
        "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
        "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
    ]
    for candidate in candidates:
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise QuotaReadError("找不到 Codex CLI")


def _send(proc: subprocess.Popen[bytes], message: dict[str, Any]) -> None:
    if proc.stdin is None:
        raise QuotaReadError("无法连接 Codex")
    try:
        proc.stdin.write((json.dumps(message, separators=(",", ":")) + "\n").encode())
        proc.stdin.flush()
    except (BrokenPipeError, OSError) as exc:
        raise QuotaReadError("Codex 连接已断开") from exc


def _response_for(
    proc: subprocess.Popen[bytes], request_id: int, deadline: float, pending: bytearray
) -> dict[str, Any]:
    if proc.stdout is None:
        raise QuotaReadError("无法读取 Codex 响应")
    fd = proc.stdout.fileno()
    while True:
        while b"\n" in pending:
            raw, _, remainder = pending.partition(b"\n")
            pending[:] = remainder
            if not raw.strip():
                continue
            try:
                message = json.loads(raw)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise QuotaReadError("Codex 响应格式错误") from exc
            if not isinstance(message, dict) or message.get("id") != request_id:
                # App-server may send unrelated notifications while a request is pending.
                continue
            if "error" in message:
                # Never surface server error text: it may contain account details.
                if _is_transient_internal_error(message["error"]):
                    raise TransientServerError("Codex 暂时无法读取额度")
                raise QuotaReadError("Codex 未能读取额度")
            result = message.get("result")
            if not isinstance(result, dict):
                raise QuotaReadError("Codex 额度响应格式不支持")
            return result

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise QuotaReadError("连接 Codex 超时")
        try:
            ready, _, _ = select.select([fd], [], [], remaining)
            if not ready:
                raise QuotaReadError("连接 Codex 超时")
            chunk = os.read(fd, 65536)
        except OSError as exc:
            raise QuotaReadError("无法读取 Codex 响应") from exc
        if not chunk:
            raise QuotaReadError("Codex 连接已断开")
        pending.extend(chunk)
        if len(pending) > MAX_LINE_BYTES:
            raise QuotaReadError("Codex 响应过长")


def read_rate_limits(timeout_seconds: float = 20.0) -> dict[str, Any]:
    if timeout_seconds <= 0:
        raise ValueError("timeout_seconds must be positive")
    deadline = time.monotonic() + timeout_seconds
    try:
        proc: subprocess.Popen[bytes] = subprocess.Popen(
            [find_codex_cli(), "app-server", "--listen", "stdio://"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
    except OSError as exc:
        raise QuotaReadError("无法启动 Codex CLI") from exc

    pending = bytearray()
    try:
        _send(
            proc,
            {
                "id": 1,
                "method": "initialize",
                "params": {
                    "clientInfo": {"name": "codex-quota-pet", "version": "0.1.0"},
                    "capabilities": {},
                },
            },
        )
        _response_for(proc, 1, deadline, pending)
        _send(proc, {"method": "initialized"})
        return _read_initialized_session(proc, deadline, pending)
    finally:
        if proc.stdin is not None:
            proc.stdin.close()
        if proc.poll() is None:
            proc.terminate()
            try:
                proc.wait(timeout=1)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait(timeout=1)


def _read_initialized_session(
    proc: subprocess.Popen[bytes], deadline: float, pending: bytearray
) -> dict[str, Any]:
    _send(proc, {"id": 2, "method": "account/rateLimits/read"})
    try:
        return _response_for(proc, 2, deadline, pending)
    except TransientServerError:
        # One read-only account refresh and one retry, both under the original deadline.
        _send(proc, {"id": 3, "method": "account/read", "params": {}})
        account = _response_for(proc, 3, deadline, pending)
        if not isinstance(account.get("account"), dict):
            raise QuotaReadError("请先登录 Codex")
        _send(proc, {"id": 4, "method": "account/rateLimits/read"})
        return _response_for(proc, 4, deadline, pending)


def _duration_label(value: Any) -> str:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        return ""
    if value % 1440 == 0:
        return f"{value // 1440}天"
    if value % 60 == 0:
        return f"{value // 60}小时"
    return f"{value}分钟"


def _reset_label(value: Any, local_tz: tzinfo | None = None) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return "未知"
    try:
        date = datetime.fromtimestamp(value, tz=local_tz)
    except (OverflowError, OSError, ValueError):
        return "未知"
    return date.strftime("%m-%d %H:%M")


def _display_quota(result: dict[str, Any]) -> dict[str, Any]:
    """Normalize the exact rate-limit window used by the three UI lines."""
    by_id = result.get("rateLimitsByLimitId")
    bucket = by_id.get("codex") if isinstance(by_id, dict) else None
    bucket_id = "codex"
    if not isinstance(bucket, dict):
        bucket = result.get("rateLimits")
        bucket_id = "legacy"
    if not isinstance(bucket, dict):
        raise QuotaReadError("Codex 额度响应格式不支持")

    window = bucket.get("primary")
    window_kind = "primary"
    if not isinstance(window, dict):
        window = bucket.get("secondary")
        window_kind = "secondary"
    if not isinstance(window, dict):
        raise QuotaReadError("Codex 暂无可显示的额度")
    used = window.get("usedPercent")
    if isinstance(used, bool) or not isinstance(used, (int, float)):
        raise QuotaReadError("Codex 暂无可显示的额度")
    try:
        finite = math.isfinite(used)
    except OverflowError:
        finite = False
    if not finite:
        raise QuotaReadError("Codex 暂无可显示的额度")

    duration = window.get("windowDurationMins")
    if isinstance(duration, bool) or not isinstance(duration, int) or duration <= 0:
        duration = None
    reset_at = window.get("resetsAt")
    try:
        valid_reset_at = (not isinstance(reset_at, bool)
                          and isinstance(reset_at, (int, float))
                          and math.isfinite(reset_at) and reset_at > 0)
    except OverflowError:
        valid_reset_at = False
    if not valid_reset_at:
        reset_at = None
    elif isinstance(reset_at, float) and reset_at.is_integer():
        reset_at = int(reset_at)
    if reset_at is not None and _reset_label(reset_at) == "未知":
        reset_at = None

    remaining = max(0, min(100, round(100 - used)))
    credits = result.get("rateLimitResetCredits")
    count = credits.get("availableCount") if isinstance(credits, dict) else None
    if isinstance(count, bool) or not isinstance(count, int) or count < 0:
        count = None
    return {
        "bucketId": bucket_id,
        "windowKind": window_kind,
        "windowDurationMins": duration,
        "usedPercent": used,
        "remainingPercent": remaining,
        "resetsAt": reset_at,
        "availableCount": count,
    }


def _quota_lines(quota: dict[str, Any], local_tz: tzinfo | None = None) -> list[str]:
    duration = _duration_label(quota["windowDurationMins"])
    remaining = quota["remainingPercent"]
    quota_line = f"额度 {remaining}%（{duration}）" if duration else f"额度 {remaining}%"
    reset_line = f"重置 {_reset_label(quota['resetsAt'], local_tz)}"
    count = quota["availableCount"]
    credits_line = "重置次数 未知" if count is None else f"重置次数 {count}次"
    return [quota_line, reset_line, credits_line]


def format_rate_limits(result: dict[str, Any], local_tz: tzinfo | None = None) -> list[str]:
    """Use the Codex bucket when available, falling back to the legacy bucket."""
    return _quota_lines(_display_quota(result), local_tz)


def successful_snapshot(result: dict[str, Any], local_tz: tzinfo | None = None) -> dict[str, Any]:
    """One successful refresh, with matching display and machine-readable data."""
    quota = _display_quota(result)
    quota["sampleId"] = uuid.uuid4().hex
    return {"status": "ok", "updatedAt": time.time(),
            "lines": _quota_lines(quota, local_tz), "quota": quota}


def write_snapshot(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    data = (json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
    temp_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(prefix=".quota-", suffix=".tmp", dir=path.parent, delete=False) as temp:
            temp_name = temp.name
            os.fchmod(temp.fileno(), 0o600)
            temp.write(data)
            temp.flush()
            os.fsync(temp.fileno())
        os.replace(temp_name, path)
        temp_name = None
    finally:
        if temp_name is not None:
            try:
                os.unlink(temp_name)
            except FileNotFoundError:
                pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="读取 Codex 剩余额度和重置时间")
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help="本地 JSON 快照路径")
    parser.add_argument("--timeout", type=float, default=20.0, help="总超时秒数")
    args = parser.parse_args(argv)

    try:
        payload: dict[str, Any] = successful_snapshot(read_rate_limits(args.timeout))
        exit_code = 0
    except QuotaReadError as exc:
        message = str(exc)
        payload = {"status": "error", "updatedAt": int(time.time()), "lines": ["额度暂不可用"], "detail": message}
        exit_code = 1
    except (OSError, ValueError) as exc:
        message = "无法保存额度" if isinstance(exc, OSError) else "额度读取参数无效"
        payload = {"status": "error", "updatedAt": int(time.time()), "lines": ["额度暂不可用"], "detail": message}
        exit_code = 1

    try:
        write_snapshot(args.output, payload)
    except OSError:
        print("无法保存额度快照", file=sys.stderr)
        return 1
    print(" | ".join(payload["lines"]) if exit_code == 0 else payload["detail"])
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
