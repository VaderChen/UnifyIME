#!/usr/bin/env python3

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path


def resolve_root() -> Path:
    explicit = os.environ.get("UNIFYIME_WORKSPACE_ROOT") or os.environ.get("FASTCHIME_WORKSPACE_ROOT")
    if explicit:
        return Path(explicit).expanduser().resolve()
    return Path(__file__).resolve().parents[3]


ROOT = resolve_root()
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
OUTPUT = ROOT / "src" / "unifyIME" / "tests" / "regression_cases.jsonl"
TARGET_COUNTS = {"zh": 100, "en": 100, "mix": 200}
PROBE_BATCH_COMMANDS = {
    "zh": "zh-probe-input-batch",
    "en": "en-probe-input-batch",
    "mix": "probe-input-batch",
}
ACTION_BATCH_COMMANDS = {
    "zh": "zh-ime-action-batch-probe",
    "en": "en-ime-action-batch-probe",
    "mix": "ime-action-batch-probe",
}


def run(cmd: list[str], timeout: int = 180) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, timeout=timeout)


def batch_outputs(command: str, rows: list[dict[str, object]]) -> dict[str, dict]:
    batch_path = Path(tempfile.gettempdir()) / f"unifyime_generate_batch_{command}.jsonl"
    with batch_path.open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    result = run([str(APP), command, str(batch_path)], timeout=180)
    if result.returncode != 0:
        raise RuntimeError(f"{command} failed: {(result.stdout + result.stderr).strip()}")
    outputs: dict[str, dict] = {}
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        payload = json.loads(line)
        row_id = str(payload.get("row_id", ""))
        if row_id:
            outputs[row_id] = payload
    return outputs


def unique(items: list[str]) -> list[str]:
    seen = set()
    output = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        output.append(item)
    return output


def zh_candidates() -> list[str]:
    subjects = [
        "我", "你", "他", "我們", "這個功能", "這個輸入法", "選字視窗", "候選順序", "游標位置", "多語言模式",
        "這次修改", "整個系統", "批次測試", "輸入結果", "設定內容",
    ]
    objects = [
        "這個輸入法", "候選順序", "選字視窗", "游標位置", "多語言模式", "批次測試", "設定內容", "輸入結果",
        "候選清單", "整個流程", "畫面內容", "第二種語言", "英文字庫", "測試資料", "排序邏輯",
    ]
    templates = [
        "{subject}今天想試試看{object}",
        "{subject}現在可以正常處理{object}",
        "{subject}看起來已經很穩定了",
        "請幫我把{object}調整一下",
        "如果有問題就直接把{object}貼給我",
        "{subject}改完之後反應速度快很多了",
        "{subject}不要一直卡住",
        "試試看{object}現在能不能選到",
        "{subject}之後還要再加入第二種語言",
        "{subject}明天早上要先去公司開會",
    ]
    results: list[str] = []
    for subject in subjects:
        for obj in objects:
            for template in templates:
                text = template.format(subject=subject, object=obj)
                if "{" in text:
                    continue
                results.append(text)
    return unique(results)


def en_candidates() -> list[str]:
    words1 = [
        "hello", "english", "technical", "reading", "working", "practical", "writing", "adaptive", "service", "natural",
        "global", "local", "modern", "formal", "future", "critical", "project", "meeting", "ability", "system",
    ]
    words2 = [
        "world", "words", "ability", "project", "meeting", "window", "cursor", "ranking", "feature", "engine",
        "input", "output", "signal", "adapter", "language", "token", "sentence", "result", "screen", "config",
    ]
    words3 = [
        "meeting", "projects", "abilities", "results", "systems", "windows", "features", "engines", "inputs", "outputs",
        "signals", "adapters", "languages", "tokens", "sentences", "screens", "configs", "words", "world", "project",
    ]
    phrases = [
        "innovation ability", "technical ability", "reading ability", "working ability", "practical ability",
        "writing ability", "service ability", "adaptive ability", "management ability", "learning ability",
    ]
    results = []
    results.extend(phrases)
    for a in words1:
        for b in words2:
            results.append(f"{a} {b}")
    for a in words1[:10]:
        for b in words2[:10]:
            for c in words3[:10]:
                results.append(f"{a} {b} {c}")
    return unique(results)


