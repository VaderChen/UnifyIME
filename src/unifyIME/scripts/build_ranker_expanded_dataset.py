#!/usr/bin/env python3
import argparse
import json
import os
import random
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
IME_DATA_ROOT = Path(
    os.environ.get("UNIFYIME_IME_DATA_ROOT")
    or os.environ.get("FASTCHIME_IME_DATA_ROOT")
    or (ROOT / "artifacts" / "datasets" / "IME").as_posix()
)
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
FETCH_PY = ROOT / "src" / "unifyIME" / "scripts" / "fetch_traditional_corpus.py"
BUILD_MOTHER_PY = ROOT / "src" / "unifyIME" / "scripts" / "build_expanded_mother_corpus.py"
REGRESSION_FILE = ROOT / "data" / "regression_sentences.txt"
USER_SELECTION_LOG = Path.home() / "Library/Application Support/UnifyIME/user_selection_log.jsonl"
REGRESSION_BACKLOG = Path.home() / "Library/Application Support/UnifyIME/regression_backlog.jsonl"
PHRASE_MAP = ROOT / "src" / "unifyIME" / "Resources" / "phrase_map.tsv"
COMMON_MAP = ROOT / "src" / "unifyIME" / "Resources" / "common_map.tsv"
def run(cmd):
    print("+", " ".join(str(part) for part in cmd), flush=True)
    subprocess.run(cmd, cwd=ROOT, check=True)


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
            if not path.exists():
                continue
            with path.open("r", encoding="utf-8") as src:
                shutil.copyfileobj(src, dst)


def split_dataset(src_path: Path, out_dir: Path, seed: int):
    rows = [json.loads(line) for line in src_path.read_text(encoding="utf-8").splitlines() if line.strip()]
    groups = {}
    for row in rows:
        groups.setdefault((row["case_id"], row["step_id"]), []).append(row)
    grouped_rows = list(groups.values())
    random.Random(seed).shuffle(grouped_rows)
    total_groups = len(grouped_rows)
    train_end = int(total_groups * 0.8)
    valid_end = int(total_groups * 0.9)
    train_rows = [row for group in grouped_rows[:train_end] for row in group]
    valid_rows = [row for group in grouped_rows[train_end:valid_end] for row in group]
    test_rows = [row for group in grouped_rows[valid_end:] for row in group]
    out_dir.mkdir(parents=True, exist_ok=True)
    parts = {
        "train.jsonl": train_rows,
        "valid.jsonl": valid_rows,
        "test.jsonl": test_rows,
    }
    for name, subset in parts.items():
        path = out_dir / name
        with path.open("w", encoding="utf-8") as f:
            for row in subset:
                f.write(json.dumps(row, ensure_ascii=False) + "\n")
    return {
        "total_rows": len(rows),
        "total_groups": total_groups,
        "train": len(parts["train.jsonl"]),
        "valid": len(parts["valid.jsonl"]),
        "test": len(parts["test.jsonl"]),
    }


