#!/usr/bin/env python3
import argparse
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
TEMP_DIR = ROOT / "temp"


def load_rows(path: Path):
    rows = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def char_segments(text: str):
    return [
        {
            "languageID": "zh-Hant",
            "reading": "",
            "value": char,
            "start": index,
            "length": 1,
        }
        for index, char in enumerate(text)
    ]


def build_candidate(text: str, readings, local_score: float, metadata: dict):
    return {
        "text": text,
        "readings": readings,
        "segments": char_segments(text),
        "localScore": local_score,
        "metadata": metadata,
    }


def batch_resolve_chars(chars):
    if not chars:
        return {}
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    input_path = TEMP_DIR / "cli_train_chars.txt"
    input_path.write_text("\n".join(sorted(chars)) + "\n", encoding="utf-8")
    proc = subprocess.run(
        [str(APP), "probe-input-batch", str(input_path)],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )
    readings_by_char = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        payload = json.loads(line)
        sentence = payload.get("sentence", "")
        if len(sentence) != 1 or not payload.get("resolved"):
            continue
        readings = payload.get("readings") or []
        readings_by_char[sentence] = set(readings)
    return readings_by_char


def classify_row(row, char_readings):
    gold = row["sentence"]
    fail = row["paths"]["hybrid"]["output"]
    if not fail or fail == gold:
        return None

    if len(gold) != len(fail):
        return "probe"

    if any((a in "，。！？；：、（）〔〕【】《》「」『』…—﹐“”" or b in "，。！？；：、（）〔〕【】《》「」『』…—﹐“”") and a != b for a, b in zip(gold, fail)):
        return "probe"

    diff_pairs = [(a, b) for a, b in zip(gold, fail) if a != b]
    if not diff_pairs:
        return None

    for gold_char, fail_char in diff_pairs:
        gold_set = char_readings.get(gold_char, set())
        fail_set = char_readings.get(fail_char, set())
        if not gold_set or not fail_set or gold_set.isdisjoint(fail_set):
            return "probe"
    return "core"


def build_group(row, index: int, split: str):
    gold = row["sentence"]
    fail = row["paths"]["hybrid"]["output"]
    readings = row.get("probe_readings") or []
    return {
        "group_id": f"{split}_{index:06d}",
        "readings": readings,
        "gold_text": gold,
        "candidates": [
            build_candidate(
                text=gold,
                readings=readings,
                local_score=0.0,
                metadata={"is_gold": 1.0, "source_cli": 1.0, "split_core": 1.0 if split == "core" else 0.0},
            ),
            build_candidate(
                text=fail,
                readings=readings,
                local_score=1000.0,
                metadata={"is_gold": 0.0, "source_cli": 1.0, "split_core": 1.0 if split == "core" else 0.0},
            ),
        ],
        "context": {
            "committedLeftContext": [],
            "committedRightContext": [],
        },
        "segment_samples": [],
        "source_metadata": {
            "origin": "cli_validate",
            "row_keys": row.get("row_keys") or [],
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Split CLI validation failures into core/probe grouped datasets.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--max-core", type=int, default=0, help="Stop after collecting this many core groups (0 = no limit)")
    args = parser.parse_args()

    rows = load_rows(Path(args.input))
    fail_rows = [row for row in rows if row.get("paths", {}).get("hybrid", {}).get("output") not in ("", row.get("sentence"))]

    unique_chars = set()
    for row in fail_rows:
        gold = row["sentence"]
        fail = row["paths"]["hybrid"]["output"]
        if len(gold) == len(fail):
            for a, b in zip(gold, fail):
                if a != b:
                    unique_chars.add(a)
                    unique_chars.add(b)
    char_readings = batch_resolve_chars(unique_chars)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    core_path = out_dir / "core_groups.jsonl"
    probe_path = out_dir / "probe_groups.jsonl"
    core_count = 0
    probe_count = 0

    with core_path.open("w", encoding="utf-8") as core_fh, probe_path.open("w", encoding="utf-8") as probe_fh:
        for row in fail_rows:
            split = classify_row(row, char_readings)
            if split is None:
                continue
            if split == "core":
                core_count += 1
                group = build_group(row, core_count, split)
                core_fh.write(json.dumps(group, ensure_ascii=False) + "\n")
                if args.max_core and core_count >= args.max_core:
                    break
            else:
                probe_count += 1
                group = build_group(row, probe_count, split)
                probe_fh.write(json.dumps(group, ensure_ascii=False) + "\n")

    summary = {
        "input": args.input,
        "core_groups": core_count,
        "probe_groups": probe_count,
        "core_output": str(core_path),
        "probe_output": str(probe_path),
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
