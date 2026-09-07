#!/usr/bin/env python3
"""Convert open mixed-language article sentences into listwise groups."""

from __future__ import annotations

import argparse
import functools
import hashlib
import json
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_COMMON_MAP = ROOT / "src/unifyIME/Resources/common_map.tsv"
DEFAULT_PHRASE_MAP = ROOT / "src/unifyIME/Resources/phrase_map.tsv"
HAN = re.compile(r"^[\u3400-\u4dbf\u4e00-\u9fff]+$")
RUN = re.compile(
    r"[\u3400-\u4dbf\u4e00-\u9fff]+|"
    r"[A-Za-z][A-Za-z0-9+#._/-]*(?:\s+[A-Za-z][A-Za-z0-9+#._/-]*)*"
)
DISPLAYABLE = re.compile(
    r"^[\u3400-\u4dbf\u4e00-\u9fff，。、！？：；（）「」『』《》〈〉—…．·]+$"
)


@dataclass(frozen=True)
class Segment:
    text: str
    reading: str
    language_id: str
    tokens: tuple[str, ...]


class Lexicon:
    def __init__(self, common_map: Path, phrase_map: Path) -> None:
        common: dict[str, list[str]] = defaultdict(list)
        weighted: dict[str, list[tuple[str, float]]] = defaultdict(list)
        self.surface_readings: dict[str, list[str]] = defaultdict(list)

        with common_map.open(encoding="utf-8") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t", 1)
                if len(parts) != 2:
                    continue
                reading, surface = parts
                if reading and surface and surface not in common[reading]:
                    common[reading].append(surface)
                if reading and surface and reading not in self.surface_readings[surface]:
                    self.surface_readings[surface].append(reading)

        with phrase_map.open(encoding="utf-8") as handle:
            for line in handle:
                parts = line.rstrip("\n").split("\t")
                if len(parts) < 2:
                    continue
                reading, surface = parts[:2]
                try:
                    weight = float(parts[2]) if len(parts) >= 3 else 0.0
                except ValueError:
                    weight = 0.0
                if reading and surface and not any(value == surface for value, _ in weighted[reading]):
                    weighted[reading].append((surface, weight))
                if reading and surface and reading not in self.surface_readings[surface]:
                    self.surface_readings[surface].append(reading)

        phrases = {
            reading: [surface for surface, _ in sorted(entries, key=lambda item: -item[1])]
            for reading, entries in weighted.items()
        }
        self.reading_candidates: dict[str, list[str]] = {}
        for reading in set(common) | set(phrases):
            sources = (
                (phrases.get(reading, []), common.get(reading, []))
                if len(reading) > 1
                else (common.get(reading, []), phrases.get(reading, []))
            )
            merged: list[str] = []
            for source in sources:
                for surface in source:
                    if surface not in merged:
                        merged.append(surface)
            self.reading_candidates[reading] = merged
        self.single_syllables = {
            reading
            for surface, readings in self.surface_readings.items()
            if len(surface) == 1 and HAN.fullmatch(surface)
            for reading in readings
        }
        self.max_surface_length = min(12, max(map(len, self.surface_readings), default=1))

    def candidate_rank(self, reading: str, surface: str) -> int:
        try:
            return self.reading_candidates.get(reading, []).index(surface)
        except ValueError:
            return 10_000

    def reverse_han(self, text: str) -> list[tuple[str, str]] | None:
        count = len(text)
        best: list[tuple[int, int, list[tuple[str, str]]] | None] = [None] * (count + 1)
        best[count] = (0, 0, [])
        for start in range(count - 1, -1, -1):
            choice = None
            for end in range(min(count, start + self.max_surface_length), start, -1):
                surface = text[start:end]
                tail = best[end]
                if tail is None:
                    continue
                readings = sorted(
                    self.surface_readings.get(surface, []),
                    key=lambda reading: self.candidate_rank(reading, surface),
                )[:4]
                for reading in readings:
                    candidate = (
                        1 + tail[0],
                        self.candidate_rank(reading, surface) + tail[1],
                        [(surface, reading)] + tail[2],
                    )
                    if choice is None or candidate[:2] < choice[:2]:
                        choice = candidate
            best[start] = choice
        return best[0][2] if best[0] is not None else None

    def split_reading(self, reading: str, expected_count: int) -> tuple[str, ...]:
        @functools.lru_cache(maxsize=None)
        def resolve(position: int, remaining: int) -> tuple[str, ...] | None:
            if position == len(reading):
                return () if remaining == 0 else None
            if remaining <= 0:
                return None
            for end in range(len(reading), position, -1):
                syllable = reading[position:end]
                if syllable not in self.single_syllables:
                    continue
                tail = resolve(end, remaining - 1)
                if tail is not None:
                    return (syllable,) + tail
            return None

        return resolve(0, expected_count) or (reading,)


