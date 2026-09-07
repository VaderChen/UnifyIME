#!/usr/bin/env python3
"""Build repeated sentence-safe listwise splits with real selection records.

The builder merges natural candidate groups with the local runtime selection
log.  Every candidate group from the same tokenized sentence family is kept in
one split, even when the same context appears in more than one source.  The
regression backlog may be supplied together with the main selection log; event
deduplication prevents its hard-case copies from being counted twice.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_CANDIDATE_SOURCES = [
    ROOT / "artifacts/datasets/natural_web_v1/raw.jsonl",
]
DEFAULT_SELECTION_LOGS = [
    Path.home() / "Library/Application Support/UnifyIME/user_selection_log.jsonl",
    Path.home() / "Library/Application Support/UnifyIME/regression_backlog.jsonl",
]
SPLIT_NAMES = ("train", "valid", "test")
LATIN_PATTERN = re.compile(r"[A-Za-z]")


def stable_digest(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def stable_fraction(text: str, seed: int) -> float:
    digest = hashlib.sha256(f"{seed}:{text}".encode("utf-8")).digest()
    return int.from_bytes(digest[:8], "big") / float(2**64)


def source_label(path: Path, index: int) -> str:
    parent = path.parent.name.strip() or "source"
    stem = path.stem.strip() or str(index + 1)
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", f"{parent}_{stem}")


def valid_group(rows: list[dict[str, Any]]) -> bool:
    positives = [row for row in rows if float(row.get("label", 0)) > 0]
    return len(rows) > 1 and len(positives) == 1


def is_hard_group(rows: list[dict[str, Any]]) -> bool:
    positive = next((row for row in rows if float(row.get("label", 0)) > 0), None)
    return positive is not None and int(positive.get("base_rank", 0)) > 0


def contains_latin(values: Iterable[Any]) -> bool:
    return any(LATIN_PATTERN.search(str(value)) for value in values)


def is_mixed_group(rows: list[dict[str, Any]]) -> bool:
    row = next((item for item in rows if float(item.get("label", 0)) > 0), rows[0])
    values: list[Any] = []
    for key in (
        "all_tokens",
        "preceding_values",
        "following_tokens",
        "following_values",
    ):
        raw = row.get(key, [])
        values.extend(raw if isinstance(raw, list) else [raw])
    values.extend(item.get("candidate_surface", "") for item in rows)
    return bool(row.get("mixed_context")) or contains_latin(values)


def is_selection_group(rows: list[dict[str, Any]]) -> bool:
    return any("real_user_selection" in row.get("tags", []) for row in rows)


def normalize_tokens(record: dict[str, Any]) -> list[str]:
    raw_tokens = record.get("all_readings", record.get("all_tokens", []))
    if not isinstance(raw_tokens, list):
        return []
    result: list[str] = []
    for token in raw_tokens:
        if isinstance(token, dict):
            value = token.get("raw_value", token.get("reading", token.get("token", "")))
        else:
            value = token
        result.append(str(value))
    return result


def normalized_string_list(value: Any) -> list[str]:
    if not isinstance(value, list):
        return []
    return [str(item) for item in value]


def event_fingerprint(record: dict[str, Any]) -> str:
    event_id = str(record.get("event_id", "")).strip()
    if event_id:
        return f"event:{event_id}"
    return "legacy:" + stable_digest(
        {
            "timestamp": record.get("timestamp"),
            "reading": record.get("reading"),
            "surface": record.get("surface"),
            "chosen_index": record.get("chosen_index"),
            "candidates": record.get("candidates"),
            "all_readings": record.get("all_readings"),
            "preceding_values": record.get("preceding_values"),
        }
    )


def selection_sentence_family(record: dict[str, Any], tokens: list[str]) -> str:
    token_languages = normalized_string_list(record.get("token_languages", []))
    payload: dict[str, Any] = {
        "tokens": tokens,
        "token_languages": token_languages,
    }
    # A one-token context is common enough that grouping every occurrence of a
    # syllable together would collapse unrelated sentences.  Add the compact
    # composition context in that special case while retaining sentence-wide
    # grouping for multi-token selections.
    if len(tokens) <= 1:
        payload.update(
            {
                "composition_text": str(record.get("composition_text", "")),
                "preceding_values": normalized_string_list(record.get("preceding_values", [])),
                "following_values": normalized_string_list(record.get("following_values", [])),
            }
        )
    if not tokens:
        payload["fallback"] = {
            "reading": record.get("reading"),
            "surface": record.get("surface"),
        }
    return "sentence:" + stable_digest(payload)[:24]


def infer_language_id(record: dict[str, Any], reading: str, surface: str) -> str:
    explicit = str(record.get("language_id", "")).strip()
    if explicit:
        return explicit
    if contains_latin([reading, surface]):
        return "english-ime"
    return "zh-Hant"


def resolve_chosen_index(record: dict[str, Any], candidates: list[str]) -> int | None:
    surface = str(record.get("surface", ""))
    try:
        chosen_index = int(record.get("chosen_index", -1))
    except (TypeError, ValueError):
        chosen_index = -1
    if 0 <= chosen_index < len(candidates) and candidates[chosen_index] == surface:
        return chosen_index
    matches = [index for index, candidate in enumerate(candidates) if candidate == surface]
    return matches[0] if len(matches) == 1 else None


def convert_selection_record(
    record: dict[str, Any],
    source_name: str,
    event_key: str,
) -> tuple[str, list[dict[str, Any]]] | None:
    raw_candidates = record.get("candidates", [])
    if not isinstance(raw_candidates, list):
        return None
    candidates = [str(candidate) for candidate in raw_candidates]
    chosen_index = resolve_chosen_index(record, candidates)
    nonempty_indices = [index for index, candidate in enumerate(candidates) if candidate]
    if chosen_index is None or chosen_index not in nonempty_indices or len(nonempty_indices) < 2:
        return None

    reading = str(record.get("reading", "")).strip()
    chosen_surface = str(record.get("surface", "")).strip()
    if not reading or not chosen_surface:
        return None

    tokens = normalize_tokens(record)
    preceding_values = normalized_string_list(record.get("preceding_values", []))
    token_languages = normalized_string_list(record.get("token_languages", []))
    try:
        span_start = max(0, int(record.get("span_start", 0)))
        span_length = max(1, int(record.get("span_length", 1)))
    except (TypeError, ValueError):
        return None
    following_tokens = normalized_string_list(record.get("following_readings", []))
    if not following_tokens and tokens:
        following_tokens = tokens[min(len(tokens), span_start + span_length) :]

    family_id = selection_sentence_family(record, tokens)
    step_id = "event-" + stable_digest(event_key)[:16]
    case_id = "selection:" + family_id.removeprefix("sentence:")
    schema_version = int(record.get("schema_version", 1) or 1)
    candidate_languages = normalized_string_list(record.get("candidate_languages", []))
    mixed_context = bool(record.get("mixed_context")) or contains_latin(
        tokens + preceding_values + following_tokens + candidates
    )
    tags = ["real_user_selection", f"selection_schema_v{schema_version}"]
    tags.append("mixed_context" if mixed_context else "single_language_context")
    if bool(record.get("top1_changed", chosen_index > 0)):
        tags.append("user_corrected_top1")
    else:
        tags.append("user_confirmed_top1")

    rows: list[dict[str, Any]] = []
    for candidate_index in nonempty_indices:
        candidate = candidates[candidate_index]
        language_id = (
            candidate_languages[candidate_index]
            if candidate_index < len(candidate_languages) and candidate_languages[candidate_index]
            else infer_language_id(record, reading, candidate)
        )
        positive = candidate_index == chosen_index
        row = {
            "sample_id": f"{case_id}:{step_id}:cand-{candidate_index + 1}",
            "case_id": case_id,
            "step_id": step_id,
            "sentence_family_id": family_id,
            "selection_event_id": event_key,
            "runtime_sentence_id": str(record.get("sentence_id", "")),
            "label": 1 if positive else 0,
            "language_id": language_id,
            "source": source_name,
            "tags": tags,
            "all_tokens": tokens,
            "token_languages": token_languages,
            "combined_token": reading,
            "focused_token": reading,
            "candidate_surface": candidate,
            "candidate_reading_or_token": reading,
            "preceding_values": preceding_values,
            "following_tokens": following_tokens,
            "following_values": normalized_string_list(record.get("following_values", [])),
            "span_start": span_start,
            "span_length": span_length,
            "base_rank": candidate_index,
            "provider_score": -candidate_index,
            "sample_weight": 1.0,
            "mixed_context": mixed_context,
            "selection_schema_version": schema_version,
        }
        rows.append(row)
    return f"{case_id}:{step_id}", rows


def load_selection_groups(
    paths: list[Path],
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = {}
    seen_events: set[str] = set()
    stats: Counter[str] = Counter()
    per_source: Counter[str] = Counter()
    for source_index, path in enumerate(paths):
        if not path.exists():
            stats["missing_files"] += 1
            continue
        source_name = "runtime_" + source_label(path, source_index)
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                stats["raw_events"] += 1
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    stats["invalid_json"] += 1
                    continue
                key = event_fingerprint(record)
                if key in seen_events:
                    stats["deduplicated_events"] += 1
                    continue
                seen_events.add(key)
                converted = convert_selection_record(record, source_name, key)
                if converted is None:
                    stats["invalid_candidate_events"] += 1
                    continue
                group_id, rows = converted
                if not valid_group(rows):
                    stats["invalid_groups"] += 1
                    continue
                groups[group_id] = rows
                stats["accepted_events"] += 1
                stats["accepted_rows"] += len(rows)
                stats["hard_events"] += int(is_hard_group(rows))
                stats["mixed_events"] += int(is_mixed_group(rows))
                stats[f"schema_v{rows[0]['selection_schema_version']}_events"] += 1
                per_source[source_name] += 1
    return groups, {**dict(stats), "accepted_by_source": dict(per_source)}


def load_candidate_groups(
    paths: list[Path],
) -> tuple[dict[str, list[dict[str, Any]]], dict[str, Any]]:
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    stats: Counter[str] = Counter()
    for source_index, path in enumerate(paths):
        if not path.exists():
            raise FileNotFoundError(path)
        prefix = source_label(path, source_index)
        with path.open(encoding="utf-8") as handle:
            for line in handle:
                if not line.strip():
                    continue
                stats["raw_rows"] += 1
                row = json.loads(line)
                original_case = str(row.get("case_id", "missing-case"))
                original_step = str(row.get("step_id", "missing-step"))
                group_id = f"candidate:{source_index}:{original_case}:{original_step}"
                updated = dict(row)
                updated["case_id"] = f"{prefix}:{original_case}"
                updated["sample_id"] = f"{prefix}:{row.get('sample_id', stable_digest(row)[:16])}"
                groups[group_id].append(updated)
    valid: dict[str, list[dict[str, Any]]] = {}
    for group_id, rows in groups.items():
        if valid_group(rows):
            valid[group_id] = rows
        else:
            stats["invalid_groups"] += 1
    stats["accepted_groups"] = len(valid)
    stats["accepted_rows"] = sum(len(rows) for rows in valid.values())
    stats["hard_groups"] = sum(is_hard_group(rows) for rows in valid.values())
    stats["mixed_groups"] = sum(is_mixed_group(rows) for rows in valid.values())
    return valid, dict(stats)


def sentence_family_id(rows: list[dict[str, Any]], group_id: str) -> str:
    explicit = str(rows[0].get("sentence_family_id", "")).strip()
    if explicit:
        return explicit
    positive = next((row for row in rows if float(row.get("label", 0)) > 0), rows[0])
    tokens = normalized_string_list(positive.get("all_tokens", []))
    token_languages = normalized_string_list(positive.get("token_languages", []))
    if tokens:
        return "sentence:" + stable_digest(
            {"tokens": tokens, "token_languages": token_languages}
        )[:24]
    return "case:" + stable_digest(str(positive.get("case_id", group_id)))[:24]


def assign_sentence_families(
    groups: dict[str, list[dict[str, Any]]],
    seed: int,
    train_fraction: float,
    valid_fraction: float,
) -> dict[str, str]:
    family_groups: dict[str, list[list[dict[str, Any]]]] = defaultdict(list)
    for group_id, rows in groups.items():
        family_groups[sentence_family_id(rows, group_id)].append(rows)

    strata: dict[tuple[bool, bool, bool], list[str]] = defaultdict(list)
    for family_id, grouped_rows in family_groups.items():
        strata[
            (
                any(is_hard_group(rows) for rows in grouped_rows),
                any(is_mixed_group(rows) for rows in grouped_rows),
                any(is_selection_group(rows) for rows in grouped_rows),
            )
        ].append(family_id)

    assignments: dict[str, str] = {}
    for family_ids in strata.values():
        family_ids.sort(key=lambda family_id: stable_fraction(family_id, seed))
        count = len(family_ids)
        train_count = int(round(count * train_fraction))
        valid_count = int(round(count * valid_fraction))
        if count >= 3:
            train_count = min(max(1, train_count), count - 2)
            valid_count = min(max(1, valid_count), count - train_count - 1)
        for index, family_id in enumerate(family_ids):
            if index < train_count:
                assignments[family_id] = "train"
            elif index < train_count + valid_count:
                assignments[family_id] = "valid"
            else:
                assignments[family_id] = "test"
    return assignments


def annotate_group(
    rows: list[dict[str, Any]],
    family_id: str,
    split_name: str,
    seed: int,
    hard_positive_boost: float,
    hard_negative_boost: float,
) -> list[dict[str, Any]]:
    hard = is_hard_group(rows)
    result: list[dict[str, Any]] = []
    for row in rows:
        updated = dict(row)
        updated["sentence_family_id"] = family_id
        updated["sentence_split"] = split_name
        updated["sentence_split_seed"] = seed
        tags = list(updated.get("tags", []))
        tags.append("sentence_safe_split")
        tags.append("balanced_hard_case" if hard else "balanced_easy_case")
        if hard:
            boost = hard_positive_boost if float(updated.get("label", 0)) > 0 else hard_negative_boost
            updated["sample_weight"] = float(updated.get("sample_weight", 1.0)) * boost
        updated["tags"] = list(dict.fromkeys(tags))
        result.append(updated)
    return result


def write_groups(path: Path, groups: Iterable[list[dict[str, Any]]]) -> int:
    row_count = 0
    with path.open("w", encoding="utf-8") as handle:
        for rows in groups:
            for row in rows:
                handle.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
                row_count += 1
    return row_count


def split_metrics(groups: list[list[dict[str, Any]]]) -> dict[str, int]:
    families = {
        str(rows[0].get("sentence_family_id", ""))
        for rows in groups
    }
    return {
        "groups": len(groups),
        "rows": sum(len(rows) for rows in groups),
        "sentence_families": len(families),
        "cases": len({str(rows[0].get("case_id", "")) for rows in groups}),
        "hard_groups": sum(is_hard_group(rows) for rows in groups),
        "mixed_groups": sum(is_mixed_group(rows) for rows in groups),
        "selection_groups": sum(is_selection_group(rows) for rows in groups),
        "mixed_selection_groups": sum(
            is_selection_group(rows) and is_mixed_group(rows) for rows in groups
        ),
    }


def validate_split_sets(
    split_groups: dict[str, list[list[dict[str, Any]]]],
) -> dict[str, Any]:
    family_sets = {
        split: {str(rows[0].get("sentence_family_id", "")) for rows in groups}
        for split, groups in split_groups.items()
    }
    case_sets = {
        split: {str(rows[0].get("case_id", "")) for rows in groups}
        for split, groups in split_groups.items()
    }
    family_overlap = 0
    case_overlap = 0
    for index, left in enumerate(SPLIT_NAMES):
        for right in SPLIT_NAMES[index + 1 :]:
            family_overlap += len(family_sets[left] & family_sets[right])
            case_overlap += len(case_sets[left] & case_sets[right])
    invalid_groups = sum(
        not valid_group(rows)
        for groups in split_groups.values()
        for rows in groups
    )
    if family_overlap or case_overlap or invalid_groups:
        raise RuntimeError(
            f"unsafe split: family_overlap={family_overlap} "
            f"case_overlap={case_overlap} invalid_groups={invalid_groups}"
        )
    return {
        "sentence_family_overlap": family_overlap,
        "case_overlap": case_overlap,
        "invalid_groups": invalid_groups,
        "verified": True,
    }


def parse_split_seeds(raw: str) -> list[int]:
    result: list[int] = []
    for value in raw.split(","):
        value = value.strip()
        if not value:
            continue
        seed = int(value)
        if seed not in result:
            result.append(seed)
    if len(result) < 2:
        raise argparse.ArgumentTypeError("--split-seeds must contain at least two unique seeds")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True)
    parser.add_argument("--candidate-source", action="append")
    parser.add_argument("--selection-log", action="append")
    parser.add_argument("--split-seeds", default="77,113,149,181,223")
    parser.add_argument("--train-fraction", type=float, default=0.70)
    parser.add_argument("--valid-fraction", type=float, default=0.15)
    parser.add_argument("--hard-positive-boost", type=float, default=20.0)
    parser.add_argument("--hard-negative-boost", type=float, default=5.0)
    args = parser.parse_args()

    if not 0.0 < args.train_fraction < 1.0:
        parser.error("--train-fraction must be between 0 and 1")
    if not 0.0 < args.valid_fraction < 1.0:
        parser.error("--valid-fraction must be between 0 and 1")
    if args.train_fraction + args.valid_fraction >= 1.0:
        parser.error("train and valid fractions must leave a non-empty test fraction")
    try:
        split_seeds = parse_split_seeds(args.split_seeds)
    except (ValueError, argparse.ArgumentTypeError) as error:
        parser.error(str(error))

    candidate_sources = (
        [Path(value).expanduser() for value in args.candidate_source]
        if args.candidate_source
        else DEFAULT_CANDIDATE_SOURCES
    )
    selection_logs = (
        [Path(value).expanduser() for value in args.selection_log]
        if args.selection_log
        else DEFAULT_SELECTION_LOGS
    )
    output = Path(args.output).expanduser()
    output.mkdir(parents=True, exist_ok=True)

    candidate_groups, candidate_stats = load_candidate_groups(candidate_sources)
    selection_groups, selection_stats = load_selection_groups(selection_logs)
    duplicate_group_ids = set(candidate_groups) & set(selection_groups)
    if duplicate_group_ids:
        raise RuntimeError(f"duplicate group ids: {sorted(duplicate_group_ids)[:3]}")
    groups = {**candidate_groups, **selection_groups}
    if not groups:
        raise RuntimeError("no valid candidate groups")

    write_groups(output / "all.jsonl", groups.values())
    write_groups(output / "selection_records.jsonl", selection_groups.values())

    split_summaries: list[dict[str, Any]] = []
    test_family_sets: list[frozenset[str]] = []
    for split_index, seed in enumerate(split_seeds, start=1):
        split_dir = output / f"split-{split_index:02d}-seed-{seed}"
        split_dir.mkdir(parents=True, exist_ok=True)
        assignments = assign_sentence_families(
            groups,
            seed,
            args.train_fraction,
            args.valid_fraction,
        )
        selected: dict[str, list[list[dict[str, Any]]]] = {
            split: [] for split in SPLIT_NAMES
        }
        for group_id, rows in groups.items():
            family_id = sentence_family_id(rows, group_id)
            split_name = assignments[family_id]
            selected[split_name].append(
                annotate_group(
                    rows,
                    family_id,
                    split_name,
                    seed,
                    args.hard_positive_boost,
                    args.hard_negative_boost,
                )
            )
        for split_name in SPLIT_NAMES:
            selected[split_name].sort(
                key=lambda rows: stable_fraction(
                    f"{rows[0].get('sentence_family_id')}:{rows[0].get('sample_id')}",
                    seed,
                )
            )
            write_groups(split_dir / f"{split_name}.jsonl", selected[split_name])

        validation = validate_split_sets(selected)
        test_family_sets.append(
            frozenset(str(rows[0].get("sentence_family_id", "")) for rows in selected["test"])
        )
        split_summary = {
            "index": split_index,
            "seed": seed,
            "directory": str(split_dir),
            "fractions": {
                "train": args.train_fraction,
                "valid": args.valid_fraction,
                "test": 1.0 - args.train_fraction - args.valid_fraction,
            },
            "splits": {
                split_name: split_metrics(selected[split_name])
                for split_name in SPLIT_NAMES
            },
            "validation": validation,
        }
        (split_dir / "summary.json").write_text(
            json.dumps(split_summary, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        split_summaries.append(split_summary)

    summary = {
        "schema": "listwise_sentence_splits_v2",
        "candidate_sources": [str(path) for path in candidate_sources],
        "selection_logs": [str(path) for path in selection_logs],
        "split_unit": "sentence_family_from_all_tokens",
        "split_seeds": split_seeds,
        "unique_test_sets": len(set(test_family_sets)),
        "candidate_stats": candidate_stats,
        "selection_stats": selection_stats,
        "totals": {
            "groups": len(groups),
            "rows": sum(len(rows) for rows in groups.values()),
            "sentence_families": len(
                {sentence_family_id(rows, group_id) for group_id, rows in groups.items()}
            ),
            "hard_groups": sum(is_hard_group(rows) for rows in groups.values()),
            "mixed_groups": sum(is_mixed_group(rows) for rows in groups.values()),
            "selection_groups": len(selection_groups),
            "mixed_selection_groups": sum(
                is_mixed_group(rows) for rows in selection_groups.values()
            ),
        },
        "split_sets": split_summaries,
    }
    (output / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
