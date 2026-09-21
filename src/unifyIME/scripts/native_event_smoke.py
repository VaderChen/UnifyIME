#!/usr/bin/env python3
"""編譯隔離原生探針，驗證 IMK 事件、提交、游標與長混打；不安裝輸入法。"""
import argparse
import platform
import tempfile
import uuid
from pathlib import Path
import json
import subprocess

ROOT = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--output-dir", type=Path)
parser.add_argument("--strategy-only", action="store_true", help="只執行隔離策略驗證")
options = parser.parse_args()
artifact_root = ROOT / "artifacts" / "native-event-smoke"
artifact_root.mkdir(parents=True, exist_ok=True)
OUT = (options.output_dir or Path(tempfile.mkdtemp(prefix="run-", dir=artifact_root))).resolve()
OUT.mkdir(parents=True, exist_ok=True)
suite = "local.unifyime.native-smoke." + uuid.uuid4().hex
SRC = ROOT / 'src/unifyIME/Sources'
COPIES = OUT / 'isolated-sources'
COPIES.mkdir(exist_ok=True)

injected = r'''
    static func auditNative() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        while let line = readLine() {
            do {
                let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
                currentCandidateCursorAlignment = CandidateCursorAlignment(rawValue: row["mode"] as? String ?? "left") ?? .left
                shiftLanguageToggleMode = ShiftLanguageToggleMode(rawValue: row["toggle_mode"] as? String ?? "disabled") ?? .disabled
                shiftEnglishInputActive = false
                let client = NativeProbeClient()
                let ctl = SessionCtl(server: nil, delegate: nil, client: nil)!
                var states: [[String: Any]] = []
                var chosenText = ""
                func state(_ action: String, _ handled: Bool) -> [String: Any] {
                    let snap = ctl.snapshot()
                    return ["action": action, "handled": handled, "english": shiftEnglishInputActive, "text": snap.markedText,
                        "committed": client.inserted.joined(), "has_composition": ctl.hasComposition,
                        "readings": ctl.allReadings, "pending": ctl.currentReading,
                        "cursor": ctl.currentCompositionCursorIndex(), "utf16_cursor": snap.cursorLocation,
                        "chosen": chosenText, "candidate_mode": ctl.candidateMode, "locks": ctl.explicitLockedKeys.count,
                        "sources": ctl.unifiedState().sourceInputs,
                        "candidates": snap.candidateEntries.map(\.text)]
                }
                func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> Bool {
                    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                        characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
                    return ctl.handle(event, client: client)
                }
                for action in row["keys"] as! [String] {
                    var handled = true
                    if action.hasPrefix("flags:") {
                        let parts = action.split(separator: ":", omittingEmptySubsequences: false)
                        let names: [String: NSEvent.ModifierFlags] = ["shift": .shift, "alt": .option, "cmd": .command, "ctrl": .control, "caps": .capsLock, "fn": .function]
                        let flags = parts[2].split(separator: "+").reduce(NSEvent.ModifierFlags()) { $0.union(names[String($1)] ?? []) }
                        let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                            characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: UInt16(parts[1])!)!
                        handled = ctl.handle(event, client: client)
                    } else if action.hasPrefix("raw:") {
                        for c in action.dropFirst(4) {
                            handled = key(0, String(c))
                            if row["paced"] as? Bool == true { ctl.flushPendingRawReplay(); ctl.flushPendingMerge() }
                        }
                    } else if action.hasPrefix("caps-shift:") { handled = key(0, String(action.dropFirst(11)), [.capsLock, .shift])
                    } else if action.hasPrefix("shortcut:") { handled = key(0, String(action.dropFirst(9)), .command)
                    } else if action.hasPrefix("caps:") { handled = key(0, String(action.dropFirst(5)), .capsLock)
                    } else if action.hasPrefix("shift:") { handled = key(0, String(action.dropFirst(6)), .shift)
                    } else if action == "flush" { ctl.flushPendingRawReplay(); ctl.flushPendingMerge()
                    } else if action == "choose-alternative" {
                        let entries = ctl.snapshot().candidateEntries
                        if let index = entries.indices.dropFirst().first(where: {
                            !entries[$0].isBopomofoLiteral && entries[$0].replacementReadings == nil && entries[$0].text != entries[0].text
                        }) {
                            chosenText = entries[index].text
                            handled = ctl.applyCandidateSelection(index: index, advance: false) != .failed
                        } else { handled = false }
                    } else if action == "commit" { ctl.commitComposition(client)
                    } else if action == "deactivate" { ctl.deactivateServer(client)
                    } else if action == "command-enter" { handled = ctl.didCommand(by: #selector(NSResponder.insertNewline(_:)), client: client)
                    } else if action == "wait" { RunLoop.current.run(until: Date().addingTimeInterval(0.55))
                    } else {
                        let codes: [String: UInt16] = ["left":123,"right":124,"home":115,"end":119,"down":125,"up":126,"esc":53,"enter":36,"space":49,"backspace":51,"delete":117]
                        if let code = codes[action] { handled = key(code) }
                    }
                    states.append(state(action, handled))
                }
                ctl.pendingRawReplayWorkItem?.cancel()
                ctl.pendingMergeWorkItem?.cancel()
                let result: [String: Any] = ["row_id": row["row_id"] ?? "", "states":states]
                print(String(data: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
                fflush(stdout)
            } catch { fputs("audit error: \(error)\n", stderr); exit(2) }
        }
    }
'''