def convert_selection_log(src_path: Path, dest_path: Path, source_name: str, sample_boost: float):
    if not src_path.exists():
        dest_path.write_text("", encoding="utf-8")
        return 0

    rows_written = 0
    with src_path.open("r", encoding="utf-8") as src, dest_path.open("w", encoding="utf-8") as dst:
        for index, line in enumerate(src, start=1):
            line = line.strip()
            if not line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue

            candidates = [candidate for candidate in record.get("candidates", []) if candidate]
            reading = record.get("reading", "")
            chosen_surface = record.get("surface", "")
            all_readings = record.get("all_readings", [])
            preceding_values = record.get("preceding_values", [])
            span_start = int(record.get("span_start", 0))
            span_length = int(record.get("span_length", max(len(all_readings), 1)))
            following_tokens = all_readings[span_start + span_length:] if all_readings else []
            top1_changed = bool(record.get("top1_changed", False))
            chosen_index = int(record.get("chosen_index", 0))

            if not candidates or not reading or not chosen_surface:
                continue

            positive_weight = sample_boost * (2.4 if top1_changed else 1.8)
            negative_weight = sample_boost * (1.2 if top1_changed else 1.0)
            case_id = f"{source_name}:case-{index}"

            for candidate_index, candidate in enumerate(candidates, start=1):
                label = int(candidate == chosen_surface and candidate_index - 1 == chosen_index)
                if chosen_surface in candidates and label == 0 and candidate == chosen_surface and candidate_index - 1 != chosen_index:
                    label = 0
                row = {
                    "sample_id": f"{case_id}-cand-{candidate_index}",
                    "case_id": case_id,
                    "step_id": 1,
                    "label": label,
                    "language_id": "zh-Hant",
                    "source": source_name,
                    "tags": ["user_log" if source_name == "user_selection_log" else "regression_backlog"],
                    "all_tokens": all_readings,
                    "combined_token": reading,
                    "focused_token": reading,
                    "candidate_surface": candidate,
                    "candidate_reading_or_token": reading,
                    "preceding_values": preceding_values,
                    "following_tokens": following_tokens,
                    "span_start": span_start,
                    "span_length": span_length,
                    "base_rank": candidate_index - 1,
                    "provider_score": -(candidate_index - 1),
                    "sample_weight": positive_weight if label > 0 else negative_weight,
                }
                dst.write(json.dumps(row, ensure_ascii=False) + "\n")
                rows_written += 1
    return rows_written


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--ime-data-root", default=str(IME_DATA_ROOT))
    parser.add_argument("--output-dir", required=True)
    parser.add_argument("--target-sentences", type=int, default=24000)
    parser.add_argument("--wiki-target-sentences", type=int, default=5000)
    parser.add_argument("--tatoeba-target-sentences", type=int, default=19000)
    parser.add_argument("--dynamic-batch", type=int, default=9000)
    parser.add_argument("--word-batch", type=int, default=1800)
    parser.add_argument("--sentence-batch", type=int, default=2400)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--user-log-boost", type=float, default=2.0)
    parser.add_argument("--backlog-boost", type=float, default=2.8)
    parser.add_argument("--base-mother")
    args = parser.parse_args()

    ime_data_root = Path(args.ime_data_root).expanduser()
    out_dir = Path(args.output_dir)
    raw_dir = out_dir / "raw"
    raw_dir.mkdir(parents=True, exist_ok=True)
    expanded_mother_txt = out_dir / "mother_expanded_sentences.txt"
    expanded_mother_summary = out_dir / "mother_expanded_summary.json"

    corpus_txt = ROOT / "data" / "web_corpus" / "wiki_zh_hant_sentences.txt"
    corpus_meta = ROOT / "data" / "web_corpus" / "wiki_zh_hant_meta.json"
    existing_sentences = 0
    if corpus_txt.exists():
        existing_sentences = sum(1 for line in corpus_txt.read_text(encoding="utf-8").splitlines() if line.strip())
    if existing_sentences < args.target_sentences:
        run([
            "python3", str(FETCH_PY),
            "--output", str(corpus_txt),
            "--meta-output", str(corpus_meta),
            "--target-sentences", str(args.target_sentences),
            "--wiki-target-sentences", str(args.wiki_target_sentences),
            "--tatoeba-target-sentences", str(args.tatoeba_target_sentences),
        ])

    run([
        "python3", str(BUILD_MOTHER_PY),
        "--ime-data-root", str(ime_data_root),
        "--phrase-map", str(PHRASE_MAP),
        "--common-map", str(COMMON_MAP),
        "--x20-dataset", str(out_dir / "all.jsonl" if (out_dir / "all.jsonl").exists() else ime_data_root / "x20" / "all.jsonl"),
        "--base-mother", str(Path(args.base_mother).expanduser() if args.base_mother else ime_data_root / "sentence_mother_samples_web_corpus" / "sentences_normalized.txt"),
        "--output", str(expanded_mother_txt),
        "--summary", str(expanded_mother_summary),
    ])

    dataset_jobs = [
        ("default", ["dump-ranker-data", str(raw_dir / "default.jsonl"), "default", "200"]),
        ("short_words", ["dump-ranker-data", str(raw_dir / "short_words.jsonl"), "short-words", str(args.word_batch)]),
        ("short_sentences", ["dump-ranker-data", str(raw_dir / "short_sentences.jsonl"), "short-sentences", str(args.sentence_batch)]),
        ("dynamic", ["dump-ranker-data", str(raw_dir / "dynamic.jsonl"), "dynamic", str(args.dynamic_batch)]),
        ("web_corpus", ["dump-ranker-data", str(raw_dir / "web_corpus.jsonl"), str(corpus_txt), "0"]),
        ("mother_expanded", ["dump-ranker-data", str(raw_dir / "mother_expanded.jsonl"), str(expanded_mother_txt), "0"]),
        ("regression", ["dump-ranker-data", str(raw_dir / "regression.jsonl"), str(REGRESSION_FILE), "0"]),
    ]

    prefixed_paths = []
    for name, cli in dataset_jobs:
        run([str(APP)] + cli)
        prefixed = raw_dir / f"{name}.prefixed.jsonl"
        prefix_ids(raw_dir / f"{name}.jsonl", prefixed, name)
        prefixed_paths.append(prefixed)

    user_log_rows = convert_selection_log(
        USER_SELECTION_LOG,
        raw_dir / "user_selection_log.jsonl",
        "user_selection_log",
        args.user_log_boost,
    )
    backlog_rows = convert_selection_log(
        REGRESSION_BACKLOG,
        raw_dir / "regression_backlog.jsonl",
        "regression_backlog",
        args.backlog_boost,
    )
    prefixed_paths.extend([
        raw_dir / "user_selection_log.jsonl",
        raw_dir / "regression_backlog.jsonl",
    ])

    merged = out_dir / "all.jsonl"
    combine_jsonl(prefixed_paths, merged)
    stats = split_dataset(merged, out_dir, args.seed)
    summary = {
        "output_dir": str(out_dir),
        "web_corpus_sentences": sum(1 for line in corpus_txt.read_text(encoding="utf-8").splitlines() if line.strip()),
        "expanded_mother_sentences": sum(1 for line in expanded_mother_txt.read_text(encoding="utf-8").splitlines() if line.strip()),
        "user_log_rows": user_log_rows,
        "backlog_rows": backlog_rows,
        "dataset": stats,
        "sources": [path.name for path in prefixed_paths if path.exists()],
    }
    (out_dir / "dataset_summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
