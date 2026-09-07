#!/usr/bin/env python3
import argparse
import json
import random
from pathlib import Path


def load_groups(paths):
    groups = []
    for path in paths:
        src = Path(path)
        if not src.exists():
            continue
        with src.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if line:
                    groups.append(json.loads(line))
    return groups


def gold_rank(group):
    gold = group.get("gold_text")
    candidates = sorted(group.get("candidates", []), key=lambda item: item["localScore"], reverse=True)
    for index, candidate in enumerate(candidates, start=1):
        if candidate["text"] == gold:
            return index
    return None


def dedup_groups(groups):
    dedup = {}
    for group in groups:
        key = group.get("gold_text") or group.get("group_id")
        current = dedup.get(key)
        current_rank = gold_rank(current) if current else None
        new_rank = gold_rank(group)
        if current is None:
            dedup[key] = group
            continue
        if current_rank is None:
            dedup[key] = group
            continue
        if new_rank is not None and new_rank > current_rank:
            dedup[key] = group
    return list(dedup.values())


def write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def split_groups(groups, seed: int):
    rng = random.Random(seed)
    rows = list(groups)
    rng.shuffle(rows)
    total = len(rows)
    train_end = max(1, int(total * 0.8)) if total > 1 else total
    valid_end = max(train_end, int(total * 0.9))
    return {
        "train": rows[:train_end],
        "valid": rows[train_end:valid_end],
        "test": rows[valid_end:],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build hard-case sentence reranker dataset.")
    parser.add_argument("--inputs", nargs="+", required=True, help="Sentence group JSONL files")
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--min-rank", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    groups = dedup_groups(load_groups(args.inputs))
    hard_groups = []
    for group in groups:
        rank = gold_rank(group)
        if rank is not None and rank >= args.min_rank:
            hard_groups.append(group)

    splits = split_groups(hard_groups, args.seed) if hard_groups else {"train": [], "valid": [], "test": []}
    out_dir = Path(args.output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    write_jsonl(out_dir / "all.sentence.jsonl", hard_groups)
    for name, rows in splits.items():
        write_jsonl(out_dir / f"{name}.sentence.jsonl", rows)

    summary = {
        "inputs": args.inputs,
        "total_groups": len(groups),
        "hard_groups": len(hard_groups),
        "min_rank": args.min_rank,
        "splits": {name: len(rows) for name, rows in splits.items()},
    }
    (out_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
