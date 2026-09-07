#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_IME_DATA_ROOT = Path(
    os.environ.get("UNIFYIME_IME_DATA_ROOT")
    or os.environ.get("FASTCHIME_IME_DATA_ROOT")
    or (ROOT / "artifacts" / "datasets" / "IME").as_posix()
).expanduser()
DEFAULT_CHECKPOINT_ROOT = Path(
    os.environ.get("UNIFYIME_CHECKPOINT_ROOT")
    or os.environ.get("FASTCHIME_CHECKPOINT_ROOT")
    or (ROOT / "artifacts" / "checkpoints").as_posix()
).expanduser()
PROJECT_ARTIFACTS_ROOT = ROOT / "artifacts" / "training"
TRAIN_PY = ROOT / "src" / "unifyIME" / "scripts" / "train_candidate_ranker.py"
INSTALL_PY = ROOT / "src" / "unifyIME" / "scripts" / "install_ranker_model.py"
TRAINING_WINDOW_BINARIES = [
    ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME",
    Path.home() / "Library" / "Input Methods" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME",
]
def run(cmd):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, check=True, cwd=ROOT)


def maybe_launch_training_window(output: Path):
    if os.environ.get("FASTCHIME_DISABLE_TRAINING_WINDOW") == "1":
        return
    for binary in TRAINING_WINDOW_BINARIES:
        if not binary.exists():
            continue
        try:
            subprocess.Popen(
                [str(binary), "training-progress-window", str(output)],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            return
        except Exception:
            continue


def clear_stale_training_outputs(output: Path):
    for name in ("metrics.json", "metrics.partial.json", "training_progress.json", "training_control.json"):
        path = output / name
        try:
            if path.exists():
                path.unlink()
        except Exception:
            pass


def sync_project_artifacts(output: Path) -> Path:
    project_dir = PROJECT_ARTIFACTS_ROOT / output.name
    project_dir.mkdir(parents=True, exist_ok=True)

    stale_temp_dirs = [
        project_dir / "feature_cache",
    ]
    for stale_dir in stale_temp_dirs:
        if stale_dir.exists():
            subprocess.run(["rm", "-rf", str(stale_dir)], check=True, cwd=ROOT)

    artifact_names = [
        "CandidateRanker.mlpackage",
        "CandidateRanker.mlmodel",
        "ranker_checkpoint.pt",
        "metrics.json",
        "metrics.partial.json",
        "train_config.json",
        "feature_schema.json",
        "training_progress.json",
    ]
    for name in artifact_names:
        source = output / name
        target = project_dir / name
        if not source.exists():
            continue
        if source.is_dir():
            if target.exists():
                subprocess.run(["rm", "-rf", str(target)], check=True, cwd=ROOT)
            subprocess.run(["ditto", str(source), str(target)], check=True, cwd=ROOT)
        else:
            target.write_bytes(source.read_bytes())
    return project_dir


def load_continue_config(output: Path):
    config_path = output / "train_config.json"
    if config_path.exists():
        return json.loads(config_path.read_text(encoding="utf-8"))
    return {
        "train": str(DEFAULT_IME_DATA_ROOT / "x20" / "train.jsonl"),
        "valid": str(DEFAULT_IME_DATA_ROOT / "x20" / "valid.jsonl"),
        "test": str(DEFAULT_IME_DATA_ROOT / "x20" / "test.jsonl"),
        "output": str(output),
        "backend": "mlp",
        "epochs": 100,
        "batch_size": 128,
        "learning_rate": 0.001,
        "hidden_sizes": "128,64,32",
        "max_depth": 3,
        "seed": 77,
        "pairwise_top_k": 3,
        "pairwise_boost": 2.0,
        "neighbor_noise_weight": 0.35,
        "builtin_positive_boost": 1.5,
        "builtin_negative_boost": 1.05,
        "checkpoint_interval": 5,
        "train_chunk_size": 50000,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ime-data-root")
    parser.add_argument("--checkpoint-root")
    parser.add_argument("--train")
    parser.add_argument("--valid")
    parser.add_argument("--test")
    parser.add_argument("--output")
    parser.add_argument("--backend", choices=["tree", "mlp"])
    parser.add_argument("--epochs", type=int)
    parser.add_argument("--batch-size", type=int)
    parser.add_argument("--learning-rate", type=float)
    parser.add_argument("--hidden-sizes")
    parser.add_argument("--max-depth", type=int)
    parser.add_argument("--seed", type=int)
    parser.add_argument("--pairwise-top-k", type=int)
    parser.add_argument("--pairwise-boost", type=float)
    parser.add_argument("--neighbor-noise-weight", type=float)
    parser.add_argument("--builtin-positive-boost", type=float)
    parser.add_argument("--builtin-negative-boost", type=float)
    parser.add_argument("--checkpoint-interval", type=int)
    parser.add_argument("--train-chunk-size", type=int)
    parser.add_argument("--resume-checkpoint")
    parser.add_argument("--continue-from")
    parser.add_argument("--install", action="store_true")
    args = parser.parse_args()

    ime_data_root = Path(args.ime_data_root).expanduser() if args.ime_data_root else DEFAULT_IME_DATA_ROOT
    checkpoint_root = Path(args.checkpoint_root).expanduser() if args.checkpoint_root else DEFAULT_CHECKPOINT_ROOT
    default_continue_output = checkpoint_root / "mlp_x20"

    if args.continue_from:
        continue_dir = Path(args.continue_from).expanduser()
    elif not args.train and default_continue_output.exists():
        continue_dir = default_continue_output
    else:
        continue_dir = None

    if continue_dir is not None:
        config = load_continue_config(continue_dir)
        args.train = args.train or config.get("train")
        args.valid = args.valid or config.get("valid")
        args.test = args.test or config.get("test")
        args.output = args.output or str(continue_dir)
        args.backend = args.backend or config.get("backend", "mlp")
        args.epochs = args.epochs or config.get("epochs", 100)
        args.batch_size = args.batch_size or config.get("batch_size", 128)
        args.learning_rate = args.learning_rate or config.get("learning_rate", 0.001)
        args.hidden_sizes = args.hidden_sizes or config.get("hidden_sizes", "192,128,96,64,32,8")
        args.max_depth = args.max_depth or config.get("max_depth", 3)
        args.seed = args.seed or config.get("seed", 42)
        args.pairwise_top_k = args.pairwise_top_k or config.get("pairwise_top_k", 3)
        args.pairwise_boost = args.pairwise_boost or config.get("pairwise_boost", 2.0)
        args.neighbor_noise_weight = args.neighbor_noise_weight or config.get("neighbor_noise_weight", 0.35)
        args.builtin_positive_boost = args.builtin_positive_boost or config.get("builtin_positive_boost", 2.5)
        args.builtin_negative_boost = args.builtin_negative_boost or config.get("builtin_negative_boost", 1.15)
        args.checkpoint_interval = getattr(args, "checkpoint_interval", None) or config.get("checkpoint_interval", 5)
        args.train_chunk_size = getattr(args, "train_chunk_size", None) or config.get("train_chunk_size", 50000)
        if not args.resume_checkpoint:
            checkpoint = continue_dir / "ranker_checkpoint.pt"
            if checkpoint.exists():
                args.resume_checkpoint = str(checkpoint)

    args.backend = args.backend or "tree"
    args.train = args.train or str(ime_data_root / "x20" / "train.jsonl")
    args.valid = args.valid or str(ime_data_root / "x20" / "valid.jsonl")
    args.test = args.test or str(ime_data_root / "x20" / "test.jsonl")
    args.output = args.output or str(default_continue_output)
    args.epochs = args.epochs or 100
    args.batch_size = args.batch_size or 4
    args.learning_rate = args.learning_rate or 0.05
    args.hidden_sizes = args.hidden_sizes or "128,64,32"
    args.max_depth = args.max_depth or 3
    args.seed = args.seed or 42
    args.pairwise_top_k = args.pairwise_top_k or 3
    args.pairwise_boost = args.pairwise_boost or 2.0
    args.neighbor_noise_weight = args.neighbor_noise_weight or 0.35
    args.builtin_positive_boost = args.builtin_positive_boost or 2.5
    args.builtin_negative_boost = args.builtin_negative_boost or 1.15
    args.checkpoint_interval = getattr(args, "checkpoint_interval", None) or 5
    args.train_chunk_size = getattr(args, "train_chunk_size", None) or 50000

    for field in ("train", "valid", "test", "output"):
        if not getattr(args, field):
            parser.error(f"--{field} is required")

    output = Path(args.output).expanduser()
    output.mkdir(parents=True, exist_ok=True)
    clear_stale_training_outputs(output)
    maybe_launch_training_window(output)

    run([
        "python3", str(TRAIN_PY),
        "--train", args.train,
        "--valid", args.valid,
        "--test", args.test,
        "--output", str(output),
        "--backend", args.backend,
        "--epochs", str(args.epochs),
        "--batch-size", str(args.batch_size),
        "--learning-rate", str(args.learning_rate),
        "--hidden-sizes", str(args.hidden_sizes),
        "--max-depth", str(args.max_depth),
        "--seed", str(args.seed),
        "--pairwise-top-k", str(args.pairwise_top_k),
        "--pairwise-boost", str(args.pairwise_boost),
        "--neighbor-noise-weight", str(args.neighbor_noise_weight),
        "--builtin-positive-boost", str(args.builtin_positive_boost),
        "--builtin-negative-boost", str(args.builtin_negative_boost),
        "--checkpoint-interval", str(args.checkpoint_interval),
        "--train-chunk-size", str(args.train_chunk_size),
    ] + (["--resume-checkpoint", str(args.resume_checkpoint)] if args.resume_checkpoint else []))

    metrics_path = output / "metrics.json"
    project_artifact_dir = sync_project_artifacts(output)
    if metrics_path.exists():
        metrics = json.loads(metrics_path.read_text(encoding="utf-8"))
        print(json.dumps({
            "backend_requested": metrics.get("backend_requested"),
            "backend_effective": metrics.get("backend_effective"),
            "valid_top1": metrics["valid"]["top1"],
            "valid_mrr": metrics["valid"]["mrr"],
            "test_top1": metrics["test"]["top1"] if metrics.get("test") else None,
            "test_mrr": metrics["test"]["mrr"] if metrics.get("test") else None,
            "best_epoch": metrics.get("best_epoch"),
        }, ensure_ascii=False, indent=2))

    if args.install:
        source_model = project_artifact_dir / "CandidateRanker.mlpackage"
        if not source_model.exists():
            source_model = project_artifact_dir / "CandidateRanker.mlmodel"
        run([
            "python3", str(INSTALL_PY),
            str(source_model),
        ])


if __name__ == "__main__":
    main()
