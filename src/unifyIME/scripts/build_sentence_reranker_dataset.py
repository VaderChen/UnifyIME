#!/usr/bin/env python3
import argparse
import json
import random
import subprocess
from pathlib import Path


def load_groups(path: Path):
    rows = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def split_groups(groups, seed: int):
    rng = random.Random(seed)
    shuffled = list(groups)
    rng.shuffle(shuffled)
    total = len(shuffled)
    train_end = int(total * 0.8)
    valid_end = int(total * 0.9)
    return {
        "train": shuffled[:train_end],
        "valid": shuffled[train_end:valid_end],
        "test": shuffled[valid_end:],
    }


def flatten_segment_samples(groups):
    rows = []
    for group in groups:
        for sample in group.get("segment_samples") or []:
            rows.append(sample)
    return rows


def summarize(groups):
    candidate_counts = [len(group.get("candidates", [])) for group in groups]
    segment_counts = [len(group.get("segment_samples") or []) for group in groups]
    return {
        "groups": len(groups),
        "avg_candidates": (sum(candidate_counts) / len(candidate_counts)) if candidate_counts else 0.0,
        "avg_segment_samples": (sum(segment_counts) / len(segment_counts)) if segment_counts else 0.0,
        "min_candidates": min(candidate_counts) if candidate_counts else 0,
        "max_candidates": max(candidate_counts) if candidate_counts else 0,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build unified UnifyIME sentence/segment reranker dataset.")
    parser.add_argument("--input", required=True, help="default | short-words | short-sentences | dynamic | article | /path/to/sentences.txt")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--app")
    parser.add_argument("--batch-size", type=int, default=100)
    parser.add_argument("--top-paths", type=int, default=8)
    parser.add_argument("--top-candidates-per-span", type=int, default=6)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    app_path = Path(args.app) if args.app else repo_root / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"

    grouped_path = out_dir / "sentence_groups.jsonl"
    cmd = [
        str(app_path),
        "dump-sentence-reranker-data",
        str(grouped_path),
        args.input,
        str(args.batch_size),
        str(args.top_paths),
        str(args.top_candidates_per_span),
    ]
    proc = subprocess.run(cmd, capture_output=True, text=True)
    if proc.returncode != 0:
        summary = {
            "command": cmd,
            "returncode": proc.returncode,
            "stdout": proc.stdout.strip(),
            "stderr": proc.stderr.strip(),
            "output_dir": str(out_dir),
        }
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return proc.returncode

    groups = load_groups(grouped_path)
    splits = split_groups(groups, args.seed)
    segment_summary = {}

    for split_name, split_groups_rows in splits.items():
        sentence_path = out_dir / f"{split_name}.sentence.jsonl"
        ranker_path = out_dir / f"{split_name}.ranker.jsonl"
        write_jsonl(sentence_path, split_groups_rows)
        ranker_rows = flatten_segment_samples(split_groups_rows)
        write_jsonl(ranker_path, ranker_rows)
        segment_summary[split_name] = {
            "sentence_groups": len(split_groups_rows),
            "ranker_rows": len(ranker_rows),
            "sentence_path": str(sentence_path),
            "ranker_path": str(ranker_path),
        }

    summary = {
        "command": cmd,
        "returncode": proc.returncode,
        "stdout": proc.stdout.strip(),
        "stderr": proc.stderr.strip(),
        "output_dir": str(out_dir),
        "group_summary": summarize(groups),
        "splits": segment_summary,
    }
    (out_dir / "dataset_summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