files = []
for folder in [SRC, ROOT/'src/phoneticIME/Sources', ROOT/'src/englishIME/Sources']:
    for path in sorted(folder.rglob('*.swift')):
        text = path.read_text()
        if path == SRC/'main.swift':
            needle = 'final class SessionCtl: IMKInputController, CandidateSelectionHandler {'
            assert needle in text
            text = text.replace(needle, needle + injected, 1)
        elif path == SRC/'App/AppEntry.swift':
            text = text.replace('func runUnifyIMEAppEntry() {', 'func runUnifyIMEAppEntry() {\n    if CommandLine.arguments.contains("audit-native") { SessionCtl.auditNative(); return }\n    if CommandLine.arguments.contains("audit-strategy") { CompositionStrategyProbe.run(); return }', 1)
        elif path == SRC/'App/RuntimeSupport.swift':
            needle = 'FileManager.default.homeDirectoryForCurrentUser\n    .appendingPathComponent("Library/Application Support/UnifyIME", isDirectory: true)'
            assert needle in text
            text = text.replace(needle, 'URL(fileURLWithPath: '+json.dumps(str(OUT/'isolated-data'))+', isDirectory: true)')
            text = text.replace('Bundle.main.bundleIdentifier ?? "com.vader.inputmethod.UnifyIME"', json.dumps(suite))
        # 隔離分散式 UI 通知，避免影響現用輸入法的 helper。
        text = text.replace('com.vader.unifyime.state', 'local.unifyime.audit.state')
        text = text.replace('com.vader.unifyime.caretMode', 'local.unifyime.audit.caretMode')
        dest = COPIES/path.name
        dest.write_text(text)
        files.append(str(dest))
client = (ROOT/'src/unifyIME/tests/NativeProbeClient.swift').read_text()
(COPIES/'Client.swift').write_text(client)
files.append(str(COPIES/'Client.swift'))
strategy = ROOT/'src/unifyIME/tests/CompositionStrategyProbe.swift'
(COPIES/strategy.name).write_text(strategy.read_text())
files.append(str(COPIES/strategy.name))
args = ['swiftc','-D','UNIFYIME_CLI','-parse-as-library','-module-name','UnifyIMEIsolated','-target',f'{platform.machine()}-apple-macos13.0']
for name in ['AppKit','Carbon','CoreML','InputMethodKit','WebKit']:
    args += ['-framework',name]
with (OUT/'isolated-build.log').open('w') as log:
    result = subprocess.run(args + files + ['-o',str(OUT/'UnifyIMEIsolated')], stdout=log, stderr=subprocess.STDOUT)
print('isolated build:', result.returncode)
if result.returncode:
    print((OUT/'isolated-build.log').read_text())
if result.returncode:
    raise SystemExit(result.returncode)

from pathlib import Path
import subprocess
import json
import os

env=dict(os.environ,UNIFYIME_DISABLE_COREML_RANKER='1',UNIFYIME_DISABLE_COREML_LISTWISE_RANKER='1',UNIFYIME_RUNTIME_TRACE_ENABLED='0',UNIFYIME_SELECTION_LOG_ENABLED='0')
strategy_result = subprocess.run([str(OUT/'UnifyIMEIsolated'), 'audit-strategy'], env=env, text=True, capture_output=True, timeout=120)
(OUT/'strategy.log').write_text(strategy_result.stdout + strategy_result.stderr)
assert strategy_result.returncode == 0, (strategy_result.stdout, strategy_result.stderr)
print(strategy_result.stdout.strip())
if options.strategy_only:
    raise SystemExit(0)
rows=[]
for mode in ['left','right','both']:
    for paced in [False, True]:
        for cursor in range(3):
            keys=['raw:su3cl3','flush','home']+['right']*cursor
            keys += ['raw:su3','flush','backspace','esc','end','enter']
            rows.append({'row_id':f'edit-{mode}-{paced}-{cursor}','mode':mode,'paced':paced,'keys':keys,'cursor':cursor})
        for raw,expected in [('wu0fu4verygood','天氣 very good'),('verygood','very good')]:
            for end in ['enter','deactivate','commit','command-enter']:
                rows.append({'row_id':f'commit-{mode}-{paced}-{raw}-{end}','mode':mode,'paced':paced,'keys':['raw:'+raw,end], 'expected':expected})
