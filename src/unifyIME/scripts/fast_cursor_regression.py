#!/usr/bin/env python3
import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Optional


ROOT = Path(__file__).resolve().parents[2]
APP_SUPPORT = Path.home() / "Library/Application Support/UnifyIME"
REVERSE_CACHE = APP_SUPPORT / "reverse_lexicon_cache.json"
COMMON_MAP = ROOT / "fastChIME" / "Resources" / "common_map.tsv"
PHRASE_MAP = ROOT / "fastChIME" / "Resources" / "phrase_map.tsv"


def load_forward_lexicon() -> Dict[str, List[str]]:
    forward: Dict[str, List[str]] = {}
    for path in (COMMON_MAP, PHRASE_MAP):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            reading, surface = parts[0], parts[1]
            if not reading or not surface:
                continue
            forward.setdefault(reading, [])
            if surface not in forward[reading]:
                forward[reading].append(surface)
    return forward


@dataclass(frozen=True)
class InsertionCase:
    base: str
    insert: str
    cursor: int
    expected: str
    insert_readings: list[str]


@dataclass(frozen=True)
class DeletionCase:
    base: str
    location: int
    length: int
    expected: str


INSERTION_CASES = [
    InsertionCase("我試看看", "一下", 2, "我試一下看看", ["ㄧ", "ㄒㄧㄚˋ"]),
    InsertionCase("測試看看", "一", 2, "測試一看看", ["ㄧ"]),
    InsertionCase("你現在可以", "還", 2, "你現在還可以", ["ㄏㄞˊ"]),
    InsertionCase("我們回家", "先", 2, "我們先回家", ["ㄒㄧㄢ"]),
    InsertionCase("這個功能穩定", "很", 4, "這個功能很穩定", ["ㄏㄣˇ"]),
]

DELETION_CASES = [
    DeletionCase("我試一下看看", 2, 2, "我試看看"),
    DeletionCase("測試一看看", 2, 1, "測試看看"),
    DeletionCase("你現在還可以", 2, 1, "你現在可以"),
    DeletionCase("我們先回家", 2, 1, "我們回家"),
    DeletionCase("這個功能很穩定", 4, 1, "這個功能穩定"),
]


def load_reverse_lexicon() -> Dict[str, List[str]]:
    if REVERSE_CACHE.exists():
        return json.loads(REVERSE_CACHE.read_text(encoding="utf-8"))

    reverse: Dict[str, List[str]] = {}

    def add(surface: str, reading: str) -> None:
        if not surface or not reading:
            return
        reverse.setdefault(surface, [])
        if reading not in reverse[surface]:
            reverse[surface].append(reading)

    for path in (COMMON_MAP, PHRASE_MAP):
        if not path.exists():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            reading, surface = parts[0], parts[1]
            add(surface, reading)

    APP_SUPPORT.mkdir(parents=True, exist_ok=True)
    REVERSE_CACHE.write_text(json.dumps(reverse, ensure_ascii=False), encoding="utf-8")
    return reverse


def reverse_readings(sentence: str, reverse_map: Dict[str, List[str]]) -> Optional[List[str]]:
    chars = list(sentence)
    count = len(chars)
    best: List[Optional[List[str]]] = [None] * (count + 1)
    best[count] = []

    for start in range(count - 1, -1, -1):
        choice = None
        for end in range(count, start, -1):
            text = "".join(chars[start:end])
            readings = reverse_map.get(text)
            tail = best[end]
            if not readings or tail is None:
                continue
            for reading in readings:
                candidate = [reading] + tail
                if choice is None or len(candidate) < len(choice):
                    choice = candidate
        best[start] = choice
    return best[0]


def resolve_committed_text(readings: List[str], reverse_map: Dict[str, List[str]], forward_map: Dict[str, List[str]]) -> str:
    joined = "".join(readings)
    direct = forward_map.get(joined)
    if direct:
        return direct[0]

    parts: list[str] = []
    for reading in readings:
        direct_list = forward_map.get(reading, [])
        direct = next((surface for surface in direct_list if len(surface) == 1), None)
        parts.append(direct or reading)
    return "".join(parts)


def simulate_insertion(case: InsertionCase, reverse_map: Dict[str, List[str]], forward_map: Dict[str, List[str]]) -> str:
    left_text = case.base[:case.cursor]
    right_text = case.base[case.cursor:]
    left = reverse_readings(left_text, reverse_map) or []
    right = reverse_readings(right_text, reverse_map) or []
    return resolve_committed_text(left + case.insert_readings + right, reverse_map, forward_map)


def simulate_deletion(case: DeletionCase, reverse_map: Dict[str, List[str]], forward_map: Dict[str, List[str]]) -> str:
    remaining = case.base[:case.location] + case.base[case.location + case.length :]
    readings = reverse_readings(remaining, reverse_map) or []
    return resolve_committed_text(readings, reverse_map, forward_map)


def run(rounds: int, summary_only: bool) -> int:
    reverse_map = load_reverse_lexicon()
    forward_map = load_forward_lexicon()
    total_ins = total_del = pass_ins = pass_del = 0

    for round_index in range(rounds):
        if rounds > 1:
            print(f"=== ROUND {round_index + 1}/{rounds} ===")

        for idx, case in enumerate(INSERTION_CASES, start=1):
            output = simulate_insertion(case, reverse_map, forward_map)
            ok = output == case.expected
            total_ins += 1
            pass_ins += int(ok)
            if not summary_only:
                print(f"[INS {idx}] {'PASS' if ok else 'FAIL'}")
                print(f"原句: {case.base}")
                print(f"插入: {case.insert}")
                print(f"位置: {case.cursor}")
                print(f"預期: {case.expected}")
                print(f"輸出: {output}")
                print("---")

        print(f"插入總結: {pass_ins}/{total_ins} 通過")

        for idx, case in enumerate(DELETION_CASES, start=1):
            output = simulate_deletion(case, reverse_map, forward_map)
            ok = output == case.expected
            total_del += 1
            pass_del += int(ok)
            if not summary_only:
                print(f"[DEL {idx}] {'PASS' if ok else 'FAIL'}")
                print(f"原句: {case.base}")
                print(f"刪除位置: {case.location}")
                print(f"刪除長度: {case.length}")
                print(f"預期: {case.expected}")
                print(f"輸出: {output}")
                print("---")

        print(f"刪除總結: {pass_del}/{total_del} 通過")

    if rounds > 1:
        overall = pass_ins + pass_del
        total = total_ins + total_del
        print(f"=== AGGREGATE SUMMARY ({rounds} ROUNDS) ===")
        print(f"插入總結: {pass_ins}/{total_ins} 通過")
        print(f"刪除總結: {pass_del}/{total_del} 通過")
        print(f"整體總結: {overall}/{total} 通過")

    return 0 if (pass_ins == total_ins and pass_del == total_del) else 2


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--summary-only", action="store_true")
    args = parser.parse_args()
    return run(max(1, args.rounds), args.summary_only)


if __name__ == "__main__":
    raise SystemExit(main())
