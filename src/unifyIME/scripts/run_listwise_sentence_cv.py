#!/usr/bin/env python3
"""Train and aggregate repeated sentence-safe listwise evaluations."""

from __future__ import annotations

import argparse
import json
import statistics
import subprocess
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
TRAIN_SCRIPT = ROOT / "src/unifyIME/scripts/train_listwise_transformer.py"


def load_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def metric_summary(values: list[float]) -> dict[str, float]:
    return {
        "mean": statistics.fmean(values),
        "stddev": statistics.pstdev(values) if len(values) > 1 else 0.0,
        "minimum": min(values),
        "maximum": max(values),
    }


def stream_command(command: list[str], log_path: Path) -> None:
    print("+", " ".join(command), flush=True)
    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(
            command,
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            bufsize=1,
        )
        assert process.stdout is not None
        for line in process.stdout:
            print(line, end="", flush=True)
            log.write(line)
        return_code = process.wait()
    if return_code != 0:
        raise subprocess.CalledProcessError(return_code, command)


def fold_result(
    split_dir: Path,
    output_dir: Path,
    metrics: dict[str, Any],
) -> dict[str, Any]:
    split_summary_path = split_dir / "summary.json"
    split_summary = load_json(split_summary_path) if split_summary_path.exists() else {}
    test = metrics["test"]
    selection_test = test.get("cohorts", {}).get("real_selection", {})
    safety_test = selection_test if int(selection_test.get("groups", 0)) > 0 else test
    groups = max(1, int(safety_test["groups"]))
    return {
        "split": split_dir.name,
        "split_seed": split_summary.get("seed"),
        "model_best_epoch": metrics["best_epoch"],
        "output": str(output_dir),
        "train_groups": metrics["train_groups"],
        "valid_groups": metrics["valid_groups"],
        "test_groups": metrics["test_groups"],
        "test": test,
        "test_top1_lift": float(test["combined_top1"]) - float(test["baseline_top1"]),
        "safety_cohort": "real_selection" if safety_test is selection_test else "overall",
        "test_safety_top1_lift": float(safety_test["combined_top1"])
        - float(safety_test["baseline_top1"]),
        "test_harm_rate": float(safety_test["harmed"]) / groups,
        "safe": float(safety_test["harmed"]) / groups
        <= float(metrics["max_valid_harm_rate"]),
        "positive_net_lift": int(safety_test["net_lift"]) > 0,
        "nonnegative_net_lift": int(safety_test["net_lift"]) >= 0,
    }


