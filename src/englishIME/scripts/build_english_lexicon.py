#!/usr/bin/env python3

from __future__ import annotations

import json
import re
import urllib.request
from collections import defaultdict
from pathlib import Path


SOURCE_FILES = [
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/1-%E5%88%9D%E4%B8%AD-%E9%A1%BA%E5%BA%8F.json", 700),
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/2-%E9%AB%98%E4%B8%AD-%E9%A1%BA%E5%BA%8F.json", 600),
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/3-CET4-%E9%A1%BA%E5%BA%8F.json", 500),
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/4-CET6-%E9%A1%BA%E5%BA%8F.json", 400),
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/5-%E8%80%83%E7%A0%94-%E9%A1%BA%E5%BA%8F.json", 300),
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/6-%E6%89%98%E7%A6%8F-%E9%A1%BA%E5%BA%8F.json", 200),
    ("https://raw.githubusercontent.com/KyleBing/english-vocabulary/master/json/7-SAT-%E9%A1%BA%E5%BA%8F.json", 100),
]

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "Resources" / "english_words.tsv"


def normalize_token(text: str) -> str:
    return "".join(ch for ch in text.lower() if ch.isalpha() or ch in {"'", "-"}).strip("-'")


def normalize_phrase(text: str) -> str:
    words = [normalize_token(part) for part in re.split(r"\s+", text.strip())]
    words = [word for word in words if word]
    return " ".join(words)


def best_translation(translations: list[dict]) -> str:
    cleaned = []
    for item in translations or []:
        text = str(item.get("translation", "")).strip()
        if text and text not in cleaned:
            cleaned.append(text)
    return "；".join(cleaned[:3])


def inflections(base: str) -> set[str]:
    forms = set()
    if len(base) <= 2 or " " in base or "'" in base:
        return forms

    if base.endswith("y") and len(base) > 2 and base[-2] not in "aeiou":
        stem = base[:-1]
        forms.update({stem + "ies", stem + "ied"})
        forms.add(base + "ing")
    elif base.endswith(("s", "sh", "ch", "x", "z", "o")):
        forms.add(base + "es")
        forms.add(base + "ed")
        forms.add(base + "ing")
    elif base.endswith("e") and len(base) > 3:
        forms.add(base + "s")
        forms.add(base + "d")
        forms.add(base[:-1] + "ing")
    else:
        forms.add(base + "s")
        forms.add(base + "ed")
        forms.add(base + "ing")

    if base.endswith("ic"):
        forms.add(base + "ally")
    elif base.endswith("y") and len(base) > 2 and base[-2] not in "aeiou":
        forms.add(base[:-1] + "ily")
    else:
        forms.add(base + "ly")

    return {form for form in forms if form != base and re.fullmatch(r"[a-z][a-z'-]*", form)}


def fetch_json(url: str) -> list[dict]:
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def build_entries() -> dict[str, tuple[str, int, str]]:
    entries: dict[str, tuple[str, int, str]] = {}
    phrase_entries: dict[str, tuple[str, int, str]] = {}
    derivatives: dict[str, tuple[str, int, str]] = {}

    for url, base_weight in SOURCE_FILES:
        data = fetch_json(url)
        for item in data:
            word = normalize_token(str(item.get("word", "")))
            if not word:
                continue
            translation = best_translation(item.get("translations", []))
            current = entries.get(word)
            if current is None or base_weight > current[1]:
                entries[word] = (str(item.get("word", word)).strip() or word, base_weight, translation)

            for form in inflections(word):
                current = derivatives.get(form)
                if current is None or base_weight - 15 > current[1]:
                    derivatives[form] = (form, max(1, base_weight - 15), translation)

            for phrase_item in item.get("phrases", [])[:30]:
                phrase = normalize_phrase(str(phrase_item.get("phrase", "")))
                if not phrase or phrase == word:
                    continue
                if len(phrase.split()) < 2:
                    continue
                phrase_translation = str(phrase_item.get("translation", "")).strip() or translation
                current = phrase_entries.get(phrase)
                phrase_weight = max(1, base_weight - 20)
                surface = str(phrase_item.get("phrase", phrase)).strip() or phrase
                if current is None or phrase_weight > current[1]:
                    phrase_entries[phrase] = (surface, phrase_weight, phrase_translation)

    merged = dict(entries)
    for bucket in (derivatives, phrase_entries):
        for normalized, payload in bucket.items():
            current = merged.get(normalized)
            if current is None or payload[1] > current[1]:
                merged[normalized] = payload
    return merged


def main() -> int:
    entries = build_entries()
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as handle:
        for normalized in sorted(entries):
            surface, weight, translation = entries[normalized]
            handle.write(f"{normalized}\t{surface}\t{weight}\t{translation}\n")
    print(f"WROTE {len(entries)} entries -> {OUTPUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
