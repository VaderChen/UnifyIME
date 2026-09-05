#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
IME_DATA_ROOT = Path(
    os.environ.get("UNIFYIME_IME_DATA_ROOT")
    or os.environ.get("FASTCHIME_IME_DATA_ROOT")
    or (ROOT / "artifacts" / "datasets" / "IME").as_posix()
)
DEFAULT_PHRASE_MAP = ROOT / "src" / "unifyIME" / "Resources" / "phrase_map.tsv"
DEFAULT_COMMON_MAP = ROOT / "src" / "unifyIME" / "Resources" / "common_map.tsv"


def load_text_lines(path: Path):
    if not path.exists():
        return []
    return [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def load_positive_surfaces(path: Path):
    surfaces = set()
    if not path.exists():
        return surfaces
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            row = json.loads(line)
            if int(row.get("label", 0)) > 0:
                surface = (row.get("candidate_surface") or "").strip()
                if surface:
                    surfaces.add(surface)
    return surfaces


def load_lexicon_surfaces(path: Path, surface_column: int):
    surfaces = set()
    if not path.exists():
        return surfaces
    with path.open("r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) <= surface_column:
                continue
            surface = parts[surface_column].strip()
            if surface:
                surfaces.add(surface)
    return surfaces


def has_cjk(text: str) -> bool:
    return any("\u3400" <= ch <= "\u9fff" for ch in text)


def build_sentence(term: str, min_chars: int, max_chars: int):
    term = term.strip()
    if not term or not has_cjk(term):
        return None
    if len(term) > max_chars:
        return None
    if min_chars <= len(term) <= max_chars:
        return term
    templates = [
        f"我想輸入{term}字",
        f"我在測試{term}功能",
        f"現在開始測試{term}",
        f"這裡會用到{term}",
    ]
    for sentence in templates:
        if min_chars <= len(sentence) <= max_chars:
            return sentence
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description="Expand local mother sentences from current lexicon terms that are uncovered by x20.")
    parser.add_argument("--ime-data-root", default=str(IME_DATA_ROOT))
    parser.add_argument("--phrase-map", default=str(DEFAULT_PHRASE_MAP))
    parser.add_argument("--common-map", default=str(DEFAULT_COMMON_MAP))
    parser.add_argument("--x20-dataset")
    parser.add_argument("--base-mother")
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--min-chars", type=int, default=6)
    parser.add_argument("--max-chars", type=int, default=30)
    args = parser.parse_args()

    ime_data_root = Path(args.ime_data_root).expanduser()
    phrase_map = Path(args.phrase_map)
    common_map = Path(args.common_map)
    x20_dataset = Path(args.x20_dataset).expanduser() if args.x20_dataset else ime_data_root / "x20" / "all.jsonl"
    base_mother = Path(args.base_mother).expanduser() if args.base_mother else ime_data_root / "sentence_mother_samples_web_corpus" / "sentences_normalized.txt"
    output_path = Path(args.output)
    summary_path = Path(args.summary)

    existing_positive_surfaces = load_positive_surfaces(x20_dataset)
    phrase_surfaces = load_lexicon_surfaces(phrase_map, 1)
    common_surfaces = load_lexicon_surfaces(common_map, 1)
    all_surfaces = phrase_surfaces | common_surfaces
    missing_surfaces = sorted(surface for surface in all_surfaces if surface not in existing_positive_surfaces)

    sentences = []
    seen = set()

    base_sentences = load_text_lines(base_mother)
    for sentence in base_sentences:
        if sentence in seen:
            continue
        seen.add(sentence)
        sentences.append(sentence)

    generated = 0
    skipped = 0
    for term in missing_surfaces:
        sentence = build_sentence(term, args.min_chars, args.max_chars)
        if not sentence:
            skipped += 1
            continue
        if sentence in seen:
            continue
        seen.add(sentence)
        sentences.append(sentence)
        generated += 1

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n".join(sentences) + ("\n" if sentences else ""), encoding="utf-8")

    summary = {
        "base_mother": str(base_mother),
        "x20_dataset": str(x20_dataset),
        "phrase_map": str(phrase_map),
        "common_map": str(common_map),
        "base_sentence_count": len(base_sentences),
        "x20_positive_surface_count": len(existing_positive_surfaces),
        "phrase_surface_count": len(phrase_surfaces),
        "common_surface_count": len(common_surfaces),
        "lexicon_surface_count": len(all_surfaces),
        "missing_surface_count": len(missing_surfaces),
        "generated_sentence_count": generated,
        "skipped_surface_count": skipped,
        "output_sentence_count": len(sentences),
        "output": str(output_path),
    }
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
