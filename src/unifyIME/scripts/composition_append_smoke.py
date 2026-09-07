#!/usr/bin/env python3
"""檢查逐鍵追加前後的組字文字及 Enter 提交；不將預期文字傳給解碼器。"""
import argparse
import json
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', type=Path, default=ROOT / 'bin/cli/UnifyIMECLI')
    args = parser.parse_args()
    cases = [json.loads(line) for line in (ROOT / 'src/unifyIME/tests/composition_append_cases.jsonl').read_text().splitlines() if line.strip()]
    requests = []
    expected = {}
    for case in cases:
        keys = ['raw:' + character for character in case['raw']]
        checkpoints = dict(case.get('checkpoints', {}))
        checkpoints[str(len(keys))] = case['expected']
        for count, text in checkpoints.items():
            row_id = f"{case['name']}／第{count}鍵"
            requests.append({'row_id': row_id, 'row_keys': keys[:int(count)]})
            expected[row_id] = (text, True)
        row_id = case['name'] + '／送出'
        requests.append({'row_id': row_id, 'row_keys': keys + ['enter']})
        expected[row_id] = (case['expected'], False)
    with tempfile.TemporaryDirectory(prefix='composition-append-') as directory:
        source = Path(directory) / 'actions.jsonl'
        source.write_text(''.join(json.dumps(row, ensure_ascii=False) + '\n' for row in requests))
        result = subprocess.run([str(args.cli.resolve()), 'ime-action-batch-replay', str(source)], cwd=ROOT, text=True, capture_output=True, timeout=180)
    if result.returncode:
        print(result.stdout, end='')
        print(result.stderr, end='')
        return result.returncode
    actual = {}
    for line in result.stdout.splitlines():
        row = json.loads(line)
        row_id = row.get('row_id')
        if row_id in actual or row_id not in expected:
            raise RuntimeError('測試結果識別碼重複或未知：' + str(row_id))
        actual[row_id] = row
    failures = 0
    for row_id, (text, has_composition) in expected.items():
        row = actual.get(row_id, {})
        passed = not row.get('error') and row.get('text') == text and row.get('has_composition') is has_composition
        failures += not passed
        print(f"{'通過' if passed else '失敗'} {row_id}：預期={text!r} 實際={row.get('text')!r}")
    print(f'共 {len(expected)} 項，通過 {len(expected) - failures}，失敗 {failures}')
    return 2 if failures else 0


if __name__ == '__main__':
    raise SystemExit(main())
