#!/usr/bin/env python3
import argparse
import json
import math
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression

try:
    import coremltools as ct
    from coremltools.models import datatypes
    from coremltools.models.neural_network import NeuralNetworkBuilder
except Exception:
    ct = None
    datatypes = None
    NeuralNetworkBuilder = None


EXPECTED_DIM = 24
ROOT = Path(__file__).resolve().parents[3]
PHRASE_MAP_PATH = ROOT / "src" / "unifyIME" / "Resources" / "phrase_map.tsv"
COMMON_MAP_PATH = ROOT / "src" / "unifyIME" / "Resources" / "common_map.tsv"
PHRASE_SURFACE_WEIGHTS = {}


def load_phrase_stats():
    if PHRASE_MAP_PATH.exists():
        with PHRASE_MAP_PATH.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t")
                if len(parts) < 2:
                    continue
                surface = parts[1]
                weight = 1.0
                if len(parts) >= 3:
                    try:
                        weight = max(float(parts[2]), 1.0)
                    except ValueError:
                        weight = 1.0
                PHRASE_SURFACE_WEIGHTS[surface] = max(PHRASE_SURFACE_WEIGHTS.get(surface, 0.0), weight)

    if COMMON_MAP_PATH.exists():
        with COMMON_MAP_PATH.open("r", encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if not line:
                    continue
                parts = line.split("\t", 1)
                if len(parts) != 2:
                    continue
                surface = parts[1]
                PHRASE_SURFACE_WEIGHTS.setdefault(surface, 1.0)


load_phrase_stats()


def stable_hash(text: str) -> float:
    if not text:
        return 0.0
    value = 1469598103934665603
    for ch in text:
        value ^= ord(ch)
        value = (value * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return float(value % 4096) / 4095.0


def is_han(ch: str) -> bool:
    if not ch:
        return False
    code = ord(ch)
    return 0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF


def han_ratio(text: str) -> float:
    if not text:
        return 0.0
    count = sum(1 for ch in text if is_han(ch))
    return float(count) / max(len(text), 1)


def phrase_log_weight(surface: str) -> float:
    weight = PHRASE_SURFACE_WEIGHTS.get(surface, 0.0)
    if weight <= 0.0:
        return 0.0
    return math.log1p(weight) / 10.0


def boundary_match_score(text: str, left_context, right_context) -> float:
    left = left_context[-1] if left_context else ""
    right = right_context[0] if right_context else ""
    score = 0.0
    if left and text and left[-1] == text[0]:
        score += 0.5
    if text and right and text[-1] == right[0]:
        score += 0.5
    return score


def encode_candidate(candidate: dict, context: dict) -> list:
    segments = candidate["segments"]
    values = [segment["value"] for segment in segments]
    lengths = [len(value) for value in values]
    segment_count = float(len(segments))
    text = candidate["text"]
    readings = candidate["readings"]
    avg_segment_length = float(sum(lengths) / len(lengths)) if lengths else 0.0
    max_segment_length = float(max(lengths)) if lengths else 0.0
    single_count = float(sum(1 for length in lengths if length == 1))
    multi_count = float(sum(1 for length in lengths if length > 1))
    phrase_count = float(sum(1 for length in lengths if length > 1))
    fallback_count = float(sum(1 for segment in segments if segment["value"] == segment["reading"]))
    phrase_weights = [phrase_log_weight(value) for value in values]
    avg_phrase_weight = sum(phrase_weights) / len(phrase_weights) if phrase_weights else 0.0
    min_phrase_weight = min(phrase_weights) if phrase_weights else 0.0
    max_phrase_weight = max(phrase_weights) if phrase_weights else 0.0
    adjacency = [phrase_log_weight(values[index] + values[index + 1]) for index in range(len(values) - 1)]
    adjacency_sum = sum(adjacency)
    adjacency_min = min(adjacency) if adjacency else 0.0
    adjacency_avg = adjacency_sum / len(adjacency) if adjacency else 0.0
    left = context.get("committedLeftContext", [])
    right = context.get("committedRightContext", [])
    features = [
        float(candidate["localScore"]),
        segment_count,
        float(len(text)),
        float(len(readings)),
        avg_segment_length,
        max_segment_length,
        single_count,
        multi_count,
        phrase_count,
        fallback_count,
        avg_phrase_weight,
        min_phrase_weight,
        max_phrase_weight,
        adjacency_sum,
        adjacency_min,
        adjacency_avg,
        float(len(left)),
        float(len(right)),
        stable_hash("|".join(left[-3:])),
        stable_hash("|".join(right[:3])),
        stable_hash(text),
        stable_hash("|".join(values)),
        han_ratio(text),
        boundary_match_score(text, left, right),
    ]
    if len(features) < EXPECTED_DIM:
        features.extend([0.0] * (EXPECTED_DIM - len(features)))
    return features[:EXPECTED_DIM]


def load_groups(path: str):
    groups = []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                groups.append(json.loads(line))
    return groups


def flatten_groups(groups):
    rows = []
    for group in groups:
        context = group.get("context") or {"committedLeftContext": [], "committedRightContext": []}
        gold_text = group.get("gold_text")
        for candidate in group.get("candidates", []):
            rows.append(
                {
                    "group_id": group["group_id"],
                    "text": candidate["text"],
                    "features": encode_candidate(candidate, context),
                    "label": 1.0 if candidate["text"] == gold_text else 0.0,
                }
            )
    return rows


def build_arrays(rows):
    x = np.asarray([row["features"] for row in rows], dtype=np.float32)
    y = np.asarray([row["label"] for row in rows], dtype=np.float32)
    return x, y


def fit_standardizer(x_train: np.ndarray):
    mean = x_train.mean(axis=0).astype(np.float32)
    std = x_train.std(axis=0).astype(np.float32)
    std = np.where(std < 1e-6, 1.0, std).astype(np.float32)
    return mean, std


def transform_features(x: np.ndarray, mean: np.ndarray, std: np.ndarray):
    return ((x - mean) / std).astype(np.float32)


def predict_logit(model, features: np.ndarray) -> float:
    weights = model.coef_[0].astype(np.float32)
    bias = float(model.intercept_[0])
    return float(features @ weights + bias)


def predict_score(model, features: np.ndarray) -> float:
    clipped = max(min(predict_logit(model, features), 30.0), -30.0)
    return float(1.0 / (1.0 + np.exp(-clipped)))


def evaluate(model, groups, mean: np.ndarray, std: np.ndarray):
    top1_hits = 0
    mrr_sum = 0.0
    evaluated = 0
    rescued = 0
    baseline_top1 = 0

    for group in groups:
        context = group.get("context") or {"committedLeftContext": [], "committedRightContext": []}
        gold_text = group.get("gold_text")
        candidates = group.get("candidates", [])
        if not candidates or not gold_text:
            continue
        baseline = sorted(candidates, key=lambda item: item["localScore"], reverse=True)
        if baseline and baseline[0]["text"] == gold_text:
            baseline_top1 += 1

        scored = []
        for candidate in candidates:
            features = np.asarray(encode_candidate(candidate, context), dtype=np.float32)
            normalized = transform_features(features, mean, std)
            score = predict_score(model, normalized)
            scored.append((score, candidate))
        scored.sort(key=lambda item: item[0], reverse=True)
        evaluated += 1
        if scored and scored[0][1]["text"] == gold_text:
            top1_hits += 1
            if baseline and baseline[0]["text"] != gold_text:
                rescued += 1
        for index, (_, candidate) in enumerate(scored, start=1):
            if candidate["text"] == gold_text:
                mrr_sum += 1.0 / index
                break

    return {
        "groups": evaluated,
        "top1": float(top1_hits / max(evaluated, 1)),
        "mrr": float(mrr_sum / max(evaluated, 1)),
        "baseline_top1": float(baseline_top1 / max(evaluated, 1)),
        "rescued": rescued,
    }


def summarize_logits(model, groups, mean: np.ndarray, std: np.ndarray):
    logits = []
    probs = []
    for group in groups:
        context = group.get("context") or {"committedLeftContext": [], "committedRightContext": []}
        for candidate in group.get("candidates", []):
            features = np.asarray(encode_candidate(candidate, context), dtype=np.float32)
            normalized = transform_features(features, mean, std)
            logits.append(predict_logit(model, normalized))
            probs.append(predict_score(model, normalized))

    if not logits:
        return {"count": 0}

    logits_arr = np.asarray(logits, dtype=np.float32)
    probs_arr = np.asarray(probs, dtype=np.float32)
    return {
        "count": int(logits_arr.shape[0]),
        "logit_min": float(logits_arr.min()),
        "logit_p10": float(np.percentile(logits_arr, 10)),
        "logit_p50": float(np.percentile(logits_arr, 50)),
        "logit_p90": float(np.percentile(logits_arr, 90)),
        "logit_max": float(logits_arr.max()),
        "prob_min": float(probs_arr.min()),
        "prob_p10": float(np.percentile(probs_arr, 10)),
        "prob_p50": float(np.percentile(probs_arr, 50)),
        "prob_p90": float(np.percentile(probs_arr, 90)),
        "prob_max": float(probs_arr.max()),
    }


def export_coreml(model, output_dir: Path):
    if ct is None or datatypes is None or NeuralNetworkBuilder is None:
        return None
    input_features = [("features", datatypes.Array(EXPECTED_DIM))]
    output_features = [("score", datatypes.Array(1))]
    builder = NeuralNetworkBuilder(input_features, output_features, disable_rank5_shape_mapping=True)
    weights = model.coef_.astype(np.float32)
    if weights.ndim == 2:
        weights = weights[0]
    bias = float(model.intercept_[0]) if np.ndim(model.intercept_) else float(model.intercept_)
    builder.add_inner_product(
        name="sentence_linear",
        W=weights.reshape(1, EXPECTED_DIM),
        b=np.asarray([bias], dtype=np.float32),
        input_channels=EXPECTED_DIM,
        output_channels=1,
        has_bias=True,
        input_name="features",
        output_name="score_raw",
    )
    builder.add_activation(
        name="sentence_sigmoid",
        non_linearity="SIGMOID",
        input_name="score_raw",
        output_name="score",
    )
    spec = builder.spec
    spec.description.input[0].shortDescription = "Sentence reranker feature vector"
    spec.description.output[0].shortDescription = "Sentence reranker score"
    path = output_dir / "SentenceRanker.mlmodel"
    mlmodel = ct.models.MLModel(spec)
    mlmodel.save(str(path))
    return str(path)


def write_json(path: Path, payload):
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description="Train UnifyIME sentence reranker.")
    parser.add_argument("--train", required=True)
    parser.add_argument("--valid", required=True)
    parser.add_argument("--test")
    parser.add_argument("--output", required=True)
    parser.add_argument("--learning-rate", type=float, default=1.0)
    parser.add_argument("--l2", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args()

    output_dir = Path(args.output).expanduser()
    output_dir.mkdir(parents=True, exist_ok=True)

    train_groups = load_groups(args.train)
    valid_groups = load_groups(args.valid)
    test_groups = load_groups(args.test) if args.test else []

    train_rows = flatten_groups(train_groups)
    valid_rows = flatten_groups(valid_groups)
    test_rows = flatten_groups(test_groups)

    if not train_rows or not valid_rows:
        raise SystemExit("train/valid dataset is empty")

    x_train, y_train = build_arrays(train_rows)
    np.random.seed(args.seed)
    mean, std = fit_standardizer(x_train)
    x_train_norm = transform_features(x_train, mean, std)
    model = LogisticRegression(
        random_state=args.seed,
        max_iter=2000,
        solver="lbfgs",
        C=(1.0 / max(args.l2, 1e-6)),
    )
    model.fit(x_train_norm, y_train.astype(np.int64))

    train_metrics = evaluate(model, train_groups, mean, std)
    valid_metrics = evaluate(model, valid_groups, mean, std)
    test_metrics = evaluate(model, test_groups, mean, std) if test_groups else None

    exported_model = export_coreml(model, output_dir)
    np.savez(
        output_dir / "sentence_reranker_linear_weights.npz",
        weights=model.coef_.astype(np.float32),
        bias=model.intercept_.astype(np.float32),
        mean=mean.astype(np.float32),
        std=std.astype(np.float32),
    )

    metrics = {
        "backend_effective": "sklearn_logistic",
        "feature_dimension": EXPECTED_DIM,
        "train_groups": len(train_groups),
        "valid_groups": len(valid_groups),
        "test_groups": len(test_groups),
        "train": train_metrics,
        "valid": valid_metrics,
        "test": test_metrics,
        "train_logits": summarize_logits(model, train_groups, mean, std),
        "valid_logits": summarize_logits(model, valid_groups, mean, std),
        "test_logits": summarize_logits(model, test_groups, mean, std) if test_groups else None,
        "config": {
            "train": args.train,
            "valid": args.valid,
            "test": args.test,
            "output": str(output_dir),
            "learning_rate": args.learning_rate,
            "l2": args.l2,
            "seed": args.seed,
            "recommended_max_chars": 30,
        },
        "coreml_exported": exported_model is not None,
        "coreml_model_path": exported_model,
    }
    write_json(output_dir / "metrics.json", metrics)
    write_json(
        output_dir / "train_config.json",
        {
            "train": args.train,
            "valid": args.valid,
            "test": args.test,
            "output": str(output_dir),
            "learning_rate": args.learning_rate,
            "l2": args.l2,
            "seed": args.seed,
        },
    )

    print(json.dumps(metrics, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