def stable_fraction(text: str, seed: int) -> float:
    digest = hashlib.sha256(f"{seed}:{text}".encode()).digest()
    return int.from_bytes(digest[:8], "big") / float(2**64)


def parse_segments(text: str, lexicon: Lexicon) -> list[Segment] | None:
    segments: list[Segment] = []
    has_han = has_english = False
    for match in RUN.finditer(text):
        value = match.group(0).strip()
        if HAN.fullmatch(value):
            reversed_segments = lexicon.reverse_han(value)
            if reversed_segments is None:
                return None
            for surface, reading in reversed_segments:
                segments.append(
                    Segment(
                        surface,
                        reading,
                        "zh-Hant",
                        lexicon.split_reading(reading, len(surface)),
                    )
                )
                has_han = True
        elif value:
            normalized = re.sub(r"\s+", " ", value)
            segments.append(Segment(normalized, normalized, "english-ime", (normalized,)))
            has_english = True
    return segments if has_han and has_english else None


def build_groups(
    record: dict[str, Any],
    lexicon: Lexicon,
    top_k: int,
    max_groups_per_sentence: int,
) -> list[list[dict[str, Any]]]:
    text = str(record.get("text", ""))
    segments = parse_segments(text, lexicon)
    if not segments:
        return []
    all_tokens = [token for segment in segments for token in segment.tokens]
    token_languages = [segment.language_id for segment in segments for _ in segment.tokens]
    token_starts: list[int] = []
    cursor = 0
    for segment in segments:
        token_starts.append(cursor)
        cursor += len(segment.tokens)

    fallback_id = hashlib.sha256(text.encode()).hexdigest()[:24]
    case_id = "article:" + str(record.get("sentence_id", fallback_id))
    groups: list[list[dict[str, Any]]] = []
    for segment_index, segment in enumerate(segments):
        if segment.language_id != "zh-Hant":
            continue
        candidates = [
            candidate
            for candidate in lexicon.reading_candidates.get(segment.reading, [])
            if DISPLAYABLE.fullmatch(candidate)
        ]
        if segment.text not in candidates:
            continue
        positive_rank = candidates.index(segment.text)
        candidates = candidates[:top_k]
        if positive_rank >= len(candidates) or len(candidates) < 2:
            continue
        token_start = token_starts[segment_index]
        span_length = len(segment.tokens)
        step_id = segment_index + 1
        tags = [
            "open_licensed_article",
            "weak_article_label",
            "mixed_context",
            str(record.get("source", "open_article")),
        ]
        rows: list[dict[str, Any]] = []
        for candidate_index, candidate in enumerate(candidates):
            rows.append(
                {
                    "sample_id": f"{case_id}:seg-{step_id}:cand-{candidate_index + 1}",
                    "case_id": case_id,
                    "step_id": step_id,
                    "label": int(candidate_index == positive_rank),
                    "language_id": "zh-Hant",
                    "source": str(record.get("source", "open_article")),
                    "tags": tags,
                    "all_tokens": all_tokens,
                    "token_languages": token_languages,
                    "combined_token": segment.reading,
                    "focused_token": segment.reading,
                    "candidate_surface": candidate,
                    "candidate_reading_or_token": segment.reading,
                    "preceding_values": [item.text for item in segments[:segment_index]][-3:],
                    "following_tokens": all_tokens[token_start + span_length :],
                    "following_values": [item.text for item in segments[segment_index + 1 :]][:3],
                    "span_start": token_start,
                    "span_length": span_length,
                    "base_rank": candidate_index,
                    "provider_score": -candidate_index,
                    "sample_weight": 1.0,
                    "mixed_context": True,
                    "article_sentence": text,
                    "article_title": str(record.get("title", "")),
                    "article_url": str(record.get("url", "")),
                    "article_license": str(record.get("license", "")),
                }
            )
        groups.append(rows)
        if max_groups_per_sentence > 0 and len(groups) >= max_groups_per_sentence:
            break
    return groups


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--common-map", default=str(DEFAULT_COMMON_MAP))
    parser.add_argument("--phrase-map", default=str(DEFAULT_PHRASE_MAP))
    parser.add_argument("--top-k", type=int, default=20)
    parser.add_argument("--max-groups-per-sentence", type=int, default=8)
    parser.add_argument("--max-easy-groups", type=int, default=5000)
    parser.add_argument("--seed", type=int, default=311)
    args = parser.parse_args()

    records = [
        json.loads(line)
        for line in Path(args.input).expanduser().read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]
    lexicon = Lexicon(Path(args.common_map), Path(args.phrase_map))
    groups: list[list[dict[str, Any]]] = []
    stats: Counter[str] = Counter()
    by_source: Counter[str] = Counter()
    for record in records:
        built = build_groups(record, lexicon, max(2, args.top_k), args.max_groups_per_sentence)
        stats["resolved_sentences"] += int(bool(built))
        stats["unresolved_sentences"] += int(not built)
        for group in built:
            groups.append(group)
            stats["raw_groups"] += 1
            positive = next(row for row in group if row["label"] > 0)
            stats["raw_hard_groups"] += int(positive["base_rank"] > 0)
            by_source[str(group[0]["source"])] += 1

    hard = [group for group in groups if next(row for row in group if row["label"])["base_rank"] > 0]
    easy = [group for group in groups if group not in hard]
    hard.sort(key=lambda group: stable_fraction(group[0]["sample_id"], args.seed))
    easy.sort(key=lambda group: stable_fraction(group[0]["sample_id"], args.seed))
    selected_easy = easy[: args.max_easy_groups] if args.max_easy_groups > 0 else easy
    selected = hard + selected_easy
    selected.sort(key=lambda group: stable_fraction(group[0]["sample_id"], args.seed + 1))

    output = Path(args.output).expanduser()
    summary_path = Path(args.summary).expanduser()
    output.parent.mkdir(parents=True, exist_ok=True)
    summary_path.parent.mkdir(parents=True, exist_ok=True)
    row_count = 0
    with output.open("w", encoding="utf-8") as handle:
        for group in selected:
            for row in group:
                handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
                row_count += 1

    summary = {
        "schema": "mixed_article_candidate_dataset_v1",
        "input": str(Path(args.input).expanduser()),
        "output": str(output),
        "input_sentences": len(records),
        "resolved_sentences": stats["resolved_sentences"],
        "unresolved_sentences": stats["unresolved_sentences"],
        "raw_groups": stats["raw_groups"],
        "raw_hard_groups": stats["raw_hard_groups"],
        "selected_groups": len(selected),
        "selected_hard_groups": len(hard),
        "selected_easy_groups": len(selected_easy),
        "rows": row_count,
        "groups_by_source": dict(by_source),
        "top_k": args.top_k,
        "max_groups_per_sentence": args.max_groups_per_sentence,
        "seed": args.seed,
    }
    summary_path.write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
