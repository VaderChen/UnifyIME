#!/usr/bin/env python3
import argparse
import json
import random
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
TEMP_DIR = ROOT / "temp"
BUILD_NEG = ROOT / "src" / "unifyIME" / "scripts" / "build_sentence_three_path_negatives.py"
SPLIT_SET = ROOT / "src" / "unifyIME" / "scripts" / "build_cli_sentence_training_set.py"
TRAINER = ROOT / "src" / "unifyIME" / "scripts" / "train_sentence_reranker.py"


def run(cmd):
    proc = subprocess.run(cmd, cwd=ROOT, text=True, capture_output=True, check=False)
    if proc.returncode != 0:
        raise RuntimeError(f"command failed: {' '.join(str(x) for x in cmd)}\nstdout={proc.stdout}\nstderr={proc.stderr}")
    return proc


def load_jsonl(path: Path):
    if not path.exists():
        return []
    with path.open("r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def append_jsonl(dst: Path, src_rows):
    dst.parent.mkdir(parents=True, exist_ok=True)
    with dst.open("a", encoding="utf-8") as fh:
        for row in src_rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Collect CLI-tested sentence samples, split, and train when enough core samples are available.")
    parser.add_argument("--input", required=True)
    parser.add_argument("--out-dir", required=True)
    parser.add_argument("--chunk-size", type=int, default=1000)
    parser.add_argument("--target-core", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    collected_rows_path = out_dir / "cli_validate.jsonl"
    core_path = out_dir / "core_groups.jsonl"
    probe_path = out_dir / "probe_groups.jsonl"
    summary_path = out_dir / "summary.json"
    train_path = out_dir / "train.jsonl"
    valid_path = out_dir / "valid.jsonl"
    test_path = out_dir / "test.jsonl"
    train_out_dir = out_dir / "artifacts"

    for path in [collected_rows_path, core_path, probe_path]:
        if path.exists():
            path.unlink()

    sentences = [line.strip() for line in Path(args.input).read_text(encoding="utf-8").splitlines() if line.strip()]
    processed = 0
    total_collected = 0
    total_core = 0
    total_probe = 0

    for chunk_index, start in enumerate(range(0, len(sentences), args.chunk_size), start=1):
        chunk = sentences[start:start + args.chunk_size]
        chunk_input = TEMP_DIR / f"cli_collect_chunk_{chunk_index:04d}.txt"
        chunk_output = TEMP_DIR / f"cli_collect_chunk_{chunk_index:04d}.jsonl"
        chunk_summary = TEMP_DIR / f"cli_collect_chunk_{chunk_index:04d}.summary.json"
        split_dir = TEMP_DIR / f"cli_collect_chunk_split_{chunk_index:04d}"
        chunk_input.write_text("\n".join(chunk) + "\n", encoding="utf-8")

        run([
            "python3",
            str(BUILD_NEG),
            "--input", str(chunk_input),
            "--output", str(chunk_output),
            "--summary", str(chunk_summary),
            "--limit", str(len(chunk)),
            "--modes", "hybrid",
        ])
        rows = load_jsonl(chunk_output)
        append_jsonl(collected_rows_path, rows)

        run([
            "python3",
            str(SPLIT_SET),
            "--input", str(chunk_output),
            "--out-dir", str(split_dir),
        ])
        core_rows = load_jsonl(split_dir / "core_groups.jsonl")
        probe_rows = load_jsonl(split_dir / "probe_groups.jsonl")
        append_jsonl(core_path, core_rows)
        append_jsonl(probe_path, probe_rows)

        processed += len(chunk)
        total_collected += len(rows)
        total_core += len(core_rows)
        total_probe += len(probe_rows)

        summary = {
            "processed": processed,
            "total_sentences": len(sentences),
            "collected_rows": total_collected,
            "core_groups": total_core,
            "probe_groups": total_probe,
            "target_core": args.target_core,
            "done": total_core >= args.target_core or processed >= len(sentences),
        }
        summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(summary, ensure_ascii=False))

        if total_core >= args.target_core:
            break

    core_rows = load_jsonl(core_path)
    if not core_rows:
        print(json.dumps({"trained": False, "reason": "no core groups"}, ensure_ascii=False))
        return 0

    if len(core_rows) < args.target_core:
        final_summary = json.loads(summary_path.read_text(encoding="utf-8"))
        final_summary.update({
            "trained": False,
            "reason": "insufficient_core_groups",
            "available_core_groups": len(core_rows),
        })
        summary_path.write_text(json.dumps(final_summary, ensure_ascii=False, indent=2), encoding="utf-8")
        print(json.dumps(final_summary, ensure_ascii=False, indent=2))
        return 0

    random.Random(args.seed).shuffle(core_rows)
    target = min(len(core_rows), args.target_core)
    core_rows = core_rows[:target]
    n = len(core_rows)
    train_end = max(1, int(n * 0.8))
    valid_end = max(train_end + 1, int(n * 0.9)) if n >= 3 else n
    train_rows = core_rows[:train_end]
    valid_rows = core_rows[train_end:valid_end] if valid_end > train_end else core_rows[:1]
    test_rows = core_rows[valid_end:] if valid_end < n else core_rows[-1:]

    write_jsonl(train_path, train_rows)
    write_jsonl(valid_path, valid_rows)
    write_jsonl(test_path, test_rows)

    run([
        "python3",
        str(TRAINER),
        "--train", str(train_path),
        "--valid", str(valid_path),
        "--test", str(test_path),
        "--output", str(train_out_dir),
    ])

    final_summary = json.loads(summary_path.read_text(encoding="utf-8"))
    final_summary.update({
        "trained": True,
        "trained_core_groups": n,
        "train_groups": len(train_rows),
        "valid_groups": len(valid_rows),
        "test_groups": len(test_rows),
        "artifacts": str(train_out_dir),
    })
    summary_path.write_text(json.dumps(final_summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(final_summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
