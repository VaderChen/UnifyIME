#!/usr/bin/env python3
import argparse
import json
from pathlib import Path


def load_rows(path: Path):
    rows = []
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def char_segments(text: str):
    segments = []
    for index, char in enumerate(text):
        segments.append(
            {
                "languageID": "zh-Hant",
                "reading": "",
                "value": char,
                "start": index,
                "length": 1,
            }
        )
    return segments


def build_candidate(text: str, readings, local_score: float, metadata: dict):
    return {
        "text": text,
        "readings": readings,
        "segments": char_segments(text),
        "localScore": local_score,
        "metadata": metadata,
    }


def build_group(row, index: int):
    sentence = row.get("sentence", "").strip()
    if not sentence:
        return None

    readings = row.get("probe_readings") or []
    negatives = []
    seen = set()
    for negative in row.get("negatives") or []:
        text = (negative.get("text") or "").strip()
        mode = negative.get("mode") or "unknown"
        if not text or text == sentence or text in seen:
            continue
        seen.add(text)
        negatives.append((mode, text))

    if not negatives:
        return None

    candidates = [
        build_candidate(
            text=sentence,
            readings=readings,
            local_score=0.0,
            metadata={
                "is_gold": 1.0,
                "source_true_negative": 1.0,
                "source_mode_rank": 0.0,
            },
        )
    ]

    for rank, (mode, text) in enumerate(negatives, start=1):
        mode_rank = {
            "traditional": 1.0,
            "hybrid": 2.0,
            "nn_only": 3.0,
        }.get(mode, 9.0)
        candidates.append(
            build_candidate(
                text=text,
                readings=readings,
                local_score=1000.0 - float(rank),
                metadata={
                    "is_gold": 0.0,
                    "source_true_negative": 1.0,
                    "source_mode_rank": mode_rank,
                },
            )
        )

    return {
        "group_id": f"true_negative_{index:04d}",
        "readings": readings,
        "gold_text": sentence,
        "candidates": candidates,
        "context": {
            "committedLeftContext": [],
            "committedRightContext": [],
        },
        "segment_samples": [],
        "source_metadata": {
            "origin": "true_negative_probe",
            "key_sequence": row.get("key_sequence", ""),
            "path_count": len(row.get("paths") or {}),
            "negative_count": len(negatives),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Build grouped sentence reranker dataset from true system negatives.")
    parser.add_argument("--input", required=True, help="Input JSONL from build_sentence_three_path_negatives.py")
    parser.add_argument("--output", required=True, help="Output grouped JSONL")
    parser.add_argument("--summary", required=True, help="Output summary JSON")
    args = parser.parse_args()

    rows = load_rows(Path(args.input))
    groups = []
    for index, row in enumerate(rows, start=1):
        group = build_group(row, index)
        if group is not None:
            groups.append(group)

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("w", encoding="utf-8") as fh:
        for group in groups:
            fh.write(json.dumps(group, ensure_ascii=False) + "\n")

    summary = {
        "input": args.input,
        "group_count": len(groups),
        "candidate_count": sum(len(group["candidates"]) for group in groups),
        "avg_candidates": (
            sum(len(group["candidates"]) for group in groups) / len(groups)
            if groups else 0.0
        ),
        "output": str(output_path),
    }
    Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
