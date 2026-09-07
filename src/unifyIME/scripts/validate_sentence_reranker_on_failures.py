#!/usr/bin/env python3
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path


def resolve_root() -> Path:
    explicit = os.environ.get("UNIFYIME_WORKSPACE_ROOT") or os.environ.get("FASTCHIME_WORKSPACE_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


ROOT = resolve_root()
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
BUILD_DATASET = ROOT / "src" / "unifyIME" / "scripts" / "build_sentence_reranker_dataset.py"
AB_CHECK = ROOT / "src" / "unifyIME" / "scripts" / "sentence_reranker_ab_check.py"
DEFAULT_WEIGHTS = ROOT / "artifacts" / "sentence_reranker" / "sentence_reranker_linear_weights.npz"


def run_capture(cmd):
    return subprocess.run(
        cmd,
        cwd=ROOT,
        check=False,
        text=True,
        capture_output=True,
    )


def parse_failures(stdout: str):
    failures = []
    current_sentence = None
    current_status = None
    for line in stdout.splitlines():
        if re.match(r"^\[\d+\] (PASS|FAIL)$", line):
            current_status = "FAIL" if "FAIL" in line else "PASS"
        elif line.startswith("句子: "):
            current_sentence = line[len("句子: "):].strip()
        elif line.startswith("---"):
            if current_status == "FAIL" and current_sentence:
                failures.append(current_sentence)
            current_sentence = None
            current_status = None
    return failures


def inspect_groups(dataset_path: Path, weights_path: Path):
    sys.path.insert(0, str(ROOT / "src" / "unifyIME" / "scripts"))
    from train_sentence_reranker import load_groups  # type: ignore
    from sentence_reranker_ab_check import load_linear_weights, rerank_score  # type: ignore

    groups = load_groups(str(dataset_path))
    weights, bias, mean, std = load_linear_weights(weights_path)
    results = []

    for group in groups:
        gold = group.get("gold_text")
        context = group.get("context") or {"committedLeftContext": [], "committedRightContext": []}
        candidates = group.get("candidates", [])
        baseline = sorted(candidates, key=lambda item: item["localScore"], reverse=True)
        reranked = sorted(
            candidates,
            key=lambda item: (item["localScore"] + rerank_score(item, context, weights, bias, mean, std)),
            reverse=True,
        )

        def find_rank(rows, target):
            for index, row in enumerate(rows, start=1):
                if row["text"] == target:
                    return index
            return None

        results.append({
            "group_id": group.get("group_id"),
            "gold_text": gold,
            "baseline_top": baseline[0]["text"] if baseline else "",
            "reranked_top": reranked[0]["text"] if reranked else "",
            "baseline_rank": find_rank(baseline, gold),
            "reranked_rank": find_rank(reranked, gold),
            "top3_baseline": [item["text"] for item in baseline[:3]],
            "top3_reranked": [item["text"] for item in reranked[:3]],
        })
    return results


def main() -> int:
    parser = argparse.ArgumentParser(description="Validate sentence reranker on current selftest failures.")
    parser.add_argument("--mode", default="short-sentences")
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--weights", default=str(DEFAULT_WEIGHTS))
    parser.add_argument("--work-dir", default=str(Path(tempfile.gettempdir()) / "sentence_reranker_failure_check"))
    parser.add_argument("--top-paths", type=int, default=8)
    parser.add_argument("--top-candidates-per-span", type=int, default=6)
    args = parser.parse_args()

    weights_path = Path(args.weights)
    work_dir = Path(args.work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)

    selftest = run_capture([str(APP), "selftest", args.mode, str(args.batch_size)])
    (work_dir / "selftest_stdout.txt").write_text(selftest.stdout, encoding="utf-8")
    (work_dir / "selftest_stderr.txt").write_text(selftest.stderr, encoding="utf-8")

    failures = parse_failures(selftest.stdout)
    failures_path = work_dir / "failed_sentences.txt"
    failures_path.write_text("\n".join(failures) + ("\n" if failures else ""), encoding="utf-8")

    if not failures:
        summary = {
            "selftest_returncode": selftest.returncode,
            "failure_count": 0,
            "message": "No failed sentences found.",
            "work_dir": str(work_dir),
        }
        print(json.dumps(summary, ensure_ascii=False, indent=2))
        return 0

    dataset_proc = run_capture([
        "python3",
        str(BUILD_DATASET),
        "--input",
        str(failures_path),
        "--output-dir",
        str(work_dir / "dataset"),
        "--batch-size",
        "0",
        "--top-paths",
        str(args.top_paths),
        "--top-candidates-per-span",
        str(args.top_candidates_per_span),
    ])
    (work_dir / "dataset_builder_stdout.txt").write_text(dataset_proc.stdout, encoding="utf-8")
    (work_dir / "dataset_builder_stderr.txt").write_text(dataset_proc.stderr, encoding="utf-8")

    dataset_path = work_dir / "dataset" / "sentence_groups.jsonl"
    ab_proc = run_capture([
        "python3",
        str(AB_CHECK),
        "--dataset",
        str(dataset_path),
        "--weights",
        str(weights_path),
        "--output",
        str(work_dir / "ab_result.json"),
    ])
    (work_dir / "ab_stdout.txt").write_text(ab_proc.stdout, encoding="utf-8")
    (work_dir / "ab_stderr.txt").write_text(ab_proc.stderr, encoding="utf-8")

    group_details = inspect_groups(dataset_path, weights_path)
    (work_dir / "group_details.json").write_text(
        json.dumps(group_details, ensure_ascii=False, indent=2),
        encoding="utf-8"
    )

    summary = {
        "selftest_returncode": selftest.returncode,
        "failure_count": len(failures),
        "failures": failures,
        "dataset_returncode": dataset_proc.returncode,
        "ab_returncode": ab_proc.returncode,
        "ab_result": json.loads((work_dir / "ab_result.json").read_text(encoding="utf-8")),
        "work_dir": str(work_dir),
    }
    (work_dir / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