for mode in ['left','right','both']:
    rows.append({'row_id':f'caps-{mode}','mode':mode,'keys':['raw:su3cl3','flush','caps:A'],'expected':'你好a'})
rows += [
    {'row_id':'length-limit','keys':['raw:'+'wu0fu4'*19+'very','flush','raw:good','flush','enter'],'expected':'天氣'*19+' very good'},
    {'row_id':'wait-then-enter','keys':['raw:wu0fu4verygood','wait','enter'],'expected':'天氣 very good'},
]
for mode in ['left', 'right', 'both']:
    for action, expected in [('caps:A', '天氣 very gooda'), ('caps-shift:A', '天氣 very good'),
                             ('shift:A', '天氣 very goodA'), ('shortcut:a', '天氣 very good')]:
        rows.append(dict(row_id=f'passthrough-{mode}-{action}', mode=mode,
                         keys=['raw:wu0fu4verygood', action], expected=expected))
    rows.append(dict(row_id=f'home-immediate-{mode}', mode=mode,
                     keys=['raw:wu0fu4verygood', 'home', 'end', 'enter'], expected='天氣 very good'))
    rows.append(dict(row_id=f'home-insert-{mode}', mode=mode,
                     keys=['raw:wu0fu4verygood', 'home', 'raw:su3', 'end', 'enter'], expected='你天氣 very good'))
    rows.append(dict(row_id=f'undo-mixed-{mode}', mode=mode,
                     keys=['raw:wu0fu4verygood', 'backspace', 'esc', 'enter'], expected='天氣 very good'))
for paced in [False, True]:
    for raw, expected in [('everybody'*15, ('everybody '*15).strip()),
                          ('wu0fu4'*40+'verygood', '天氣'*40+' very good'),
                          ('verygood'+'wu0fu4'*21, 'very good '+'天氣'*21),
                          ('wu0fu4verygood'*10, ('天氣 very good '*10).strip())]:
        rows.append(dict(row_id=f'long-{paced}-{len(rows)}', paced=paced,
                         keys=['raw:'+raw, 'enter'], expected=expected))
# 單按左右修飾鍵、連按、雙側同按及組合鍵，直接走正式 IMK 事件處理。
for mode, accepted in [('disabled', []), ('left', [56]), ('right', [60]), ('all', [56,60]), ('leftAlt', [58]), ('rightAlt', [61]), ('leftControl', [59]), ('rightControl', [62])]:
    for code, flag in [(56,'shift'), (60,'shift'), (58,'alt'), (61,'alt'), (59,'ctrl'), (62,'ctrl')]:
        down, up = f'flags:{code}:{flag}', f'flags:{code}:'
        toggles = code in accepted
        rows.append(dict(row_id=f'toggle-{mode}-{code}', toggle_mode=mode,
                         keys=[down,up,down,up], english_states=[False,toggles,toggles,False]))
        if toggles:
            rows.append(dict(row_id=f'toggle-repeat-{mode}-{code}', toggle_mode=mode,
                             keys=[down,down,up,up], english_states=[False,False,True,True]))
            rows.append(dict(row_id=f'toggle-composition-{mode}-{code}', toggle_mode=mode,
                             keys=['raw:su3cl3',down,up], expected='你好', english_states=[False,False,True]))
            rows.append(dict(row_id=f'toggle-key-chord-{mode}-{code}', toggle_mode=mode,
                             keys=[down,'raw:a',up], english_states=[False,False,False]))
            other = {56:60,60:56,58:61,61:58,59:62,62:59}[code]
            rows.append(dict(row_id=f'toggle-both-sides-{mode}-{code}', toggle_mode=mode,
                             keys=[down,f'flags:{other}:{flag}',up], english_states=[False,False,False]))
            for modifier, modifier_code in [('cmd',55),('ctrl',59),('caps',57),('fn',63),('alt',58),('shift',56)]:
                if modifier == flag: continue
                rows.append(dict(row_id=f'toggle-chord-{mode}-{code}-{modifier}', toggle_mode=mode,
                    keys=[down,f'flags:{modifier_code}:{flag}+{modifier}',f'flags:{modifier_code}:{flag}',up],
                    english_states=[False]*4))
