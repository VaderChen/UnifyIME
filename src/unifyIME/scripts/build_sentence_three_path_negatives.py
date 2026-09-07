#!/usr/bin/env python3
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
APP = ROOT / "bin" / "app" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
DEPLOYED_APP = Path.home() / "Library" / "Input Methods" / "全一輸入法.app" / "Contents" / "MacOS" / "UnifyIME"
DEFAULT_TIMEOUT = 20
TEMP_DIR = ROOT / "temp"


def resolve_app_path():
    if APP.exists():
        return APP
    if DEPLOYED_APP.exists():
        return DEPLOYED_APP
    raise FileNotFoundError(f"UnifyIME binary not found: {APP} or {DEPLOYED_APP}")


def run_capture(cmd, env=None, timeout=DEFAULT_TIMEOUT):
    try:
        return subprocess.run(
            cmd,
            cwd=ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return None


def load_sentences(path: Path, limit: int):
    sentences = [line.strip() for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
    if limit > 0:
        return sentences[:limit]
    return sentences


def parse_selftest(stdout: str):
    key_sequence = None
    output = None
    for line in stdout.splitlines():
        if line.startswith("鍵序: "):
            key_sequence = line[len("鍵序: "):].strip()
        elif line.startswith("輸出: "):
            output = line[len("輸出: "):].strip()
    return key_sequence, output


def parse_probe_input_json(stdout: str):
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return None
    if not payload.get("resolved"):
        return None
    key_sequence = (payload.get("key_sequence") or "").strip()
    readings = payload.get("readings") or []
    row_keys = payload.get("row_keys") or []
    return {
        "key_sequence": key_sequence,
        "readings": readings,
        "row_keys": row_keys,
    }


def parse_probe_json(stdout: str):
    try:
        payload = json.loads(stdout)
    except json.JSONDecodeError:
        return {"text": "", "readings": "", "has_composition": False}
    return {
        "text": (payload.get("text") or "").strip(),
        "readings": (payload.get("readings") or "").strip(),
        "has_composition": bool(payload.get("has_composition", False)),
    }


def parse_action_probe(stdout: str):
    text_marker = "文字：\n"
    reading_marker = "\n\n讀音佇列："
    queue_empty = "讀音佇列：\n（空）"
    idx = stdout.rfind(text_marker)
    if idx == -1:
        return {"text": "", "readings": "", "has_composition": False}
    tail = stdout[idx + len(text_marker):]
    final_text = tail.split(reading_marker, 1)[0].replace("❚", "").strip()

    queue_idx = stdout.rfind("讀音佇列：")
    if queue_idx == -1:
        return {"text": final_text, "readings": "", "has_composition": False}
    queue_tail = stdout[queue_idx:]
    has_composition = queue_empty not in queue_tail
    readings = queue_tail.split("\n\n候選：", 1)[0].split("讀音佇列：\n", 1)[-1].strip()
    if readings == "（空）":
        readings = ""
    return {
        "text": final_text,
        "readings": readings,
        "has_composition": has_composition,
    }


def env_for_mode(mode: str):
    env = os.environ.copy()
    if mode == "traditional":
        env["UNIFYIME_DISABLE_COREML_RANKER"] = "1"
        env["FASTCHIME_DISABLE_COREML_RANKER"] = "1"
    elif mode == "nn_only":
        env.pop("UNIFYIME_DISABLE_COREML_RANKER", None)
        env.pop("FASTCHIME_DISABLE_COREML_RANKER", None)
        env["UNIFYIME_COREML_ONLY_RANKER"] = "1"
        env["FASTCHIME_COREML_ONLY_RANKER"] = "1"
    elif mode == "hybrid":
        env.pop("UNIFYIME_DISABLE_COREML_RANKER", None)
        env.pop("FASTCHIME_DISABLE_COREML_RANKER", None)
        env.pop("UNIFYIME_COREML_ONLY_RANKER", None)
        env.pop("FASTCHIME_COREML_ONLY_RANKER", None)
    else:
        raise ValueError(f"unknown mode: {mode}")
    return env


def collect_for_sentence(sentence: str, timeout: int, modes):
    app_path = resolve_app_path()
    probe_input = run_capture([str(app_path), "probe-input", sentence], timeout=timeout)
    if probe_input is None:
        return None
    input_payload = parse_probe_input_json(probe_input.stdout)
    if input_payload is None:
        return None
    key_sequence = input_payload["key_sequence"]
    row_keys = [token for token in (input_payload.get("row_keys") or []) if token]
    if not key_sequence and not row_keys:
        return None
    key_tokens = [token for token in key_sequence.split() if token and "?" not in token]
    if not row_keys:
        if not key_tokens:
            return None
        row_keys = [f"raw:{token}" for token in key_tokens] + ["enter"]
    if not key_tokens and any(token.startswith("raw:") for token in row_keys):
        key_tokens = [token.split(":", 1)[1] for token in row_keys if token.startswith("raw:")]
    if not row_keys:
        return None

    results = {
        "sentence": sentence,
        "key_sequence": key_sequence,
        "key_tokens": key_tokens,
        "row_keys": row_keys,
        "probe_readings": input_payload["readings"],
        "paths": {},
    }

    for mode in modes:
        probe = run_capture([str(app_path), "ime-action-probe", *row_keys], env=env_for_mode(mode), timeout=timeout)
        if probe is None:
            results["paths"][mode] = {
                "returncode": -1,
                "output": "",
                "readings": "",
                "has_composition": False,
                "timeout": True,
            }
            continue
        parsed = parse_action_probe(probe.stdout)
        results["paths"][mode] = {
            "returncode": probe.returncode,
            "output": parsed["text"],
            "readings": parsed["readings"],
            "has_composition": parsed["has_composition"],
            "timeout": False,
        }

    negatives = []
    seen = set()
    for mode, payload in results["paths"].items():
        output = payload["output"]
        if not output or output == sentence or output in seen:
            continue
        seen.add(output)
        negatives.append({
            "mode": mode,
            "text": output,
        })
    results["negatives"] = negatives
    return results


def collect_batch(sentences, timeout: int, modes):
    app_path = resolve_app_path()
    TEMP_DIR.mkdir(parents=True, exist_ok=True)
    probe_input_path = TEMP_DIR / "probe_input_batch.txt"
    probe_input_path.write_text("\n".join(sentences) + "\n", encoding="utf-8")
    probe = run_capture([str(app_path), "probe-input-batch", str(probe_input_path)], timeout=timeout * max(1, len(sentences)))
    if probe is None:
        return {}, len(sentences)

    input_payloads = {}
    unresolved = 0
    for line in probe.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        payload = parse_probe_input_json(line)
        if payload is None:
            try:
                raw = json.loads(line)
            except json.JSONDecodeError:
                continue
            sentence = raw.get("sentence")
            if sentence:
                unresolved += 1
            continue
        raw = json.loads(line)
        input_payloads[raw["sentence"]] = payload

    results_by_mode = {mode: {} for mode in modes}
    for mode in modes:
        batch_rows = []
        for sentence in sentences:
            payload = input_payloads.get(sentence)
            if not payload:
                continue
            batch_rows.append({"row_id": sentence, "row_keys": payload["row_keys"]})
        input_jsonl = TEMP_DIR / f"ime_action_batch_{mode}.jsonl"
        input_jsonl.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in batch_rows), encoding="utf-8")
        action = run_capture([str(app_path), "ime-action-batch-probe", str(input_jsonl)], env=env_for_mode(mode), timeout=timeout * max(1, len(batch_rows)))
        if action is None:
            for row in batch_rows:
                results_by_mode[mode][row["row_id"]] = {
                    "returncode": -1,
                    "output": "",
                    "readings": "",
                    "has_composition": False,
                    "timeout": True,
                }
            continue
        for line in action.stdout.splitlines():
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                payload = json.loads(line)
            except json.JSONDecodeError:
                continue
            sentence = payload.get("row_id")
            if not sentence:
                continue
            results_by_mode[mode][sentence] = {
                "returncode": action.returncode,
                "output": (payload.get("text") or "").strip(),
                "readings": (payload.get("readings") or "").strip(),
                "has_composition": bool(payload.get("has_composition", False)),
                "timeout": False,
            }

    rows = {}
    for sentence in sentences:
        payload = input_payloads.get(sentence)
        if not payload:
            continue
        row = {
            "sentence": sentence,
            "key_sequence": payload["key_sequence"],
            "key_tokens": [token for token in payload["key_sequence"].split() if token and "?" not in token],
            "row_keys": payload["row_keys"],
            "probe_readings": payload["readings"],
            "paths": {},
        }
        negatives = []
        seen = set()
        for mode in modes:
            mode_payload = results_by_mode[mode].get(sentence, {
                "returncode": -1,
                "output": "",
                "readings": "",
                "has_composition": False,
                "timeout": True,
            })
            row["paths"][mode] = mode_payload
            output = mode_payload["output"]
            if not output or output == sentence or output in seen:
                continue
            seen.add(output)
            negatives.append({"mode": mode, "text": output})
        row["negatives"] = negatives
        rows[sentence] = row
    return rows, unresolved


