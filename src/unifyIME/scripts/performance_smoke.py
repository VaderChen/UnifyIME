#!/usr/bin/env python3
"""隔離量測詞庫、逐鍵混打的耗時與峰值 RSS，並比對完整詞庫候選契約。"""
import argparse
import hashlib
import importlib.util
import json
import os
import platform
import re
import statistics
import subprocess
import tempfile
import time
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output-dir", type=Path)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--compare-with", type=Path)
    parser.add_argument("--skip-build", action="store_true")
    parser.add_argument("--build-only", action="store_true")
    parser.add_argument("--functions-only", action="store_true", help="只量測函式層級契約與工作負載")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs 必須大於零")
    artifact_root = ROOT / "artifacts/performance-smoke"
    artifact_root.mkdir(parents=True, exist_ok=True)
    out = (args.output_dir or Path(tempfile.mkdtemp(prefix="run-", dir=artifact_root))).resolve()
    out.mkdir(parents=True, exist_ok=True)
    binary = out / "UnifyIMEPerformance"
    if not args.skip_build:
        copies = out / "isolated-sources"
        copies.mkdir(exist_ok=True)
        suite = "local.unifyime.performance." + uuid.uuid4().hex
        files = []
        hashes = {}
        for folder in ["src/unifyIME/Sources", "src/phoneticIME/Sources", "src/englishIME/Sources"]:
            for path in sorted((args.source_root / folder).rglob("*.swift")):
                if path.name.startswith("._"):
                    continue
                text = path.read_text()
                hashes[str(path.relative_to(args.source_root))] = hashlib.sha256(text.encode()).hexdigest()
                if path.name == "AppEntry.swift":
                    needle = "func runUnifyIMEAppEntry() {"
                    assert needle in text
                    text = text.replace(needle, needle + '\n    if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "performance-probe" { PerformanceProbe.run(CommandLine.arguments[2]); return }', 1)
                if path.name == "RuntimeSupport.swift":
                    needle = 'FileManager.default.homeDirectoryForCurrentUser\n    .appendingPathComponent("Library/Application Support/UnifyIME", isDirectory: true)'
                    assert needle in text
                    text = text.replace(needle, 'URL(fileURLWithPath: ' + json.dumps(str(out / "isolated-data")) + ', isDirectory: true)')
                    text = text.replace('Bundle.main.bundleIdentifier ?? "com.vader.inputmethod.UnifyIME"', json.dumps(suite))
                text = text.replace("com.vader.unifyime.state", suite + ".state").replace("com.vader.unifyime.caretMode", suite + ".caretMode")
                dest = copies / path.name
                dest.write_text(text)
                files.append(str(dest))
        files.append(str(ROOT / "src/unifyIME/tests/PerformanceProbe.swift"))
        files.append(str(ROOT / "src/unifyIME/tests/FunctionPerformanceProbe.swift"))
        command = ["swiftc", "-D", "UNIFYIME_CLI", "-parse-as-library", "-module-name", "UnifyIMEPerformance", "-target", f"{platform.machine()}-apple-macos13.0"]
        command += ["-O", "-whole-module-optimization"] if args.configuration == "release" else ["-Onone"]
        for framework in ["AppKit", "Carbon", "CoreML", "InputMethodKit", "WebKit"]:
            command += ["-framework", framework]
        with (out / "build.log").open("w") as log:
            subprocess.run(command + files + ["-o", str(binary)], stdout=log, stderr=subprocess.STDOUT, check=True)
        (out / "build.json").write_text(json.dumps({"configuration": args.configuration, "sources": hashes}, indent=2))
    if args.build_only:
        print("隔離執行檔：", binary)
        return

    env = dict(os.environ, UNIFYIME_DISABLE_COREML_RANKER="1", FASTCHIME_DISABLE_COREML_RANKER="1",
               UNIFYIME_DISABLE_COREML_LISTWISE_RANKER="1", UNIFYIME_RUNTIME_TRACE_ENABLED="0",
               FASTCHIME_RUNTIME_TRACE_ENABLED="0", UNIFYIME_SELECTION_LOG_ENABLED="0",
               UNIFYIME_PROFILE="0", FASTCHIME_PROFILE="0")
    spec = importlib.util.spec_from_file_location("mixed_smoke", ROOT / "src/unifyIME/scripts/mixed_live_smoke.py")
    mixed = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mixed)
    cases = [(name, raw, expected, commit) for name, raw, expected, commit in mixed.CASES if not name.startswith("delete-")]
    rows = [{"row_id": name, "row_keys": ["raw:" + c for c in raw] + (["enter"] if commit else [])} for name, raw, _, commit in cases]
    input_path = out / "mixed-input.jsonl"
    input_path.write_text("".join(json.dumps(row, ensure_ascii=False) + "\n" for row in rows))

    summary = {"configuration": json.loads((out / "build.json").read_text())["configuration"],
               "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "scenarios": {}}
    scenarios = (["function-top-k", "function-features", "function-frequency", "function-vocabulary", "function-walk"]
                 if args.functions_only else ["english", "chinese", "mixed", "english-contract", "chinese-contract", "ranking"])
    for scenario in scenarios:
        samples = []
        for iteration in range(args.runs if scenario in ["english", "chinese", "mixed"] or args.functions_only else 1):
            command = [str(binary), "ime-action-batch-replay", str(input_path)] if scenario == "mixed" else [str(binary), "performance-probe", scenario]
            start = time.perf_counter()
            result = subprocess.run(["/usr/bin/time", "-l"] + command, cwd=ROOT, env=env, text=True, capture_output=True, timeout=300)
            elapsed = (time.perf_counter() - start) * 1000
            (out / f"{scenario}-{iteration}.stdout").write_text(result.stdout)
            (out / f"{scenario}-{iteration}.stderr").write_text(result.stderr)
            result.check_returncode()
            match = re.search(r"(\d+)\s+maximum resident set size", result.stderr)
            if not match:
                raise RuntimeError("缺少峰值 RSS 量測")
            if scenario == "mixed":
                outputs = [json.loads(line) for line in result.stdout.splitlines() if line.startswith("{")]
                by_id = {row["row_id"]: row for row in outputs}
                assert len(by_id) == len(cases)
                for name, _, expected, commit in cases:
                    row = by_id[name]
                    assert row["text"] == expected and row["has_composition"] is (not commit) and not row.get("error"), row
                payload = {"digest": hashlib.sha256(json.dumps(outputs, sort_keys=True, ensure_ascii=False).encode()).hexdigest(), "cases": len(cases)}
            else:
                payload = json.loads(result.stdout)
            payload.update(wall_ms=elapsed, peak_rss_bytes=int(match[1]))
            samples.append(payload)
        assert len({sample["digest"] for sample in samples}) == 1, scenario
        numeric = {key: statistics.median(sample[key] for sample in samples) for key in samples[0]
                   if key.endswith("_ms") or key == "peak_rss_bytes"}
        summary["scenarios"][scenario] = {"digest": samples[0]["digest"], "median": numeric, "samples": samples}
        print(scenario, json.dumps(numeric), flush=True)
    (out / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2))
    if args.compare_with:
        baseline = json.loads(args.compare_with.read_text())
        for scenario, result in summary["scenarios"].items():
            assert result["digest"] == baseline["scenarios"][scenario]["digest"], f"結果不同：{scenario}"
        print("修改前後的候選、排序與混打輸出全部相同。")
    print("量測結果：", out / "summary.json")


if __name__ == "__main__":
    main()
