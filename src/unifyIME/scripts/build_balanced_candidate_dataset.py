#!/usr/bin/env python3
"""Build a compact, case-safe candidate-ranker dataset with hard-case weighting."""

from __future__ import annotations

import argparse
import hashlib
import json
import random
from collections import defaultdict
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_SOURCES = [
    ROOT / "data/dynamic/dynamic.jsonl",
    ROOT / "data/short_sentences/short_sentences.jsonl",
    ROOT / "data/short_words/short_words.jsonl",
    ROOT / "data/default/default.jsonl",
    ROOT / "data/regression/regression.jsonl",
    ROOT / "data/web_corpus/web_corpus.jsonl",
]


def stable_fraction(text: str, seed: int) -> float:
    digest = hashlib.sha256(f"{seed}:{text}".encode()).digest()
    return int.from_bytes(digest[:8], "big") / float(2**64)


def load_groups(paths: list[Path]) -> dict[str, list[dict[str, Any]]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for path in paths:
        source_prefix = path.parent.name
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                row = json.loads(line)
                group_id = f"{source_prefix}:{row.get('case_id')}:{row.get('step_id')}"
                row["case_id"] = f"{source_prefix}:{row.get('case_id')}"
                row["sample_id"] = f"{source_prefix}:{row.get('sample_id')}"
                groups[group_id].append(row)
    return groups


def valid_group(rows: list[dict[str, Any]]) -> bool:
    positives = [row for row in rows if float(row.get("label", 0)) > 0]
    return len(rows) > 1 and len(positives) == 1


def is_hard_group(rows: list[dict[str, Any]]) -> bool:
    return any(
        float(row.get("label", 0)) > 0 and int(row.get("base_rank", 0)) > 0
        for row in rows
    )


def split_name(group_id: str, seed: int, train_fraction: float, valid_fraction: float) -> str:
    fraction = stable_fraction(group_id, seed)
    if fraction < train_fraction:
        return "train"
    if fraction < train_fraction + valid_fraction:
        return "valid"
    return "test"


def stratified_case_splits(
    groups: dict[str, list[dict[str, Any]]],
    seed: int,
    train_fraction: float,
    valid_fraction: float,
) -> dict[str, str]:
    case_has_hard: dict[str, bool] = defaultdict(bool)
    for group_id, rows in groups.items():
        case_id = str(rows[0].get("case_id", group_id))
        case_has_hard[case_id] = case_has_hard[case_id] or is_hard_group(rows)

    assignments: dict[str, str] = {}
    for has_hard in (False, True):
        case_ids = [case_id for case_id, value in case_has_hard.items() if value == has_hard]
        case_ids.sort(key=lambda case_id: stable_fraction(case_id, seed))
        train_count = int(round(len(case_ids) * train_fraction))
        valid_count = int(round(len(case_ids) * valid_fraction))
        if len(case_ids) >= 3:
            train_count = min(max(1, train_count), len(case_ids) - 2)
            valid_count = min(max(1, valid_count), len(case_ids) - train_count - 1)
        for index, case_id in enumerate(case_ids):
            if index < train_count:
                assignments[case_id] = "train"
            elif index < train_count + valid_count:
                assignments[case_id] = "valid"
            else:
                assignments[case_id] = "test"
    return assignments


def reweight(
    rows: list[dict[str, Any]],
    hard_positive_boost: float,
    hard_negative_boost: float,
) -> list[dict[str, Any]]:
    hard = is_hard_group(rows)
    result = []
    for row in rows:
        updated = dict(row)
        tags = list(updated.get("tags", []))
        if hard:
            tags.append("balanced_hard_case")
            boost = hard_positive_boost if float(updated.get("label", 0)) > 0 else hard_negative_boost
            updated["sample_weight"] = float(updated.get("sample_weight", 1.0)) * boost
        else:
            tags.append("balanced_easy_case")
        updated["tags"] = list(dict.fromkeys(tags))
        result.append(updated)
    return result


def write_rows(path: Path, groups: list[list[dict[str, Any]]]) -> int:
    count = 0
    with path.open("w", encoding="utf-8") as handle:
        for group in groups:
            for row in group:
                handle.write(json.dumps(row, ensure_ascii=False) + "\n")
                count += 1
    return count


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--source", action="append")
    parser.add_argument("--seed", type=int, default=77)
    parser.add_argument("--train-fraction", type=float, default=0.8)
    parser.add_argument("--valid-fraction", type=float, default=0.1)
    parser.add_argument("--train-easy-groups", type=int, default=6000)
    parser.add_argument("--valid-easy-groups", type=int, default=1500)
    parser.add_argument("--test-easy-groups", type=int, default=1500)
    parser.add_argument("--hard-positive-boost", type=float, default=30.0)
    parser.add_argument("--hard-negative-boost", type=float, default=10.0)
    args = parser.parse_args()

    if not 0.0 < args.train_fraction < 1.0:
        parser.error("--train-fraction must be between 0 and 1")
    if not 0.0 < args.valid_fraction < 1.0:
        parser.error("--valid-fraction must be between 0 and 1")
    if args.train_fraction + args.valid_fraction >= 1.0:
        parser.error("train and valid fractions must leave a non-empty test fraction")

    sources = [Path(path).expanduser() for path in args.source] if args.source else DEFAULT_SOURCES
    output = Path(args.output).expanduser()
    output.mkdir(parents=True, exist_ok=True)
    groups = {key: value for key, value in load_groups(sources).items() if valid_group(value)}

    buckets: dict[str, dict[str, list[tuple[str, list[dict[str, Any]]]]]] = {
        split: {"hard": [], "easy": []} for split in ("train", "valid", "test")
    }
    case_splits = stratified_case_splits(
        groups,
        args.seed,
        args.train_fraction,
        args.valid_fraction,
    )
    for group_id, rows in groups.items():
        # Keep every segment from the same sentence/case in one split.  A
        # group-only split can leak adjacent context from one sentence into
        # both training and evaluation even though candidate rows themselves
        # do not overlap.
        case_id = str(rows[0].get("case_id", group_id))
        split = case_splits[case_id]
        bucket = "hard" if is_hard_group(rows) else "easy"
        buckets[split][bucket].append((group_id, rows))

    rng = random.Random(args.seed)
    caps = {
        "train": args.train_easy_groups,
        "valid": args.valid_easy_groups,
        "test": args.test_easy_groups,
    }
    summary: dict[str, Any] = {
        "sources": [str(path) for path in sources],
        "seed": args.seed,
        "split_unit": "case_id_stratified_by_hard_case",
        "split_fractions": {
            "train": args.train_fraction,
            "valid": args.valid_fraction,
            "test": 1.0 - args.train_fraction - args.valid_fraction,
        },
        "hard_positive_boost": args.hard_positive_boost,
        "hard_negative_boost": args.hard_negative_boost,
        "splits": {},
    }
    for split in ("train", "valid", "test"):
        easy = buckets[split]["easy"]
        hard = buckets[split]["hard"]
        rng.shuffle(easy)
        selected = hard + easy[:caps[split]]
        rng.shuffle(selected)
        weighted_groups = [
            reweight(rows, args.hard_positive_boost, args.hard_negative_boost)
            for _, rows in selected
        ]
        row_count = write_rows(output / f"{split}.jsonl", weighted_groups)
        summary["splits"][split] = {
            "groups": len(selected),
            "hard_groups": len(hard),
            "easy_groups": min(len(easy), caps[split]),
            "rows": row_count,
        }

    (output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