def aggregate_results(results: list[dict[str, Any]]) -> dict[str, Any]:
    test_metrics = [result["test"] for result in results]
    numeric_keys = (
        "baseline_top1",
        "combined_top1",
        "pure_top1",
        "hard_combined_top1",
        "hard_pure_top1",
        "mean_abs_residual",
    )
    aggregate: dict[str, Any] = {
        key: metric_summary([float(metrics[key]) for metrics in test_metrics])
        for key in numeric_keys
    }
    aggregate["top1_lift"] = metric_summary(
        [float(result["test_top1_lift"]) for result in results]
    )
    aggregate["harm_rate"] = metric_summary(
        [float(result["test_harm_rate"]) for result in results]
    )
    for key in ("groups", "hard_groups", "improved", "harmed", "net_lift", "changed"):
        values = [int(metrics[key]) for metrics in test_metrics]
        aggregate[key] = {
            "sum": sum(values),
            "mean": statistics.fmean(values),
            "minimum": min(values),
            "maximum": max(values),
        }
    aggregate["safe_folds"] = sum(bool(result["safe"]) for result in results)
    aggregate["positive_net_lift_folds"] = sum(
        bool(result["positive_net_lift"]) for result in results
    )
    aggregate["nonnegative_net_lift_folds"] = sum(
        bool(result["nonnegative_net_lift"]) for result in results
    )
    aggregate["all_folds_safe"] = all(bool(result["safe"]) for result in results)
    aggregate["all_folds_positive_net_lift"] = all(
        bool(result["positive_net_lift"]) for result in results
    )
    aggregate["all_folds_nonnegative_net_lift"] = all(
        bool(result["nonnegative_net_lift"]) for result in results
    )
    aggregate["safety_cohort"] = (
        "real_selection"
        if all(result["safety_cohort"] == "real_selection" for result in results)
        else "mixed_fallback"
    )
    cohort_names = sorted(
        {
            name
            for metrics in test_metrics
            for name in metrics.get("cohorts", {})
        }
    )
    aggregate["cohorts"] = {}
    for name in cohort_names:
        cohort_metrics = [
            metrics["cohorts"][name]
            for metrics in test_metrics
            if int(metrics.get("cohorts", {}).get(name, {}).get("groups", 0)) > 0
        ]
        if not cohort_metrics:
            continue
        cohort_summary: dict[str, Any] = {
            key: metric_summary([float(metrics[key]) for metrics in cohort_metrics])
            for key in numeric_keys
        }
        cohort_summary["top1_lift"] = metric_summary(
            [
                float(metrics["combined_top1"]) - float(metrics["baseline_top1"])
                for metrics in cohort_metrics
            ]
        )
        for key in ("groups", "hard_groups", "improved", "harmed", "net_lift", "changed"):
            values = [int(metrics[key]) for metrics in cohort_metrics]
            cohort_summary[key] = {
                "sum": sum(values),
                "mean": statistics.fmean(values),
                "minimum": min(values),
                "maximum": max(values),
            }
        aggregate["cohorts"][name] = cohort_summary
    return aggregate


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dataset-root", required=True)
    parser.add_argument("--output-root", required=True)
    parser.add_argument("--max-splits", type=int, default=0)
    parser.add_argument("--epochs", type=int, default=3)
    parser.add_argument("--minimum-epochs", type=int, default=1)
    parser.add_argument("--early-stopping-patience", type=int, default=0)
    parser.add_argument("--batch-size", type=int, default=4)
    parser.add_argument("--eval-batch-size", type=int, default=8)
    parser.add_argument("--learning-rate", type=float, default=3e-4)
    parser.add_argument("--hard-weight", type=float, default=8.0)
    parser.add_argument("--weak-article-weight", type=float, default=0.1)
    parser.add_argument("--gradient-log-interval", type=int, default=100)
    parser.add_argument("--evaluation-residual-scale", type=float, default=0.5)
    parser.add_argument("--max-valid-harm-rate", type=float, default=0.01)
    parser.add_argument("--mixed-augment-probability", type=float, default=0.15)
    parser.add_argument("--model-seed", type=int, default=42)
    parser.add_argument("--cpu", action="store_true")
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--export-folds", action="store_true")
    parser.add_argument("--fail-on-unsafe", action="store_true")
    args = parser.parse_args()

    dataset_root = Path(args.dataset_root).expanduser()
    output_root = Path(args.output_root).expanduser()
    output_root.mkdir(parents=True, exist_ok=True)
    split_dirs = sorted(path for path in dataset_root.glob("split-*") if path.is_dir())
    if len(split_dirs) < 2:
        parser.error("dataset root must contain at least two split-* directories")
    if args.max_splits > 0:
        split_dirs = split_dirs[: args.max_splits]
    if not split_dirs:
        parser.error("no split-* directories selected")

    results: list[dict[str, Any]] = []
    for split_dir in split_dirs:
        for name in ("train.jsonl", "valid.jsonl", "test.jsonl"):
            if not (split_dir / name).is_file():
                raise FileNotFoundError(split_dir / name)
        fold_output = output_root / split_dir.name
        fold_output.mkdir(parents=True, exist_ok=True)
        metrics_path = fold_output / "metrics.json"
        if not (args.resume and metrics_path.exists()):
            command = [
                sys.executable,
                str(TRAIN_SCRIPT),
                "--train",
                str(split_dir / "train.jsonl"),
                "--valid",
                str(split_dir / "valid.jsonl"),
                "--test",
                str(split_dir / "test.jsonl"),
                "--output",
                str(fold_output),
                "--epochs",
                str(args.epochs),
                "--minimum-epochs",
                str(args.minimum_epochs),
                "--early-stopping-patience",
                str(args.early_stopping_patience),
                "--batch-size",
                str(args.batch_size),
                "--eval-batch-size",
                str(args.eval_batch_size),
                "--learning-rate",
                str(args.learning_rate),
                "--hard-weight",
                str(args.hard_weight),
                "--weak-article-weight",
                str(args.weak_article_weight),
                "--gradient-log-interval",
                str(args.gradient_log_interval),
                "--evaluation-residual-scale",
                str(args.evaluation_residual_scale),
                "--max-valid-harm-rate",
                str(args.max_valid_harm_rate),
                "--mixed-augment-probability",
                str(args.mixed_augment_probability),
                "--seed",
                str(args.model_seed),
            ]
            if args.cpu:
                command.append("--cpu")
            if not args.export_folds:
                command.append("--skip-export")
            stream_command(command, fold_output / "train.log")
        metrics = load_json(metrics_path)
        results.append(fold_result(split_dir, fold_output, metrics))

    aggregate = aggregate_results(results)
    summary = {
        "schema": "listwise_sentence_cv_v1",
        "dataset_root": str(dataset_root),
        "output_root": str(output_root),
        "fold_count": len(results),
        "training": {
            "epochs": args.epochs,
            "minimum_epochs": args.minimum_epochs,
            "early_stopping_patience": args.early_stopping_patience,
            "batch_size": args.batch_size,
            "eval_batch_size": args.eval_batch_size,
            "learning_rate": args.learning_rate,
            "hard_weight": args.hard_weight,
            "weak_article_weight": args.weak_article_weight,
            "gradient_log_interval": args.gradient_log_interval,
            "evaluation_residual_scale": args.evaluation_residual_scale,
            "max_valid_harm_rate": args.max_valid_harm_rate,
            "mixed_augment_probability": args.mixed_augment_probability,
            "model_seed": args.model_seed,
            "device": "cpu" if args.cpu else "automatic_mps",
        },
        "folds": results,
        "aggregate": aggregate,
    }
    summary_path = output_root / "cv_summary.json"
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    print(f"saved_summary={summary_path}")
    if args.fail_on_unsafe and not aggregate["all_folds_safe"]:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
