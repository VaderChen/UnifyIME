#!/usr/bin/env python3
import argparse
import json
import os
import random
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
BUILD_SH = ROOT / "fastChIME" / "build.sh"
TRAIN_PY = ROOT / "fastChIME" / "scripts" / "train_candidate_ranker.py"
FETCH_PY = ROOT / "fastChIME" / "scripts" / "fetch_traditional_corpus.py"
MODEL_DIR = ROOT / "fastChIME" / "Resources" / "Models"
REGRESSION_FILE = ROOT / "data" / "regression_sentences.txt"


def run(cmd, env=None):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True, env=env)


def capture(cmd, env=None):
    print("+", " ".join(str(c) for c in cmd), flush=True)
    result = subprocess.run(cmd, cwd=ROOT, check=False, env=env, text=True, capture_output=True)
    if result.returncode not in (0, 2):
        raise subprocess.CalledProcessError(result.returncode, cmd, output=result.stdout, stderr=result.stderr)
    return result.stdout


def prefix_ids(src_path: Path, dest_path: Path, prefix: str):
    with src_path.open("r", encoding="utf-8") as src, dest_path.open("w", encoding="utf-8") as dst:
        for line in src:
            row = json.loads(line)
            row["sample_id"] = f"{prefix}:{row['sample_id']}"
            row["case_id"] = f"{prefix}:{row['case_id']}"
            dst.write(json.dumps(row, ensure_ascii=False) + "\n")


def combine_jsonl(inputs, output):
    with output.open("w", encoding="utf-8") as dst:
        for path in inputs:
            with path.open("r", encoding="utf-8") as src:
                shutil.copyfileobj(src, dst)


