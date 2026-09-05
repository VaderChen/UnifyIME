#!/usr/bin/env python3
"""Replay source-attributed, paraphrased Chinese/English article cases."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import tempfile
import time
from collections import Counter
from pathlib import Path
from typing import Any


def resolve_workspace_root() -> Path:
    explicit = os.environ.get("UNIFYIME_WORKSPACE_ROOT") or os.environ.get("FASTCHIME_WORKSPACE_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


ROOT = resolve_workspace_root()
APP = Path(os.environ.get("UNIFYIME_CLI_PATH", str(ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME")))
CASE_FILE = ROOT / "src" / "unifyIME" / "tests" / "web_mixed_sentences.jsonl"
MAX_MIXED_RAW_KEYS = 120
DEFAULT_INCREMENTAL_CASES = {"ms-001", "apple-005", "mdn-002", "ibm-001"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--strict",
        action="store_true",
        help="Treat exploratory mismatches as failures too.",
    )
    parser.add_argument(
        "--list",
        action="store_true",
        help="List source URLs and expected sentences without replaying them.",
    )
    parser.add_argument(
        "--full-incremental",
        action="store_true",
        help="Replay every case marked incremental one key at a time (slow stress test).",
    )
    parser.add_argument(
        "--case",
        dest="case_ids",
        action="append",
        help="Run only the selected case_id; may be repeated.",
    )
    parser.add_argument(
        "--segment-batch",
        action="store_true",
        help="Send non-incremental cases as language-segment chunks instead of one raw token.",
    )
    return parser.parse_args()


def load_cases() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    with CASE_FILE.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            case_id = str(payload.get("case_id", ""))
            if not case_id or case_id in seen_ids:
                raise ValueError(f"line {line_number}: missing or duplicate case_id {case_id!r}")
            if payload.get("tier") not in {"regression", "exploratory"}:
                raise ValueError(f"line {line_number}: invalid tier")
            if payload.get("replay") not in {"incremental", "batch"}:
                raise ValueError(f"line {line_number}: invalid replay mode")
            segments = payload.get("segments")
            if not isinstance(segments, list) or not segments:
                raise ValueError(f"line {line_number}: segments must be a non-empty list")
            if not any(segment.get("lang") == "zh" for segment in segments):
                raise ValueError(f"line {line_number}: at least one Chinese segment is required")
            if not any(segment.get("lang") == "en" for segment in segments):
                raise ValueError(f"line {line_number}: at least one English segment is required")
            seen_ids.add(case_id)
            cases.append(payload)
    return cases


def run(command: list[str], timeout: int = 180) -> subprocess.CompletedProcess[str]:
    return subprocess.run(command, text=True, capture_output=True, timeout=timeout)


def build_chinese_raw_map(cases: list[dict[str, Any]]) -> tuple[dict[str, str], list[str]]:
    phrases = list(
        dict.fromkeys(
            str(segment["text"])
            for case in cases
            for segment in case["segments"]
            if segment.get("lang") == "zh"
        )
    )
    with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".txt", delete=False) as handle:
        input_path = Path(handle.name)
        for phrase in phrases:
            handle.write(phrase + "\n")

    try:
        result = run([str(APP), "zh-build-raw-input-batch", str(input_path)])
    finally:
        input_path.unlink(missing_ok=True)

    if result.returncode != 0:
        detail = (result.stdout + result.stderr).strip()
        raise RuntimeError(f"zh-build-raw-input-batch failed: {detail}")

    output_lines = [line for line in result.stdout.splitlines() if line.strip()]
    raw_map: dict[str, str] = {}
    unresolved: list[str] = []
    for phrase, line in zip(phrases, output_lines):
        payload = json.loads(line)
        if not payload.get("resolved"):
            unresolved.append(phrase)
            continue
        row_keys = payload.get("row_keys", [])
        raw = "".join(
            str(key)[4:]
            for key in row_keys
            if isinstance(key, str) and key.startswith("raw:")
        )
        if raw:
            raw_map[phrase] = raw
        else:
            unresolved.append(phrase)
    if len(output_lines) < len(phrases):
        unresolved.extend(phrases[len(output_lines):])
    return raw_map, unresolved


def english_raw(text: str) -> str:
    raw = re.sub(r"\s+", "", text).lower()
    if not raw or not raw.isascii() or not raw.isalpha():
        raise ValueError(f"unsupported English raw segment: {text!r}")
    return raw


def build_case_raw(
    case: dict[str, Any],
    chinese_raw: dict[str, str],
) -> tuple[str | None, list[str], str | None]:
    parts: list[str] = []
    for segment in case["segments"]:
        language = segment.get("lang")
        text = str(segment.get("text", ""))
        if language == "zh":
            raw = chinese_raw.get(text)
            if not raw:
                return None, [], f"unresolved Chinese segment: {text}"
            parts.append(raw)
        elif language == "en":
            try:
                parts.append(english_raw(text))
            except ValueError as error:
                return None, [], str(error)
        else:
            return None, [], f"unsupported segment language: {language!r}"
    raw = "".join(parts)
    if len(raw) > MAX_MIXED_RAW_KEYS:
        return None, [], f"raw length {len(raw)} exceeds {MAX_MIXED_RAW_KEYS}"
    return raw, parts, None


def build_replay_rows(
    cases: list[dict[str, Any]],
    chinese_raw: dict[str, str],
    full_incremental: bool,
    segment_batch: bool,
) -> tuple[list[dict[str, Any]], dict[str, str], dict[str, int]]:
    rows: list[dict[str, Any]] = []
    setup_gaps: dict[str, str] = {}
    raw_lengths: dict[str, int] = {}

    for case in cases:
        case_id = str(case["case_id"])
        raw, raw_parts, error = build_case_raw(case, chinese_raw)
        if error or raw is None:
            setup_gaps[case_id] = error or "unknown setup error"
            continue
        raw_lengths[case_id] = len(raw)
        should_replay_incrementally = case["replay"] == "incremental" and (
            full_incremental or case_id in DEFAULT_INCREMENTAL_CASES
        )
        if should_replay_incrementally:
            row_keys = [f"raw:{character}" for character in raw]
        elif segment_batch:
            row_keys = [f"raw:{part}" for part in raw_parts]
        else:
            row_keys = [f"raw:{raw}"]
        row_keys.append("enter")
        punctuation = str(case.get("punctuation", ""))
        if punctuation:
            row_keys.append(f"punct:{punctuation}")
        rows.append({"row_id": case_id, "row_keys": row_keys})

    return rows, setup_gaps, raw_lengths


def replay(rows: list[dict[str, Any]], chunk_size: int = 40) -> dict[str, dict[str, Any]]:
    outputs: dict[str, dict[str, Any]] = {}
    for chunk_start in range(0, len(rows), chunk_size):
        chunk = rows[chunk_start:chunk_start + chunk_size]
        with tempfile.NamedTemporaryFile("w", encoding="utf-8", suffix=".jsonl", delete=False) as handle:
            input_path = Path(handle.name)
            for row in chunk:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
        try:
            result = run([str(APP), "ime-action-batch-replay", str(input_path)])
        finally:
            input_path.unlink(missing_ok=True)
        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            raise RuntimeError(f"ime-action-batch-replay failed: {detail}")
        if result.stderr and os.environ.get("UNIFYIME_PROFILE_SUMMARY") == "1":
            print(result.stderr, end="")
        for line in result.stdout.splitlines():
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            row_id = str(payload.get("row_id", ""))
            if row_id:
                outputs[row_id] = payload
    return outputs


def print_case_list(cases: list[dict[str, Any]]) -> None:
    previous_source = ""
    for case in cases:
        source = str(case["source_title"])
        if source != previous_source:
            if previous_source:
                print()
            print(f"SOURCE {source}")
            print(str(case["source_url"]))
            previous_source = source
        print(f"- [{case['tier']}] {case['case_id']}: {case['expected']}")


def main() -> int:
    started_at = time.perf_counter()
    args = parse_args()
    if not APP.is_file():
        print(f"FAIL app missing: {APP}")
        return 2

    try:
        cases = load_cases()
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"FAIL invalid case file: {error}")
        return 2

    if args.case_ids:
        selected = set(args.case_ids)
        cases = [case for case in cases if str(case["case_id"]) in selected]
        missing = selected - {str(case["case_id"]) for case in cases}
        if missing:
            print(f"FAIL unknown case_id: {', '.join(sorted(missing))}")
            return 2

    if args.list:
        print_case_list(cases)
        return 0

    try:
        chinese_raw, unresolved_phrases = build_chinese_raw_map(cases)
        rows, setup_gaps, raw_lengths = build_replay_rows(
            cases,
            chinese_raw,
            full_incremental=args.full_incremental,
            segment_batch=args.segment_batch,
        )
        outputs = replay(rows) if rows else {}
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print(f"FAIL test runner: {error}")
        return 2

    outcomes: Counter[str] = Counter()
    strict_failures = 0
    for case in cases:
        case_id = str(case["case_id"])
        tier = str(case["tier"])
        expected = str(case["expected"])
        setup_error = setup_gaps.get(case_id)
        payload = outputs.get(case_id, {})
        actual = str(payload.get("text", ""))
        passed = setup_error is None and actual == expected

        if passed:
            status = "PASS" if tier == "regression" else "EXPLORE_PASS"
            outcomes[status] += 1
            print(f"{status} {case_id} raw={raw_lengths[case_id]}: {actual}")
            continue

        status = "FAIL" if tier == "regression" else "EXPLORE_GAP"
        outcomes[status] += 1
        if tier == "regression" or args.strict:
            strict_failures += 1
        detail = setup_error or f"expected={expected!r} actual={actual!r}"
        print(f"{status} {case_id}: {detail}")

    print(
        "TOTAL "
        f"{len(cases)} "
        f"PASS {outcomes['PASS']} "
        f"FAIL {outcomes['FAIL']} "
        f"EXPLORE_PASS {outcomes['EXPLORE_PASS']} "
        f"EXPLORE_GAP {outcomes['EXPLORE_GAP']}"
    )
    print(f"ELAPSED_SECONDS {time.perf_counter() - started_at:.2f}")
    if unresolved_phrases:
        print(f"UNRESOLVED_CHINESE_SEGMENTS {len(unresolved_phrases)}")
    return 0 if strict_failures == 0 else 2


if __name__ == "__main__":
    raise SystemExit(main())