def main() -> int:
    parser = argparse.ArgumentParser(description="Build sentence negatives from three real decode paths.")
    parser.add_argument("--input", required=True, help="Mother sample sentence txt")
    parser.add_argument("--output", required=True, help="Output grouped JSONL")
    parser.add_argument("--summary", required=True, help="Output summary JSON")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument(
        "--modes",
        default="traditional,hybrid",
        help="Comma separated modes: traditional,nn_only,hybrid",
    )
    args = parser.parse_args()
    modes = [mode.strip() for mode in args.modes.split(",") if mode.strip()]
    valid_modes = {"traditional", "nn_only", "hybrid"}
    invalid_modes = [mode for mode in modes if mode not in valid_modes]
    if not modes or invalid_modes:
        raise SystemExit(f"invalid modes: {','.join(invalid_modes or ['(empty)'])}")

    sentences = load_sentences(Path(args.input), args.limit)
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("", encoding="utf-8")

    collected = 0
    negative_cases = 0
    negative_outputs = 0
    resolved_failures = 0

    batch_rows, resolved_failures = collect_batch(sentences, timeout=args.timeout, modes=modes)
    for index, sentence in enumerate(sentences, start=1):
        row = batch_rows.get(sentence)
        if row is None:
            if index % 10 == 0 or index == len(sentences):
                print(
                    f"[{index}/{len(sentences)}] collected={collected} negative_cases={negative_cases} unresolved={resolved_failures}",
                    file=sys.stderr,
                )
            continue
        with output_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row, ensure_ascii=False) + "\n")
        collected += 1
        if row["negatives"]:
            negative_cases += 1
            negative_outputs += len(row["negatives"])
        if index % 10 == 0 or index == len(sentences):
            print(
                f"[{index}/{len(sentences)}] collected={collected} negative_cases={negative_cases} unresolved={resolved_failures}",
                file=sys.stderr,
            )

    summary = {
        "input": args.input,
        "limit": args.limit,
        "timeout": args.timeout,
        "modes": modes,
        "processed": len(sentences),
        "collected": collected,
        "negative_cases": negative_cases,
        "negative_outputs": negative_outputs,
        "unresolved": resolved_failures,
        "output": str(output_path),
    }
    Path(args.summary).write_text(json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
