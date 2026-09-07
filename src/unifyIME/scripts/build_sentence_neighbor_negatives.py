#!/usr/bin/env python3
import argparse
import json
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


def levenshtein(a: str, b: str) -> int:
    if a == b:
        return 0
    if not a:
        return len(b)
    if not b:
        return len(a)
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, start=1):
        curr = [i]
        for j, cb in enumerate(b, start=1):
            cost = 0 if ca == cb else 1
            curr.append(min(
                prev[j] + 1,
                curr[j - 1] + 1,
                prev[j - 1] + cost,
            ))
        prev = curr
    return prev[-1]


def char_diff_count(a: str, b: str) -> int:
    max_len = max(len(a), len(b))
    total = abs(len(a) - len(b))
    for ca, cb in zip(a, b):
        if ca != cb:
            total += 1
    return total if max_len else 0


def gold_rank(group):
    gold = group.get("gold_text")
    candidates = sorted(group.get("candidates", []), key=lambda item: item["localScore"], reverse=True)
    for index, candidate in enumerate(candidates, start=1):
        if candidate["text"] == gold:
            return index
    return None


def dedup_candidates(candidates):
    dedup = {}
    for candidate in candidates:
        text = candidate["text"]
        existing = dedup.get(text)
        if existing is None or candidate["localScore"] > existing["localScore"]:
            dedup[text] = candidate
    return list(dedup.values())


def scored_negatives(group):
    gold = group.get("gold_text", "")
    candidates = dedup_candidates(group.get("candidates", []))
    negatives = []
    for candidate in candidates:
        text = candidate["text"]
        if text == gold:
            continue
        score_gap = abs(float(candidate["localScore"]) - max(
            float(item["localScore"]) for item in candidates if item["text"] == gold
        ))
        negatives.append({
            "candidate": candidate,
            "char_diff": char_diff_count(gold, text),
            "edit_distance": levenshtein(gold, text),
            "score_gap": score_gap,
        })
    negatives.sort(key=lambda item: (
        item["char_diff"],
        item["edit_distance"],
        item["score_gap"],
        item["candidate"]["text"],
    ))
    return negatives


def build_neighbor_group(group, per_group: int):
    gold = group.get("gold_text", "")
    candidates = dedup_candidates(group.get("candidates", []))
    gold_candidates = [candidate for candidate in candidates if candidate["text"] == gold]
    if not gold_candidates:
        return None, 0
    gold_candidate = max(gold_candidates, key=lambda item: item["localScore"])
    negatives = scored_negatives(group)
    chosen_negatives = [item["candidate"] for item in negatives[:per_group]]
    if not chosen_negatives:
        return None, 0

    new_group = dict(group)
    new_group["candidates"] = [gold_candidate] + chosen_negatives
    metadata = {
        "gold_rank_in_source": gold_rank(group),
        "neighbor_negative_count": len(chosen_negatives),
        "source_candidate_count": len(candidates),
        "hard_case": (gold_rank(group) or 0) > 1,
    }
    new_group["neighbor_metadata"] = metadata
    return new_group, len(chosen_negatives)


def write_jsonl(path: Path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Build grouped near-neighbor negative dataset for sentence reranker.")
    parser.add_argument("--inputs", nargs="+", required=True, help="Sentence group JSONL files")
    parser.add_argument("--output", required=True, help="Output grouped JSONL")
    parser.add_argument("--summary", required=True, help="Output summary JSON")
    parser.add_argument("--target-negatives", type=int, default=500)
    parser.add_argument("--per-group", type=int, default=5)
    parser.add_argument("--hard-only", action="store_true")
    args = parser.parse_args()

    source_groups = load_groups(args.inputs)
    source_groups.sort(key=lambda group: (
        gold_rank(group) or 10**9,
        group.get("gold_text", ""),
    ))

    selected_groups = []
    total_negatives = 0
    skipped_no_gold = 0
    skipped_no_neighbors = 0

    for group in source_groups:
        rank = gold_rank(group)
        if rank is None:
            skipped_no_gold += 1
            continue
        if args.hard_only and rank <= 1:
            continue
        built, negative_count = build_neighbor_group(group, args.per_group)
        if built is None:
            skipped_no_neighbors += 1
            continue
        selected_groups.append(built)
        total_negatives += negative_count
        if total_negatives >= args.target_negatives:
            break

    write_jsonl(Path(args.output), selected_groups)

    summary = {
        "inputs": args.inputs,
        "group_count": len(selected_groups),
        "negative_count": total_negatives,
        "target_negatives": args.target_negatives,
        "per_group": args.per_group,
        "hard_only": args.hard_only,
        "skipped_no_gold": skipped_no_gold,
        "skipped_no_neighbors": skipped_no_neighbors,
        "hard_groups": sum(1 for group in selected_groups if group.get("neighbor_metadata", {}).get("hard_case")),
        "easy_groups": sum(1 for group in selected_groups if not group.get("neighbor_metadata", {}).get("hard_case")),
    }
    Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
