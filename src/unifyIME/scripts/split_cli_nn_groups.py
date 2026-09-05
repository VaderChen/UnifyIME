#!/usr/bin/env python3
import argparse
import json
import random
from pathlib import Path


def load_jsonl(path: Path):
    with path.open("r", encoding="utf-8") as fh:
        return [json.loads(line) for line in fh if line.strip()]


def write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Split CLI-collected grouped sentence samples into train/valid/test JSONL.")
    parser.add_argument("--input", required=True, help="Input grouped JSONL, usually core_groups.jsonl")
    parser.add_argument("--out-dir", required=True, help="Output directory for train/valid/test JSONL")
    parser.add_argument("--seed", type=int, default=42, help="Shuffle seed")
    parser.add_argument("--train-ratio", type=float, default=0.8, help="Train split ratio")
    parser.add_argument("--valid-ratio", type=float, default=0.1, help="Validation split ratio")
    args = parser.parse_args()

    input_path = Path(args.input)
    out_dir = Path(args.out_dir)
    rows = load_jsonl(input_path)
    if not rows:
        raise SystemExit(f"no rows in {input_path}")

    random.Random(args.seed).shuffle(rows)

    total = len(rows)
    train_end = int(total * args.train_ratio)
    valid_end = int(total * (args.train_ratio + args.valid_ratio))

    train_rows = rows[:train_end]
    valid_rows = rows[train_end:valid_end]
    test_rows = rows[valid_end:]

    write_jsonl(out_dir / "train.jsonl", train_rows)
    write_jsonl(out_dir / "valid.jsonl", valid_rows)
    write_jsonl(out_dir / "test.jsonl", test_rows)

    print(json.dumps({
        "input": str(input_path),
        "out_dir": str(out_dir),
        "total": total,
        "train": len(train_rows),
        "valid": len(valid_rows),
        "test": len(test_rows),
        "seed": args.seed,
    }, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
