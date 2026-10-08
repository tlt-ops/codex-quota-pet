from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import timedelta, timezone
from io import StringIO
from pathlib import Path
from unittest.mock import patch


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))

from quota_client import (  # noqa: E402
    QuotaReadError,
    TransientServerError,
    _is_transient_internal_error,
    _read_initialized_session,
    format_rate_limits,
    main,
    successful_snapshot,
    write_snapshot,
)


LOCAL_TZ = timezone(timedelta(hours=8))
FIXTURE = Path(__file__).resolve().parent / "fixtures" / "rate_limits_sample.json"


class QuotaClientTests(unittest.TestCase):
    def setUp(self) -> None:
        self.sample = json.loads(FIXTURE.read_text(encoding="utf-8"))

    def test_codex_bucket_and_three_compact_lines(self) -> None:
        self.assertEqual(
            format_rate_limits(self.sample, LOCAL_TZ),
            ["额度 53%（7天）", "重置 10-04 12:34", "重置次数 1次"],
        )

    def test_structured_primary_matches_displayed_window(self) -> None:
        snapshot = successful_snapshot(self.sample, LOCAL_TZ)
        self.assertEqual(snapshot["status"], "ok")
        self.assertEqual(snapshot["lines"], format_rate_limits(self.sample, LOCAL_TZ))
        self.assertEqual(snapshot["quota"], {
            "bucketId": "codex", "windowKind": "primary",
            "windowDurationMins": 10080, "usedPercent": 47,
            "remainingPercent": 53, "resetsAt": 1791088440,
            "availableCount": 1, "sampleId": snapshot["quota"]["sampleId"],
        })
        self.assertRegex(snapshot["quota"]["sampleId"], r"^[0-9a-f]{32}$")

    def test_structured_secondary_fallback(self) -> None:
        self.sample["rateLimitsByLimitId"]["codex"].pop("primary")
        snapshot = successful_snapshot(self.sample, LOCAL_TZ)
        quota = snapshot["quota"]
        self.assertEqual((quota["bucketId"], quota["windowKind"]), ("codex", "secondary"))
        self.assertEqual(quota["windowDurationMins"], 300)
        self.assertEqual(quota["usedPercent"], 20)
        self.assertEqual(quota["remainingPercent"], 80)
        self.assertEqual(snapshot["lines"], format_rate_limits(self.sample, LOCAL_TZ))

    def test_structured_legacy_fallback_and_clamping(self) -> None:
        self.sample.pop("rateLimitsByLimitId")
        self.sample["rateLimits"]["primary"]["usedPercent"] = 120
        snapshot = successful_snapshot(self.sample, LOCAL_TZ)
        quota = snapshot["quota"]
        self.assertEqual((quota["bucketId"], quota["windowKind"]), ("legacy", "primary"))
        self.assertEqual(quota["usedPercent"], 120)
        self.assertEqual(quota["remainingPercent"], 0)
        self.assertEqual(snapshot["lines"][0], "额度 0%（5小时）")

    def test_snapshot_ids_are_unique_even_when_values_and_time_match(self) -> None:
        with patch("quota_client.time.time", return_value=1791088440):
            first = successful_snapshot(self.sample, LOCAL_TZ)
            second = successful_snapshot(self.sample, LOCAL_TZ)
        self.assertEqual(first["updatedAt"], second["updatedAt"])
        self.assertNotEqual(first["quota"]["sampleId"], second["quota"]["sampleId"])

    def test_success_timestamp_keeps_subsecond_precision(self) -> None:
        with patch("quota_client.time.time", return_value=1791088440.875):
            snapshot = successful_snapshot(self.sample, LOCAL_TZ)
        self.assertEqual(snapshot["updatedAt"], 1791088440.875)

    def test_invalid_optional_values_are_json_safe_and_unknown(self) -> None:
        window = self.sample["rateLimitsByLimitId"]["codex"]["primary"]
        window["windowDurationMins"] = -3
        window["resetsAt"] = float("inf")
        self.sample["rateLimitResetCredits"]["availableCount"] = True
        snapshot = successful_snapshot(self.sample, LOCAL_TZ)
        quota = snapshot["quota"]
        self.assertIsNone(quota["windowDurationMins"])
        self.assertIsNone(quota["resetsAt"])
        self.assertIsNone(quota["availableCount"])
        self.assertEqual(snapshot["lines"], ["额度 53%", "重置 未知", "重置次数 未知"])
        json.dumps(snapshot, allow_nan=False)

    def test_fractional_usage_display_integer_is_exact_match(self) -> None:
        self.sample["rateLimitsByLimitId"]["codex"]["primary"]["usedPercent"] = 48.4
        snapshot = successful_snapshot(self.sample, LOCAL_TZ)
        quota = snapshot["quota"]
        self.assertEqual(quota["usedPercent"], 48.4)
        self.assertEqual(quota["remainingPercent"], 52)
        self.assertIn(f"额度 {quota['remainingPercent']}%", snapshot["lines"][0])

    def test_missing_reset_count_is_unknown(self) -> None:
        self.sample.pop("rateLimitResetCredits")
        self.assertEqual(format_rate_limits(self.sample, LOCAL_TZ)[2], "重置次数 未知")
        self.assertIsNone(successful_snapshot(self.sample, LOCAL_TZ)["quota"]["availableCount"])

    def test_legacy_bucket_and_clamping(self) -> None:
        self.sample.pop("rateLimitsByLimitId")
        self.sample["rateLimits"]["primary"]["usedPercent"] = 120
        self.assertEqual(format_rate_limits(self.sample, LOCAL_TZ)[0], "额度 0%（5小时）")

    def test_missing_windows_is_error(self) -> None:
        with self.assertRaises(QuotaReadError):
            format_rate_limits({"rateLimits": {}}, LOCAL_TZ)

    def test_snapshot_is_private_json(self) -> None:
        payload = {"status": "ok", "updatedAt": 1791088440, "lines": ["额度 53%（7天）"]}
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "quota.json"
            write_snapshot(path, payload)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8")), payload)
            self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_failed_refresh_replaces_prior_quota_without_stale_machine_data(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "quota.json"
            with patch("quota_client.read_rate_limits", return_value=self.sample):
                with redirect_stdout(StringIO()):
                    self.assertEqual(main(["--output", str(path)]), 0)
            self.assertIn("quota", json.loads(path.read_text(encoding="utf-8")))
            with patch("quota_client.read_rate_limits", side_effect=QuotaReadError("Codex 未能读取额度")):
                with redirect_stdout(StringIO()):
                    self.assertEqual(main(["--output", str(path)]), 1)
            failure = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(failure["status"], "error")
            self.assertEqual(failure["lines"], ["额度暂不可用"])
            self.assertEqual(failure["detail"], "Codex 未能读取额度")
            self.assertNotIn("quota", failure)

    def test_only_non_auth_internal_error_is_retried(self) -> None:
        self.assertTrue(_is_transient_internal_error({"code": -32603, "message": "upstream request failed"}))
        self.assertFalse(_is_transient_internal_error({"code": -32603, "message": "401 Unauthorized"}))
        self.assertFalse(_is_transient_internal_error({"code": -32602, "message": "invalid params"}))

    def test_one_bounded_retry_after_transient_error(self) -> None:
        responses = [
            TransientServerError("temporary"),
            {"account": {"type": "chatgpt"}},
            self.sample,
        ]
        with patch("quota_client._send") as send, patch("quota_client._response_for", side_effect=responses) as response:
            result = _read_initialized_session(object(), 123.0, bytearray())
        self.assertIs(result, self.sample)
        self.assertEqual([item.args[1]["id"] for item in send.call_args_list], [2, 3, 4])
        self.assertEqual([item.args[1] for item in response.call_args_list], [2, 3, 4])


if __name__ == "__main__":
    unittest.main()