# 英文複數候選不可吃掉下一個中文音節的首鍵；同時驗證真正的複數仍保留。
for word in ['automation', 'operation', 'application', 'project', 'system', 'model', 'test']:
    for paced in [False, True]:
        for prefix, surface in [('', ''), ('wu0fu4', '天氣 ')]:
            rows.append(dict(row_id=f'boundary-{word}-{paced}-{bool(prefix)}', paced=paced,
                keys=['raw:'+prefix+word+'s/6', 'enter'], expected=surface+word+' 能'))
        rows.append(dict(row_id=f'plural-{word}-{paced}', paced=paced,
            keys=['raw:'+word+'s', 'enter'], expected=word+'s'))
# 人工選字之後追加／刪除其他內容，確認已選文字不被重新辨識覆蓋。
for mode in ['left', 'right', 'both']:
    for paced in [False, True]:
        for action in ['enter', 'commit', 'deactivate', 'command-enter']:
            rows.append(dict(row_id=f'selection-{mode}-{paced}-{action}', mode=mode, paced=paced,
                keys=['raw:su3cl3', 'flush', 'choose-alternative', 'end', 'raw:wu0fu4', 'flush', 'backspace', action], preserve_selection=True))
# 第一聲末音節在英文區段前，以完成音節的候選副本作整詞評估。
for raw, text in [('zpvu', '分析'), ('ej/n', '公司'), ('wj/5', '通知')]:
    for paced in [False, True]:
        for prefix in ['', 'everybody']:
            rows.append(dict(row_id=f'first-tone-{text}-{paced}-{bool(prefix)}', paced=paced,
                keys=['raw:'+prefix+raw+'verygood', 'enter'], expected=('everybody ' if prefix else '')+text+' very good'))
# 詞中尚未完成的音節必須留在插入點；刪除後恢復原詞與提交內容。
for mode in ['left', 'right', 'both']:
    for paced in [False, True]:
        for cursor, pending in enumerate(['ㄒ你好', '你ㄒ好', '你好ㄒ']):
            rows.append(dict(row_id=f'pending-insert-{mode}-{paced}-{cursor}', mode=mode, paced=paced,
                keys=['raw:su3cl3', 'flush', 'home']+['right']*cursor+
                    ['raw:v', 'flush', 'backspace', 'end', 'enter'], pending_expected=pending))
(OUT/'native-matrix.jsonl').write_text(''.join(json.dumps(r,ensure_ascii=False)+'\n' for r in rows))
r=subprocess.run([str(OUT/'UnifyIMEIsolated'),'audit-native'],env=env,text=True,input=(OUT/'native-matrix.jsonl').read_text(),capture_output=True,timeout=600)
(OUT/'native-matrix-results.jsonl').write_text(r.stdout)
(OUT/'native-matrix.stderr').write_text(r.stderr)
assert r.returncode==0,(r.returncode,r.stderr)
actual={row['row_id']:row for row in map(json.loads,r.stdout.splitlines())}
summary=[]
for row in rows:
    states=actual[row['row_id']]['states']; last=states[-1]
    if row['row_id'].startswith('edit-'):
        inserted=['ㄋㄧˇ','ㄏㄠˇ'];inserted.insert(row['cursor'],'ㄋㄧˇ')
        flushes=[s for s in states if s['action']=='flush']
        after_backspace=next(s for s in states if s['action']=='backspace')
        after_esc=next(s for s in states if s['action']=='esc')
        passed=flushes[-1]['readings']==inserted and after_backspace['readings']==['ㄋㄧˇ','ㄏㄠˇ'] and after_esc['readings']==inserted and not last['has_composition']
    elif row.get('pending_expected'):
        pending = [s for s in states if s['action'] == 'flush'][-1]
        restored = next(s for s in states if s['action'] == 'backspace')
        passed = (pending['text'] == row['pending_expected'] and pending['pending'] == 'ㄒ'
                  and restored['text'] == '你好' and last['committed'] == '你好' and not last['has_composition'])
    elif row.get('expected'):
        passed=last['committed']==row['expected'] and not last['has_composition']
    elif row.get('preserve_selection'):
        chosen = next(state for state in states if state['action'] == 'choose-alternative')
        passed = chosen['handled'] and bool(chosen['chosen']) and chosen['locks'] > 0 and last['committed'] == chosen['text'] + '天' and not last['has_composition']
    elif 'english_states' in row:
        passed=True
    else:
        passed=None
    if 'english_states' in row:
        passed = passed and [state['english'] for state in states] == row['english_states']
    item={'row_id':row['row_id'],'passed':passed,'committed':last['committed']}
    summary.append(item)
    if passed is not True: print(json.dumps(item,ensure_ascii=False))
(OUT/'native-matrix-summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
print('TOTAL',len(rows),'PASS',sum(s['passed'] is True for s in summary),'FAIL',sum(s['passed'] is False for s in summary),'OBSERVE',sum(s['passed'] is None for s in summary))

print("驗證產物：", OUT)
raise SystemExit(0 if all(item["passed"] for item in summary) else 2)
