#!/usr/bin/env python3
"""Collect open-licensed Traditional Chinese articles with English context."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import html
import json
import re
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter
from pathlib import Path
from typing import Any, Iterable


WIKIPEDIA_API = "https://zh.wikipedia.org/w/api.php"
WIKIBOOKS_API = "https://zh.wikibooks.org/w/api.php"
WIKINEWS_API = "https://zh.wikinews.org/w/api.php"
USER_AGENT = "FastChIME/2.0 (open mixed corpus; local IME research)"
MDN_REPOSITORY = "https://github.com/mdn/translated-content.git"
MDN_RAW_BASE = "https://github.com/mdn/translated-content/blob/main/"
WIKIPEDIA_SEARCH_QUERIES = (
    "人工智慧 API 軟體",
    "machine learning 模型",
    "Apple macOS 軟體",
    "Google API 平台",
    "Microsoft Windows 軟體",
    "Python JavaScript 程式語言",
    "GitHub 開放原始碼",
    "Transformer 大型語言模型",
)
WIKIBOOKS_SEARCH_QUERIES = (
    "Python",
    "JavaScript",
    "HTML CSS",
    "Web API",
    "Apple Swift",
    "Google Chrome",
    "Microsoft Office",
    "Git GitHub",
    "機器學習",
    "人工智慧",
    "資料庫 SQL",
)
WIKINEWS_SEARCH_QUERIES = (
    "Apple",
    "Google",
    "Microsoft",
    "OpenAI",
    "ChatGPT",
    "人工智慧",
    "AI",
    "軟體",
    "網路",
    "科技",
    "GitHub",
    "Python",
)
HAN_PATTERN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]")
LATIN_PATTERN = re.compile(r"[A-Za-z]")
SENTENCE_SPLIT = re.compile(r"[。！？；!?;\n]+")
CODE_FENCE = re.compile(r"```.*?```", re.DOTALL)
FRONT_MATTER = re.compile(r"\A---\s*\n.*?\n---\s*\n", re.DOTALL)
MARKDOWN_IMAGE = re.compile(r"!\[[^\]]*\]\([^)]*\)")
MARKDOWN_LINK = re.compile(r"\[([^\]]+)\]\([^)]*\)")
MDN_MACRO_QUOTED = re.compile(r"\{\{[^{}]*?\(\s*[\"']([^\"']+)[\"'][^{}]*?\)\s*\}\}")
MDN_MACRO = re.compile(r"\{\{[^{}]+\}\}")
HTML_TAG = re.compile(r"<[^>]+>")
URL_PATTERN = re.compile(r"https?\s*:\s*//\S+", re.IGNORECASE)
WHITESPACE = re.compile(r"\s+")


def request_json(url: str, query: dict[str, str]) -> dict[str, Any]:
    full_url = f"{url}?{urllib.parse.urlencode(query)}"
    for attempt in range(5):
        request = urllib.request.Request(full_url, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                payload = json.load(response)
            time.sleep(0.35)
            return payload
        except urllib.error.HTTPError as error:
            if error.code not in (429, 503) or attempt == 4:
                raise
            retry_after = error.headers.get("Retry-After")
            delay = float(retry_after) if retry_after and retry_after.isdigit() else 2**attempt
            time.sleep(max(1.0, min(delay, 15.0)))
    raise RuntimeError("unreachable request retry state")


def stable_id(*values: str) -> str:
    return hashlib.sha256("\u241f".join(values).encode("utf-8")).hexdigest()[:24]


def normalize_text(value: str) -> str:
    value = html.unescape(value)
    value = value.replace("\\<", "<").replace("\\>", ">")
    value = value.replace("（", " (").replace("）", ") ")
    value = WHITESPACE.sub(" ", value)
    value = re.sub(r"\s+([,，、:：])", r"\1", value)
    value = re.sub(r"([,，、:：])(?=[^\s])", r"\1 ", value)
    return value.strip(" -—–*#>|：:\t\r\n")


def split_long_piece(piece: str, max_length: int) -> list[str]:
    if len(piece) <= max_length:
        return [piece]
    chunks = [normalize_text(value) for value in re.split(r"[，、：:,]", piece)]
    return [value for value in chunks if value]


def valid_mixed_sentence(sentence: str, min_length: int, max_length: int) -> bool:
    if not min_length <= len(sentence) <= max_length:
        return False
    han_count = len(HAN_PATTERN.findall(sentence))
    latin_count = len(LATIN_PATTERN.findall(sentence))
    if han_count < 4 or latin_count < 2:
        return False
    if URL_PATTERN.search(sentence):
        return False
    if "|" in sentence:
        return False
    code_markers = sum(sentence.count(marker) for marker in ("{", "}", "=>", "==", ";;"))
    if code_markers >= 2:
        return False
    visible = sum(
        character.isalnum() or bool(HAN_PATTERN.match(character))
        for character in sentence
    )
    return visible / max(1, len(sentence)) >= 0.55


def sentence_candidates(text: str, min_length: int, max_length: int) -> list[str]:
    result: list[str] = []
    for piece in SENTENCE_SPLIT.split(text):
        cleaned = normalize_text(piece)
        for chunk in split_long_piece(cleaned, max_length):
            if valid_mixed_sentence(chunk, min_length, max_length):
                result.append(chunk)
    return result


def clean_markdown(text: str) -> tuple[str, str]:
    title_match = re.search(r"^title:\s*(.+)$", text, re.MULTILINE)
    title = title_match.group(1).strip().strip('"\'') if title_match else ""
    text = FRONT_MATTER.sub("", text)
    text = CODE_FENCE.sub("\n", text)
    text = MARKDOWN_IMAGE.sub("", text)
    text = MARKDOWN_LINK.sub(r"\1", text)
    text = MDN_MACRO_QUOTED.sub(r"\1", text)
    text = MDN_MACRO.sub("", text)
    text = re.sub(r"`([^`]+)`", r"\1", text)
    text = text.replace("**", "").replace("__", "")
    text = re.sub(r"_([\u3400-\u4dbf\u4e00-\u9fff][^_\n]*?)_", r"\1", text)
    text = HTML_TAG.sub(" ", text)
    text = re.sub(r"^\s*(?:#{1,6}|>|[-*+] |\d+[.)] )", "", text, flags=re.MULTILINE)
    return title, text


def clone_or_update_mdn(checkout: Path) -> str:
    if not (checkout / ".git").exists():
        subprocess.run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--filter=blob:none",
                "--sparse",
                MDN_REPOSITORY,
                str(checkout),
            ],
            check=True,
        )
    subprocess.run(
        ["git", "-C", str(checkout), "sparse-checkout", "set", "files/zh-tw/web"],
        check=True,
    )
    return subprocess.check_output(
        ["git", "-C", str(checkout), "rev-parse", "HEAD"], text=True
    ).strip()


def collect_mdn(
    checkout: Path,
    min_length: int,
    max_length: int,
    max_sentences: int,
    max_sentences_per_article: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    commit = clone_or_update_mdn(checkout)
    root = checkout / "files/zh-tw/web"
    paths = sorted(root.rglob("*.md"))
    rows: list[dict[str, Any]] = []
    articles_with_sentences = 0
    for path in paths:
        raw = path.read_text(encoding="utf-8", errors="ignore")
        title, prose = clean_markdown(raw)
        candidates = sentence_candidates(prose, min_length, max_length)
        if candidates:
            articles_with_sentences += 1
        relative = path.relative_to(checkout).as_posix()
        article_url = f"{MDN_RAW_BASE}{relative}"
        selected_candidates = (
            candidates[:max_sentences_per_article]
            if max_sentences_per_article > 0
            else candidates
        )
        for sentence in selected_candidates:
            rows.append(
                {
                    "sentence_id": "mdn:" + stable_id(article_url, sentence),
                    "text": sentence,
                    "source": "mdn_zh_tw",
                    "title": title or path.parent.name,
                    "url": article_url,
                    "source_path": relative,
                    "license": "CC-BY-SA-2.5",
                    "attribution": "MDN contributors",
                }
            )
            if max_sentences > 0 and len(rows) >= max_sentences:
                break
        if max_sentences > 0 and len(rows) >= max_sentences:
            break
    return rows, {
        "repository": MDN_REPOSITORY,
        "commit": commit,
        "license": "CC-BY-SA-2.5",
        "scanned_articles": len(paths),
        "articles_with_sentences": articles_with_sentences,
        "sentences": len(rows),
        "max_sentences_per_article": max_sentences_per_article,
    }


def mediawiki_page_ids(
    api: str,
    queries: Iterable[str],
    max_articles: int,
) -> dict[int, str]:
    pages: dict[int, str] = {}
    for query in queries:
        payload = request_json(
            api,
            {
                "action": "query",
                "format": "json",
                "list": "search",
                "srsearch": query,
                "srnamespace": "0",
                "srlimit": "40",
                "variant": "zh-hant",
            },
        )
        for result in payload.get("query", {}).get("search", []):
            pages[int(result["pageid"])] = str(result["title"])
            if len(pages) >= max_articles:
                return pages
    return pages


def chunks(values: list[int], size: int) -> Iterable[list[int]]:
    for index in range(0, len(values), size):
        yield values[index : index + size]


def collect_mediawiki(
    *,
    api: str,
    source: str,
    sentence_prefix: str,
    article_base_url: str,
    license_name: str,
    license_url: str,
    attribution: str,
    queries: tuple[str, ...],
    min_length: int,
    max_length: int,
    max_articles: int,
    max_sentences: int,
    max_sentences_per_article: int,
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    pages = mediawiki_page_ids(api, queries, max_articles)
    rows: list[dict[str, Any]] = []
    articles_with_sentences = 0
    for page_ids in chunks(list(pages), 20):
        payload = request_json(
            api,
            {
                "action": "query",
                "format": "json",
                "pageids": "|".join(str(page_id) for page_id in page_ids),
                "prop": "extracts",
                "explaintext": "1",
                "exsectionformat": "plain",
                "variant": "zh-hant",
                "converttitles": "1",
            },
        )
        for page in payload.get("query", {}).get("pages", {}).values():
            title = str(page.get("title", ""))
            page_id = int(page.get("pageid", 0))
            article_url = f"{article_base_url}{page_id}"
            candidates = sentence_candidates(
                str(page.get("extract", "")), min_length, max_length
            )
            if candidates:
                articles_with_sentences += 1
            selected_candidates = (
                candidates[:max_sentences_per_article]
                if max_sentences_per_article > 0
                else candidates
            )
            for sentence in selected_candidates:
                rows.append(
                    {
                        "sentence_id": sentence_prefix + ":" + stable_id(str(page_id), sentence),
                        "text": sentence,
                        "source": source,
                        "title": title,
                        "url": article_url,
                        "page_id": page_id,
                        "license": license_name,
                        "license_url": license_url,
                        "attribution": attribution,
                    }
                )
                if max_sentences > 0 and len(rows) >= max_sentences:
                    break
            if max_sentences > 0 and len(rows) >= max_sentences:
                break
        if max_sentences > 0 and len(rows) >= max_sentences:
            break
    return rows, {
        "api": api,
        "license": license_name,
        "license_url": license_url,
        "searched_articles": len(pages),
        "articles_with_sentences": articles_with_sentences,
        "sentences": len(rows),
        "max_sentences_per_article": max_sentences_per_article,
        "queries": list(queries),
    }


def deduplicate(rows: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    result: list[dict[str, Any]] = []
    seen: set[str] = set()
    for row in rows:
        normalized = normalize_text(str(row["text"]))
        key = normalized.casefold()
        if key in seen:
            continue
        seen.add(key)
        updated = dict(row)
        updated["text"] = normalized
        result.append(updated)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-jsonl", required=True)
    parser.add_argument("--output-text", required=True)
    parser.add_argument("--summary", required=True)
    parser.add_argument("--mdn-checkout", default="/tmp/FastChIME-mdn-translated-content")
    parser.add_argument("--max-mdn-sentences", type=int, default=4000)
    parser.add_argument("--max-mdn-sentences-per-article", type=int, default=30)
    parser.add_argument("--max-wikipedia-articles", type=int, default=120)
    parser.add_argument("--max-wikipedia-sentences", type=int, default=1600)
    parser.add_argument("--max-wikipedia-sentences-per-article", type=int, default=25)
    parser.add_argument("--max-wikibooks-articles", type=int, default=160)
    parser.add_argument("--max-wikibooks-sentences", type=int, default=1800)
    parser.add_argument("--max-wikibooks-sentences-per-article", type=int, default=20)
    parser.add_argument("--max-wikinews-articles", type=int, default=180)
    parser.add_argument("--max-wikinews-sentences", type=int, default=1800)
    parser.add_argument("--max-wikinews-sentences-per-article", type=int, default=15)
    parser.add_argument("--min-length", type=int, default=10)
    parser.add_argument("--max-length", type=int, default=96)
    args = parser.parse_args()

    output_jsonl = Path(args.output_jsonl).expanduser()
    output_text = Path(args.output_text).expanduser()
    summary_path = Path(args.summary).expanduser()
    for path in (output_jsonl, output_text, summary_path):
        path.parent.mkdir(parents=True, exist_ok=True)

    mdn_rows, mdn_summary = collect_mdn(
        Path(args.mdn_checkout).expanduser(),
        args.min_length,
        args.max_length,
        args.max_mdn_sentences,
        args.max_mdn_sentences_per_article,
    )
    try:
        wikipedia_rows, wikipedia_summary = collect_mediawiki(
            api=WIKIPEDIA_API,
            source="wikipedia_zh_hant",
            sentence_prefix="wikipedia",
            article_base_url="https://zh.wikipedia.org/?curid=",
            license_name="CC-BY-SA-4.0 / GFDL",
            license_url="https://creativecommons.org/licenses/by-sa/4.0/deed.zh-hant",
            attribution="Wikipedia contributors",
            queries=WIKIPEDIA_SEARCH_QUERIES,
            min_length=args.min_length,
            max_length=args.max_length,
            max_articles=args.max_wikipedia_articles,
            max_sentences=args.max_wikipedia_sentences,
            max_sentences_per_article=args.max_wikipedia_sentences_per_article,
        )
    except (urllib.error.URLError, TimeoutError) as error:
        wikipedia_rows = []
        wikipedia_summary = {
            "api": WIKIPEDIA_API,
            "license": "CC-BY-SA-4.0 / GFDL",
            "sentences": 0,
            "status": "temporarily_unavailable",
            "error": str(error),
        }
    try:
        wikibooks_rows, wikibooks_summary = collect_mediawiki(
            api=WIKIBOOKS_API,
            source="wikibooks_zh_hant",
            sentence_prefix="wikibooks",
            article_base_url="https://zh.wikibooks.org/?curid=",
            license_name="CC-BY-SA-4.0",
            license_url="https://creativecommons.org/licenses/by-sa/4.0/deed.zh",
            attribution="Wikibooks contributors",
            queries=WIKIBOOKS_SEARCH_QUERIES,
            min_length=args.min_length,
            max_length=args.max_length,
            max_articles=args.max_wikibooks_articles,
            max_sentences=args.max_wikibooks_sentences,
            max_sentences_per_article=args.max_wikibooks_sentences_per_article,
        )
    except (urllib.error.URLError, TimeoutError) as error:
        wikibooks_rows = []
        wikibooks_summary = {
            "api": WIKIBOOKS_API,
            "license": "CC-BY-SA-4.0",
            "sentences": 0,
            "status": "temporarily_unavailable",
            "error": str(error),
        }
    try:
        wikinews_rows, wikinews_summary = collect_mediawiki(
            api=WIKINEWS_API,
            source="wikinews_zh_hant",
            sentence_prefix="wikinews",
            article_base_url="https://zh.wikinews.org/?curid=",
            license_name="CC-BY-4.0",
            license_url="https://creativecommons.org/licenses/by/4.0/",
            attribution="Wikinews contributors",
            queries=WIKINEWS_SEARCH_QUERIES,
            min_length=args.min_length,
            max_length=args.max_length,
            max_articles=args.max_wikinews_articles,
            max_sentences=args.max_wikinews_sentences,
            max_sentences_per_article=args.max_wikinews_sentences_per_article,
        )
    except (urllib.error.URLError, TimeoutError) as error:
        wikinews_rows = []
        wikinews_summary = {
            "api": WIKINEWS_API,
            "license": "CC-BY-4.0",
            "sentences": 0,
            "status": "temporarily_unavailable",
            "error": str(error),
        }
    source_rows = mdn_rows + wikipedia_rows + wikibooks_rows + wikinews_rows
    rows = deduplicate(source_rows)
    retrieved_at = dt.datetime.now(dt.timezone.utc).isoformat()
    with output_jsonl.open("w", encoding="utf-8") as handle:
        for row in rows:
            updated = dict(row)
            updated["retrieved_at"] = retrieved_at
            handle.write(json.dumps(updated, ensure_ascii=False, separators=(",", ":")) + "\n")
    output_text.write_text(
        "\n".join(str(row["text"]) for row in rows) + "\n",
        encoding="utf-8",
    )
    counts = Counter(str(row["source"]) for row in rows)
    summary = {
        "schema": "open_mixed_corpus_v1",
        "retrieved_at": retrieved_at,
        "filters": {
            "min_length": args.min_length,
            "max_length": args.max_length,
            "requires_han_characters": 4,
            "requires_latin_characters": 2,
        },
        "sources": {
            "mdn": mdn_summary,
            "wikipedia": wikipedia_summary,
            "wikibooks": wikibooks_summary,
            "wikinews": wikinews_summary,
        },
        "sentences_before_deduplication": len(source_rows),
        "sentences": len(rows),
        "sentences_by_source": dict(counts),
        "output_jsonl": str(output_jsonl),
        "output_text": str(output_text),
    }
    summary_path.write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