def mix_candidates() -> list[str]:
    zh_prefixes = [
        "我想", "這個", "請加入一些", "今天", "下週有", "這次", "如果要", "我們現在要", "請直接把", "最後再看一下",
        "目前", "接下來", "現在", "之後", "剛剛的",
    ]
    zh_suffixes = [
        "一下", "很重要", "進去", "延後", "也要測", "先保留", "再調整", "先跑一遍", "放進選單", "寫進文件",
        "加到測試裡", "做成正式流程", "回頭再修", "不要吃掉右邊", "先確認結果",
    ]
    en_phrases = [
        "test", "project", "english words", "project meetings", "technical ability", "reading ability", "working projects",
        "feature flag", "global ranking", "local adapter", "input token", "output result", "screen config", "future language",
        "batch runner", "thread pool", "signal adapter", "cursor window", "meeting notes", "service ability",
    ]
    results = []
    for prefix in zh_prefixes:
        for phrase in en_phrases:
            results.append(f"{prefix} {phrase}")
            for suffix in zh_suffixes:
                results.append(f"{prefix} {phrase} {suffix}")
    return unique(results)


def resolve_cases(category: str, candidates: list[str], limit: int) -> list[str]:
    probe_cmd = PROBE_BATCH_COMMANDS[category]
    action_cmd = ACTION_BATCH_COMMANDS[category]
    input_path = Path(tempfile.gettempdir()) / f"unifyime_generate_cases_{category}.txt"
    with input_path.open("w", encoding="utf-8") as handle:
        for sentence in candidates:
            handle.write(sentence + "\n")
    result = run([str(APP), probe_cmd, str(input_path)], timeout=180)
    if result.returncode != 0:
        raise RuntimeError(f"{probe_cmd} failed: {(result.stdout + result.stderr).strip()}")
    lines = [line for line in result.stdout.splitlines() if line.strip()]
    batch_rows: list[dict[str, object]] = []
    row_map: dict[str, str] = {}
    for index, (sentence, line) in enumerate(zip(candidates, lines)):
        try:
            payload = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not payload.get("resolved"):
            continue
        row_keys = payload.get("row_keys")
        if not isinstance(row_keys, list) or not row_keys:
            continue
        row_id = f"{category}-{index}"
        batch_rows.append({"row_id": row_id, "row_keys": row_keys})
        row_map[row_id] = sentence

    resolved: list[str] = []
    chunk_size = 100
    for offset in range(0, len(batch_rows), chunk_size):
        chunk = batch_rows[offset: offset + chunk_size]
        outputs = batch_outputs(action_cmd, chunk)
        for row in chunk:
            row_id = str(row["row_id"])
            payload = outputs.get(row_id)
            if not payload or payload.get("error"):
                continue
            sentence = row_map[row_id]
            actual = str(payload.get("text", "")).replace("❚", "").strip()
            if actual != sentence:
                continue
            resolved.append(sentence)
            if len(resolved) >= limit:
                return resolved
    return resolved


def main() -> int:
    datasets = {
        "zh": resolve_cases("zh", zh_candidates(), TARGET_COUNTS["zh"]),
        "en": resolve_cases("en", en_candidates(), TARGET_COUNTS["en"]),
        "mix": resolve_cases("mix", mix_candidates(), TARGET_COUNTS["mix"]),
    }
    for category, target in TARGET_COUNTS.items():
        actual = len(datasets[category])
        if actual < target:
            raise RuntimeError(f"{category} only resolved {actual}/{target}")

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with OUTPUT.open("w", encoding="utf-8") as handle:
        for category in ("zh", "en", "mix"):
            for sentence in datasets[category]:
                handle.write(json.dumps({"category": category, "sentence": sentence}, ensure_ascii=False) + "\n")
    print(f"WROTE {sum(len(v) for v in datasets.values())} cases -> {OUTPUT}")
    for category in ("zh", "en", "mix"):
        print(f"{category}: {len(datasets[category])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
