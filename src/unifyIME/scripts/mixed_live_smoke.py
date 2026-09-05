#!/usr/bin/env python3
"""Fast continuous raw-key smoke test shared with the live mixed-input path."""

import json
import os
import subprocess
import tempfile
from pathlib import Path


def resolve_workspace_root() -> Path:
    explicit = os.environ.get("UNIFYIME_WORKSPACE_ROOT") or os.environ.get("FASTCHIME_WORKSPACE_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


ROOT = resolve_workspace_root()
APP = Path(os.environ.get("UNIFYIME_CLI_PATH", str(ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME")))
CASES = [
    ("pure-zh", "wu0fu4", "天氣", True),
    ("pure-en", "verygood", "very good", True),
    ("zh-en", "wu0fu4very", "天氣 very", True),
    ("en-zh", "verywu0fu4", "very 天氣", True),
    ("zh-en-split", "wu0fu4verygood", "天氣 very good", True),
    ("long-zh-en", "rupwu0wu0fu4verygood", "今天天氣 very good", True),
    # Uncommitted prefixes catch transient language flips while typing.
    ("prefix-everyb", "everyb", "everyb", False),
    ("prefix-everybo", "everybo", "everybo", False),
    ("prefix-everybod", "everybod", "everybod", False),
    ("prefix-veryg", "veryg", "veryg", False),
    ("prefix-projectm", "projectm", "projectm", False),
    ("mixed-prefix-everyb", "wu0fu4everyb", "天氣 everyb", False),
    ("mixed-prefix-veryg", "5k4ek7veryg", "這個 veryg", False),
    # Long, uninterrupted raw streams with repeated language switches.
    (
        "long-everybody-verygood",
        "rupwu0wu0fu4everybody2.rm,62k7verygood",
        "今天天氣 everybody 都覺得 very good",
        True,
    ),
    (
        "long-project-everybody",
        "ji3vu;3m/4projecthk4g4everybody2u6ru,6eji3",
        "我想用 project 測試 everybody 的結果",
        True,
    ),
    (
        "long-feature-everybody-test",
        "5k4ek7featureflagvmul4everybodyufu3test",
        "這個 feature flag 需要 everybody 一起 test",
        True,
    ),
    (
        "long-input-token",
        "fu/31;jifm,4bp4inputtokeng4z.3dk3u35/4t;6tj3xu3",
        "請幫我確認 input token 是否可以正常處理",
        True,
    ),
    (
        "long-project-meetings",
        "284ru85/4y94g3m/4projectmeetingsgjbj4z83",
        "大家正在使用 project meetings 輸入法",
        True,
    ),
    (
        "long-english-first",
        "everybody2.rm,62k7projectmeetingscp3cl3",
        "everybody 都覺得 project meetings 很好",
        True,
    ),
    (
        "long-three-switches",
        "rupwu0wu0fu4verygood284ru85/4y94g3m/4featureflaghk4g4everybody",
        "今天天氣 very good 大家正在使用 feature flag 測試 everybody",
        True,
    ),
    (
        "long-marathon",
        "fu/31;jifm,4bp4everybodyg4z.3dk3u35/4t;6tj3xu3projectmeetings2u6inputtoken",
        "請幫我確認 everybody 是否可以正常處理 project meetings 的 input token",
        True,
    ),
]

# Keep representative long cases fully incremental to exercise the live
# per-keystroke path past the old 30-key limit. Other long cases are delivered
# as one uninterrupted raw token so the regular smoke remains fast while still
# validating final span materialization without artificial Enter boundaries.
INCREMENTAL_LONG_CASES = {case_id for case_id, _, _, _ in CASES if case_id.startswith("long-")}


def main() -> int:
    if not APP.is_file():
        print(f"FAIL app missing: {APP}")
        return 2

    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".jsonl", delete=False) as handle:
        input_path = Path(handle.name)
        for case_id, raw, _, should_commit in CASES:
            is_incremental = not case_id.startswith("long-") or case_id in INCREMENTAL_LONG_CASES
            raw_keys = [f"raw:{character}" for character in raw] if is_incremental else [f"raw:{raw}"]
            row = {
                "row_id": case_id,
                "row_keys": raw_keys + (["enter"] if should_commit else []),
            }
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    try:
        result = subprocess.run(
            [str(APP), "ime-action-batch-replay", str(input_path)],
            text=True,
            capture_output=True,
            timeout=120,
        )
    finally:
        input_path.unlink(missing_ok=True)

    if result.returncode != 0:
        print(result.stdout, end="")
        print(result.stderr, end="")
        return result.returncode

    outputs: dict[str, dict[str, object]] = {}
    for line in result.stdout.splitlines():
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        row_id = str(payload.get("row_id", ""))
        if row_id:
            outputs[row_id] = payload

    failures = 0
    for case_id, raw, expected, _ in CASES:
        payload = outputs.get(case_id, {})
        actual = str(payload.get("text", ""))
        if actual == expected:
            print(f"PASS {case_id}: {actual}")
            continue
        failures += 1
        print(f"FAIL {case_id}: raw={raw} expected={expected!r} actual={actual!r}")

    print(f"TOTAL {len(CASES)} PASS {len(CASES) - failures} FAIL {failures}")
    return 0 if failures == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
