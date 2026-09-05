#!/usr/bin/env python3
import argparse
import json
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "fastChIME" / "scripts"))

from train_sentence_reranker import load_groups  # type: ignore
from sentence_reranker_ab_check import load_linear_weights, rerank_score  # type: ignore


def find_rank(items, gold_text: str):
    for index, item in enumerate(items, start=1):
        if item["text"] == gold_text:
            return index
    return None


def evaluate(groups, weights, bias, mean, std, alpha: float):
    baseline_top1 = 0
    reranked_top1 = 0
    baseline_mrr = 0.0
    reranked_mrr = 0.0
    rescued = []
    regressed = []
    details = []

    for group in groups:
        candidates = group.get("candidates", [])
        gold = group.get("gold_text")
        context = group.get("context") or {"committedLeftContext": [], "committedRightContext": []}
        if not candidates or not gold:
            continue

        baseline = sorted(candidates, key=lambda item: item["localScore"], reverse=True)
        reranked = sorted(
            candidates,
            key=lambda item: (item["localScore"] + alpha * rerank_score(item, context, weights, bias, mean, std)),
            reverse=True,
        )

        baseline_ok = baseline[0]["text"] == gold
        reranked_ok = reranked[0]["text"] == gold
        if baseline_ok:
            baseline_top1 += 1
        if reranked_ok:
            reranked_top1 += 1

        baseline_rank = find_rank(baseline, gold)
        reranked_rank = find_rank(reranked, gold)
        if baseline_rank:
            baseline_mrr += 1.0 / baseline_rank
        if reranked_rank:
            reranked_mrr += 1.0 / reranked_rank

        if reranked_ok and not baseline_ok:
            rescued.append(group["group_id"])
        if baseline_ok and not reranked_ok:
            regressed.append(group["group_id"])

        details.append({
            "group_id": group["group_id"],
            "gold_text": gold,
            "baseline_top": baseline[0]["text"],
            "reranked_top": reranked[0]["text"],
            "baseline_rank": baseline_rank,
            "reranked_rank": reranked_rank,
        })

    total = max(len(details), 1)
    return {
        "alpha": alpha,
        "groups": len(details),
        "baseline_top1": baseline_top1 / total,
        "reranked_top1": reranked_top1 / total,
        "baseline_mrr": baseline_mrr / total,
        "reranked_mrr": reranked_mrr / total,
        "rescued_count": len(rescued),
        "regressed_count": len(regressed),
        "rescued_groups": rescued,
        "regressed_groups": regressed,
        "details": details,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Sweep alpha for UnifyIME sentence reranker.")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--weights", required=True)
    parser.add_argument("--alphas", nargs="+", type=float, default=[1.0, 10.0, 30.0, 100.0, 300.0, 1000.0, 3000.0])
    parser.add_argument("--output")
    args = parser.parse_args()

    groups = load_groups(args.dataset)
    weights, bias, mean, std = load_linear_weights(Path(args.weights))

    results = [evaluate(groups, weights, bias, mean, std, alpha) for alpha in args.alphas]
    if args.output:
        Path(args.output).write_text(json.dumps(results, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(results, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
