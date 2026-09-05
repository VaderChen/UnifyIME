import json
import os
import re
import subprocess
import tempfile
from pathlib import Path


def resolve_root() -> Path:
    explicit = os.environ.get("UNIFYIME_WORKSPACE_ROOT") or os.environ.get("FASTCHIME_WORKSPACE_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


ROOT = resolve_root()
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
CASE_FILE = ROOT / "src" / "unifyIME" / "tests" / "regression_cases.jsonl"
PROBE_BATCH_COMMANDS = {
    "zh": "zh-build-raw-input-batch",
    "en": "en-build-raw-input-batch",
    "mix": "build-raw-input-batch",
}
ACTION_BATCH_COMMANDS = {
    "zh": "zh-ime-action-batch-replay",
    "en": "en-ime-action-batch-replay",
    "mix": "ime-action-batch-replay",
}


def load_cases() -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    with CASE_FILE.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            payload = json.loads(line)
            rows.append({
                "category": str(payload["category"]),
                "sentence": str(payload["sentence"]),
            })
    return rows


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, timeout=180)


def final_text_from_probe_output(output: str) -> str:
    blocks = re.findall(r"=== IME ACTION STEP .*?===\n(.*?)\n=== END IME ACTION STEP .*?===", output, re.S)
    final_block = blocks[-1] if blocks else ""
    match = re.search(r"文字：\n(.*?)\n\n讀音佇列：", final_block, re.S)
    if not match:
        return ""
    return match.group(1).replace("❚", "").strip()


def main() -> int:
    CASES = load_cases()
    failures: list[tuple[int, str, str, str, str]] = []
    skipped: list[tuple[int, str, str]] = []
    category_totals: dict[str, int] = {}
    category_passes: dict[str, int] = {}
    for idx, case in enumerate(CASES, 1):
        category = case["category"]
        category_totals[category] = category_totals.get(category, 0) + 1
    cases_by_category: dict[str, list[tuple[int, str]]] = {}
    for idx, case in enumerate(CASES, 1):
        cases_by_category.setdefault(case["category"], []).append((idx, case["sentence"]))

    for category, entries in cases_by_category.items():
        probe_cmd = PROBE_BATCH_COMMANDS[category]
        action_cmd = ACTION_BATCH_COMMANDS[category]
        probe_input_path = Path(tempfile.gettempdir()) / f"unifyime_probe_input_batch_{category}.txt"
        with probe_input_path.open("w", encoding="utf-8") as handle:
            for _, sentence in entries:
                handle.write(sentence + "\n")

        try:
            probe = run([str(APP), probe_cmd, str(probe_input_path)])
        except subprocess.TimeoutExpired:
            for idx, sentence in entries:
                failures.append((idx, category, sentence, f"{probe_cmd} timeout", ""))
            continue

        if probe.returncode != 0:
            detail = (probe.stdout + probe.stderr).strip()
            for idx, sentence in entries:
                failures.append((idx, category, sentence, f"{probe_cmd} failed", detail))
            continue

        probe_lines = [line for line in probe.stdout.splitlines() if line.strip()]
        batch_rows: list[dict[str, object]] = []
        resolved_cases: dict[str, tuple[int, str, str]] = {}

        for line_index, (idx, sentence) in enumerate(entries):
            if line_index >= len(probe_lines):
                failures.append((idx, category, sentence, f"missing {probe_cmd} row", ""))
                continue
            try:
                payload = json.loads(probe_lines[line_index])
            except json.JSONDecodeError:
                failures.append((idx, category, sentence, f"invalid {probe_cmd} json", probe_lines[line_index]))
                continue
            if not payload.get("resolved"):
                skipped.append((idx, category, sentence))
                continue

            row_keys = payload.get("row_keys")
            key_tokens = payload.get("key_tokens")
            key_sequence = payload.get("key_sequence", "")
            if isinstance(row_keys, list) and row_keys:
                tokens = list(row_keys)
            elif key_sequence:
                tokens = [f"raw:{ch}" for ch in key_sequence if ch != " "] + ["enter"]
            elif isinstance(key_tokens, list) and key_tokens:
                tokens = [f"raw:{token}" for token in key_tokens] + ["enter"]
            else:
                failures.append((idx, category, sentence, "empty key_sequence", probe.stdout.strip()))
                continue

            row_id = f"{category}-case-{idx}"
            batch_rows.append({
                "row_id": row_id,
                "row_keys": tokens,
            })
            resolved_cases[row_id] = (idx, sentence, key_sequence)

        if not batch_rows:
            continue

        batch_path = Path(tempfile.gettempdir()) / f"unifyime_raw_selftest_batch_{category}.jsonl"
        with batch_path.open("w", encoding="utf-8") as handle:
            for row in batch_rows:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")

        try:
            result = run([str(APP), action_cmd, str(batch_path)])
        except subprocess.TimeoutExpired:
            for row_id, (idx, sentence, key_sequence) in resolved_cases.items():
                failures.append((idx, category, sentence, f"{action_cmd} timeout", key_sequence))
            continue

        if result.returncode != 0:
            detail = (result.stdout + result.stderr).strip()
            for row_id, (idx, sentence, key_sequence) in resolved_cases.items():
                failures.append((idx, category, sentence, f"{action_cmd} failed", detail))
            continue

        outputs: dict[str, dict[str, object]] = {}
        for line in result.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            row_id = str(payload.get("row_id", ""))
            if row_id:
                outputs[row_id] = payload

        for row_id, (idx, sentence, key_sequence) in resolved_cases.items():
            payload = outputs.get(row_id)
            if not payload:
                failures.append((idx, category, sentence, "missing batch result", key_sequence))
                continue
            if payload.get("error"):
                failures.append((idx, category, sentence, str(payload["error"]), key_sequence))
                continue
            actual = str(payload.get("text", "")).replace("❚", "").strip()
            if actual != sentence:
                failures.append((idx, category, sentence, actual, key_sequence))
                continue
            category_passes[category] = category_passes.get(category, 0) + 1

    print(f"TOTAL {len(CASES)}")
    print(f"PASS {sum(category_passes.values())}")
    print(f"FAIL {len(failures)}")
    print(f"SKIP_UNRESOLVED {len(skipped)}")
    for category in sorted(category_totals):
        total = category_totals[category]
        passed = category_passes.get(category, 0)
        skipped_count = sum(1 for _, cat, _ in skipped if cat == category)
        failed = sum(1 for _, cat, _, _, _ in failures if cat == category)
        print(f"CATEGORY {category}: total={total} pass={passed} fail={failed} skip={skipped_count}")
    for idx, category, expected, actual, extra in failures:
        print("---")
        print(f"CASE {idx}")
        print(f"CATEGORY: {category}")
        print(f"EXPECTED: {expected}")
        print(f"ACTUAL:   {actual}")
        print(f"EXTRA:    {extra}")
    for idx, category, sentence in skipped:
        print("---")
        print(f"CASE {idx}")
        print(f"CATEGORY: {category}")
        print(f"SKIPPED:  unresolved reverse path")
        print(f"TARGET:   {sentence}")
    return 0 if not failures else 2


if __name__ == "__main__":
    raise SystemExit(main())
