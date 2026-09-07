#!/usr/bin/env python3
import argparse
import json
import re
import time
import urllib.parse
import urllib.request
from pathlib import Path


API = "https://zh.wikipedia.org/w/api.php"
USER_AGENT = "UnifyIME/1.0 (ranker corpus fetch)"
TATOEBA_TSV = "https://raw.githubusercontent.com/krmanik/Chinese-Example-Sentences/main/Chinese%20Example%20Sentences/cmn_sen_db_2.tsv"
SIMPLIFIED_HINTS = set("后发国学体会云广万与东为业严丰临丽举么义乌乐乔习乡书买乱争于亏亚产亩亲亿仅从仑仓仪价众优伙伞伟伤伦伪体余")
TRADITIONAL_HINTS = set("後發國學體會雲廣萬與東為業嚴豐臨麗舉麼義烏樂喬習鄉書買亂爭於虧亞產畝親億僅從侖倉儀價眾優夥傘偉傷倫偽體餘")
SENTENCE_SPLIT = re.compile(r"[。！？；?!;\n]+")


def fetch_random_extracts(batch_size: int):
    query = {
        "action": "query",
        "format": "json",
        "generator": "random",
        "grnnamespace": "0",
        "grnlimit": str(batch_size),
        "prop": "extracts",
        "explaintext": "1",
        "exlimit": "max",
        "variant": "zh-hant",
    }
    url = f"{API}?{urllib.parse.urlencode(query)}"
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.load(resp)
    return list(payload.get("query", {}).get("pages", {}).values())


def has_enough_traditional(text: str) -> bool:
    simp = sum(1 for ch in text if ch in SIMPLIFIED_HINTS)
    trad = sum(1 for ch in text if ch in TRADITIONAL_HINTS)
    return trad >= simp


def han_ratio(text: str) -> float:
    if not text:
        return 0.0
    han = 0
    for ch in text:
        code = ord(ch)
        if 0x3400 <= code <= 0x4DBF or 0x4E00 <= code <= 0x9FFF:
            han += 1
    return han / max(len(text), 1)


def clean_sentence(text: str) -> str:
    text = re.sub(r"\[[0-9]+\]", "", text)
    text = re.sub(r"\s+", "", text)
    text = text.strip("()（）「」『』【】《》〈〉,，、:：\"' ")
    return text


def extract_sentences(extract: str, min_len: int, max_len: int):
    out = []
    for piece in SENTENCE_SPLIT.split(extract):
        sentence = clean_sentence(piece)
        if not sentence:
            continue
        if not (min_len <= len(sentence) <= max_len):
            continue
        if not has_enough_traditional(sentence):
            continue
        if han_ratio(sentence) < 0.75:
            continue
        out.append(sentence)
    return out


def fetch_tatoeba_sentences(min_len: int, max_len: int, limit: int):
    req = urllib.request.Request(TATOEBA_TSV, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        text = resp.read().decode("utf-8", "ignore")
    sentences = []
    for line in text.splitlines():
        cols = line.split("\t")
        if len(cols) < 3:
            continue
        sentence = clean_sentence(cols[2])
        if not sentence:
            continue
        if not (min_len <= len(sentence) <= max_len):
            continue
        if not has_enough_traditional(sentence):
            continue
        if han_ratio(sentence) < 0.6:
            continue
        sentences.append(sentence)
        if len(sentences) >= limit:
            break
    print(f"loaded_tatoeba_sentences={len(sentences)}", flush=True)
    return sentences


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True)
    parser.add_argument("--meta-output", required=True)
    parser.add_argument("--target-sentences", type=int, default=6000)
    parser.add_argument("--wiki-target-sentences", type=int, default=3000)
    parser.add_argument("--tatoeba-target-sentences", type=int, default=7000)
    parser.add_argument("--batch-size", type=int, default=20)
    parser.add_argument("--min-len", type=int, default=8)
    parser.add_argument("--max-len", type=int, default=28)
    parser.add_argument("--sleep-ms", type=int, default=100)
    args = parser.parse_args()

    output = Path(args.output)
    meta_output = Path(args.meta_output)
    output.parent.mkdir(parents=True, exist_ok=True)
    meta_output.parent.mkdir(parents=True, exist_ok=True)

    seen = set()
    sentences = []
    meta = []

    tatoeba = fetch_tatoeba_sentences(args.min_len, args.max_len, args.tatoeba_target_sentences)
    for sentence in tatoeba:
        if sentence in seen:
            continue
        seen.add(sentence)
        sentences.append(sentence)

    wiki_target = max(args.wiki_target_sentences, args.target_sentences - len(sentences))
    wiki_batches = 0
    while len(sentences) < args.target_sentences and len(meta) < wiki_target * 4:
        pages = fetch_random_extracts(args.batch_size)
        wiki_batches += 1
        for page in pages:
            title = page.get("title", "")
            extract = page.get("extract", "")
            picked = extract_sentences(extract, args.min_len, args.max_len)
            if picked:
                meta.append({
                    "title": title,
                    "pageid": page.get("pageid"),
                    "sentence_count": len(picked),
                })
            for sentence in picked:
                if sentence in seen:
                    continue
                seen.add(sentence)
                sentences.append(sentence)
                if len(sentences) >= args.target_sentences:
                    break
            if len(sentences) >= args.target_sentences:
                break
        if wiki_batches % 10 == 0:
            print(f"wiki_batches={wiki_batches} collected_sentences={len(sentences)} articles={len(meta)}", flush=True)
        time.sleep(args.sleep_ms / 1000.0)

    output.write_text("\n".join(sentences) + "\n", encoding="utf-8")
    meta_output.write_text(json.dumps({
        "sources": [
            {
                "name": "zh.wikipedia.org",
                "variant": "zh-hant",
                "license": "CC BY-SA 4.0 / GFDL",
            },
            {
                "name": "krmanik/Chinese-Example-Sentences",
                "origin": "Tatoeba",
                "license": "See upstream repository and Tatoeba licensing",
            },
        ],
        "sentences": len(sentences),
        "articles": len(meta),
        "tatoeba_sentences": len(tatoeba),
        "user_agent": USER_AGENT,
        "articles_sample": meta[:200],
    }, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"saved_sentences={output}", flush=True)
    print(f"saved_meta={meta_output}", flush=True)
    print(f"sentence_count={len(sentences)}", flush=True)


if __name__ == "__main__":
    main()
