#!/usr/bin/env python3
import argparse
import json
import re
from pathlib import Path


STRIP_CHARS = "。！？；?!;…．，,、：:\"'“”‘’()（）【】《》〈〉﹐"


def load_sentence_groups(path: Path):
    rows = []
    if not path.exists():
        return rows
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def load_text_sentences(path: Path):
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def normalize_sentence(text: str) -> str:
    text = text.strip()
    text = text.strip(STRIP_CHARS + " ")
    text = re.sub(r"\s+", "", text)
    replacements = {
        "隻": "只",
        "瞭": "了",
        "纔": "才",
        "麥剋風": "麥克風",
        "傢": "家",
        "裏": "裡",
        "錶": "表",
        "妳": "你",
    }
    for source, target in replacements.items():
        text = text.replace(source, target)
    return text


def main() -> int:
    parser = argparse.ArgumentParser(description="Extract sentence mother samples from grouped datasets or plain-text corpora.")
    parser.add_argument("--inputs", nargs="+", required=True, help="Sentence group JSONL files or plain-text sentence files")
    parser.add_argument("--output", required=True, help="Output plain-text sentence list")
    parser.add_argument("--summary", required=True, help="Output summary JSON")
    parser.add_argument("--min-chars", type=int, default=6)
    parser.add_argument("--max-chars", type=int, default=30)
    parser.add_argument("--normalize", action="store_true")
    args = parser.parse_args()

    sentences = []
    seen = set()
    source_counts = {}

    for raw_path in args.inputs:
        path = Path(raw_path)
        kept = 0
        rows = []
        if path.suffix == ".jsonl":
            rows = load_sentence_groups(path)
            source_sentences = [(row.get("gold_text") or "").strip() for row in rows]
            source_counts[str(path)] = {
                "rows": len(rows),
                "source_type": "jsonl_groups",
                "kept_sentences": 0,
            }
        else:
            source_sentences = load_text_sentences(path)
            source_counts[str(path)] = {
                "rows": len(source_sentences),
                "source_type": "text_sentences",
                "kept_sentences": 0,
            }

        for sentence in source_sentences:
            if args.normalize:
                sentence = normalize_sentence(sentence)
            if not sentence:
                continue
            if not (args.min_chars <= len(sentence) <= args.max_chars):
                continue
            if sentence in seen:
                continue
            seen.add(sentence)
            sentences.append(sentence)
            kept += 1
        source_counts[str(path)]["kept_sentences"] = kept

    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(sentences) + ("\n" if sentences else ""), encoding="utf-8")

    summary = {
        "input_count": len(args.inputs),
        "sentence_count": len(sentences),
        "min_chars": args.min_chars,
        "max_chars": args.max_chars,
        "sources": source_counts,
        "output": str(output_path),
    }
    Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
