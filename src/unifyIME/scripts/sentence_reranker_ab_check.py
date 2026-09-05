#!/usr/bin/env python3
import argparse
import json
from pathlib import Path

import numpy as np

from train_sentence_reranker import encode_candidate, load_groups


def load_linear_weights(path: Path):
    data = np.load(path)
    weights = data["weights"]
    bias = data["bias"]
    mean = data["mean"] if "mean" in data.files else np.zeros(weights.shape[-1], dtype=np.float32)
    std = data["std"] if "std" in data.files else np.ones(weights.shape[-1], dtype=np.float32)
    if weights.ndim == 2:
        weights = weights[0]
    if bias.ndim > 0:
        bias = float(bias[0])
    else:
        bias = float(bias)
    return weights.astype(np.float32), bias, mean.astype(np.float32), std.astype(np.float32)


def sigmoid(x: float) -> float:
    return 1.0 / (1.0 + np.exp(-max(min(x, 30.0), -30.0)))


def rerank_score(candidate: dict, context: dict, weights, bias: float, mean: np.ndarray, std: np.ndarray) -> float:
    features = np.asarray(encode_candidate(candidate, context), dtype=np.float32)
    normalized = (features - mean) / std
    return float(sigmoid(float(normalized @ weights + bias)))


def evaluate(groups, weights, bias: float, mean: np.ndarray, std: np.ndarray):
    baseline_top1 = 0
    reranked_top1 = 0
    baseline_mrr = 0.0
    reranked_mrr = 0.0
    rescued = []
    regressed = []

    for group in groups:
        candidates = group.get("candidates", [])
        gold = group.get("gold_text")
        context = group.get("context") or {"committedLeftContext": [], "committedRightContext": []}
        if not candidates or not gold:
            continue

        baseline = sorted(candidates, key=lambda item: item["localScore"], reverse=True)
        reranked = sorted(
            candidates,
            key=lambda item: (item["localScore"] + rerank_score(item, context, weights, bias, mean, std)),
            reverse=True,
        )

        if baseline and baseline[0]["text"] == gold:
            baseline_top1 += 1
        if reranked and reranked[0]["text"] == gold:
            reranked_top1 += 1

        for index, item in enumerate(baseline, start=1):
            if item["text"] == gold:
                baseline_mrr += 1.0 / index
                break
        for index, item in enumerate(reranked, start=1):
            if item["text"] == gold:
                reranked_mrr += 1.0 / index
                break

        baseline_ok = baseline and baseline[0]["text"] == gold
        reranked_ok = reranked and reranked[0]["text"] == gold
        if reranked_ok and not baseline_ok:
            rescued.append(group["group_id"])
        if baseline_ok and not reranked_ok:
            regressed.append(group["group_id"])

    total = max(len(groups), 1)
    return {
        "groups": len(groups),
        "baseline_top1": baseline_top1 / total,
        "reranked_top1": reranked_top1 / total,
        "baseline_mrr": baseline_mrr / total,
        "reranked_mrr": reranked_mrr / total,
        "rescued_count": len(rescued),
        "regressed_count": len(regressed),
        "rescued_groups": rescued[:20],
        "regressed_groups": regressed[:20],
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="AB check for UnifyIME sentence reranker.")
    parser.add_argument("--dataset", required=True)
    parser.add_argument("--weights", required=True, help="sentence_reranker_linear_weights.npz")
    parser.add_argument("--output")
    args = parser.parse_args()

    groups = load_groups(args.dataset)
    weights, bias, mean, std = load_linear_weights(Path(args.weights))
    result = evaluate(groups, weights, bias, mean, std)
    if args.output:
        Path(args.output).write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