def split_dataset(src_path: Path, out_dir: Path, seed: int):
    rows = [json.loads(line) for line in src_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    groups = {}
    for row in rows:
        groups.setdefault((row["case_id"], row["step_id"]), []).append(row)
    grouped_rows = list(groups.values())
    random.Random(seed).shuffle(grouped_rows)
    n = len(grouped_rows)
    train_end = int(n * 0.8)
    valid_end = int(n * 0.9)
    train_rows = [row for group in grouped_rows[:train_end] for row in group]
    valid_rows = [row for group in grouped_rows[train_end:valid_end] for row in group]
    test_rows = [row for group in grouped_rows[valid_end:] for row in group]
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, subset in [
        ("train.jsonl", train_rows),
        ("valid.jsonl", valid_rows),
        ("test.jsonl", test_rows),
    ]:
        path = out_dir / name
        with path.open("w", encoding="utf-8") as f:
            for row in subset:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return {
        "total_rows": len(rows),
        "total_groups": n,
        "train": len(train_rows),
        "valid": len(valid_rows),
        "test": len(test_rows),
    }


def parse_selftest_failures(text: str):
    failures = []
    current_sentence = None
    current_status = None
    for line in text.splitlines():
        if line.startswith("[") and ("PASS" in line or "FAIL" in line):
            current_status = "FAIL" if "FAIL" in line else "PASS"
        elif line.startswith("句子: "):
            current_sentence = line[len("句子: "):].strip()
        elif line.startswith("---"):
            if current_status == "FAIL" and current_sentence:
                failures.append(current_sentence)
            current_sentence = None
            current_status = None
    return failures


def update_regression_file(failures, hard_negative_sentences=None):
    baseline = [
        "我今天想試試看這個輸入法",
        "你現在可以正常打字聊天嗎",
        "這個功能看起來已經很穩定了",
        "請幫我把候選詞排序調整一下",
        "我們等一下再回頭修選字視窗",
        "如果有問題就直接把畫面貼給我",
        "這次改完之後反應速度快很多了",
        "他說明天早上要先去公司開會",
        "我希望連續輸入時不要一直卡住",
        "試試看變這個字現在能不能選到",
    ]
    hard_negative_sentences = hard_negative_sentences or []
    merged = []
    seen = set()
    for sentence in baseline + failures + hard_negative_sentences:
        if sentence and sentence not in seen:
            seen.add(sentence)
            merged.append(sentence)
    REGRESSION_FILE.parent.mkdir(parents=True, exist_ok=True)
    REGRESSION_FILE.write_text("\n".join(merged) + "\n", encoding="utf-8")


def extract_hard_negatives(report_path: Path, out_path: Path):
    data = json.loads(report_path.read_text(encoding="utf-8"))
    pairs = []
    for row in data:
        core = row.get("coreml_order") or []
        heur = row.get("heuristic_order") or []
        gold = row.get("segment_text")
        if not gold or not core or not heur:
            continue
        if core[0] == gold and heur[0] != gold:
            pairs.append({
                "sentence": row["sentence"],
                "segment_text": gold,
                "reading": row.get("reading"),
                "heuristic_top": heur[0],
                "coreml_top": core[0],
            })
    out_path.write_text(json.dumps(pairs, ensure_ascii=False, indent=2), encoding="utf-8")
    return pairs


def compile_model(mlmodel: Path):
    tmp_dir = ROOT / "fastChIME" / "Resources" / "Models_tmp_compile"
    if tmp_dir.exists():
        shutil.rmtree(tmp_dir)
    run(["xcrun", "coremlc", "compile", str(mlmodel), str(tmp_dir.parent)])
    compiled = tmp_dir.parent / "CandidateRanker.mlmodelc"
    backup = MODEL_DIR / "CandidateRanker.mlmodelc.loop_backup"
    if compiled.exists():
        if backup.exists():
            shutil.rmtree(backup)
        if (MODEL_DIR / "CandidateRanker.mlmodelc").exists():
            shutil.copytree(MODEL_DIR / "CandidateRanker.mlmodelc", backup)
            shutil.rmtree(MODEL_DIR / "CandidateRanker.mlmodelc")
        shutil.move(str(compiled), str(MODEL_DIR / "CandidateRanker.mlmodelc"))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--iterations", type=int, default=3)
    parser.add_argument("--target-sentences", type=int, default=9000)
    parser.add_argument("--dynamic-batch", type=int, default=6000)
    parser.add_argument("--word-batch", type=int, default=1200)
    parser.add_argument("--sentence-batch", type=int, default=1500)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--wiki-target-sentences", type=int, default=1500)
    parser.add_argument("--tatoeba-target-sentences", type=int, default=8500)
    args = parser.parse_args()

    corpus_txt = ROOT / "data" / "web_corpus" / "wiki_zh_hant_sentences.txt"
    corpus_meta = ROOT / "data" / "web_corpus" / "wiki_zh_hant_meta.json"
    run([
        "python3", str(FETCH_PY),
        "--output", str(corpus_txt),
        "--meta-output", str(corpus_meta),
        "--target-sentences", str(args.target_sentences),
        "--wiki-target-sentences", str(args.wiki_target_sentences),
        "--tatoeba-target-sentences", str(args.tatoeba_target_sentences),
    ])

    run([str(BUILD_SH)])
    update_regression_file([])

    loop_summary = []

    for iteration in range(1, args.iterations + 1):
        print(f"=== iteration {iteration} ===", flush=True)
        iter_dir = ROOT / "data" / f"ranker_x10_iter{iteration}"
        raw_dir = iter_dir / "raw"
        raw_dir.mkdir(parents=True, exist_ok=True)

        dataset_jobs = [
            ("default", ["dump-ranker-data", str(raw_dir / "default.jsonl"), "default", "200"]),
            ("short_words", ["dump-ranker-data", str(raw_dir / "short_words.jsonl"), "short-words", str(args.word_batch)]),
            ("short_sentences", ["dump-ranker-data", str(raw_dir / "short_sentences.jsonl"), "short-sentences", str(args.sentence_batch)]),
            ("dynamic", ["dump-ranker-data", str(raw_dir / "dynamic.jsonl"), "dynamic", str(args.dynamic_batch)]),
            ("web_corpus", ["dump-ranker-data", str(raw_dir / "web_corpus.jsonl"), str(corpus_txt), "0"]),
            ("regression", ["dump-ranker-data", str(raw_dir / "regression.jsonl"), str(REGRESSION_FILE), "0"]),
        ]

        prefixed_paths = []
        for name, cli in dataset_jobs:
            run([str(APP)] + cli)
            prefixed = raw_dir / f"{name}.prefixed.jsonl"
            prefix_ids(raw_dir / f"{name}.jsonl", prefixed, f"iter{iteration}:{name}")
            prefixed_paths.append(prefixed)

        merged = iter_dir / "all.jsonl"
        combine_jsonl(prefixed_paths, merged)
        split_stats = split_dataset(merged, iter_dir, args.seed + iteration)
        print(f"dataset_total={split_stats['total']} train={split_stats['train']} valid={split_stats['valid']} test={split_stats['test']}", flush=True)

        artifacts = ROOT / "fastChIME" / "artifacts" / f"x10_iter{iteration}"
        run([
            "python3", str(TRAIN_PY),
            "--train", str(iter_dir / "train.jsonl"),
            "--valid", str(iter_dir / "valid.jsonl"),
            "--test", str(iter_dir / "test.jsonl"),
            "--output", str(artifacts),
            "--epochs", "24",
            "--learning-rate", "0.05",
            "--max-depth", "3",
            "--seed", str(args.seed + iteration),
        ])

        compile_model(artifacts / "CandidateRanker.mlmodel")
        run([str(BUILD_SH)])

        ab_default = iter_dir / "ranker_ab_default.json"
        ab_dynamic = iter_dir / "ranker_ab_dynamic.json"
        run([str(APP), "ab-ranker-check", str(ab_default), "default", "20"])
        run([str(APP), "ab-ranker-check", str(ab_dynamic), "dynamic", "120"])
        hardneg = extract_hard_negatives(ab_dynamic, iter_dir / "hard_negatives.json")
        hardneg_sentences = [item["sentence"] for item in hardneg]

        selftest_default = capture([str(APP), "selftest"])
        selftest_regression = capture([str(APP), "selftest", str(REGRESSION_FILE)])
        failures = parse_selftest_failures(selftest_default) + parse_selftest_failures(selftest_regression)
        update_regression_file(failures, hardneg_sentences)

        metrics = json.loads((artifacts / "metrics.json").read_text(encoding="utf-8"))
        loop_summary.append({
            "iteration": iteration,
            "dataset": split_stats,
            "metrics": {
                "valid_top1": metrics["valid"]["top1"],
                "valid_mrr": metrics["valid"]["mrr"],
                "test_top1": metrics["test"]["top1"] if metrics.get("test") else None,
                "test_mrr": metrics["test"]["mrr"] if metrics.get("test") else None,
                "best_epoch": metrics.get("best_epoch"),
            },
            "selftest_failures": failures,
            "hard_negative_count": len(hardneg),
        })

    summary_path = ROOT / "fastChIME" / "artifacts" / "x10_loop_summary.json"
    summary_path.write_text(json.dumps(loop_summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved_summary={summary_path}")


if __name__ == "__main__":
    main()
