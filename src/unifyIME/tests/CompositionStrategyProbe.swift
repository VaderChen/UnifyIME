import Foundation

/// 僅由隔離 Smoke 執行檔載入，不連接正式輸入法或使用者資料。
enum CompositionStrategyProbe {
    static func run() {
        var passed = 0
        var failed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) {
            guard condition() else { print("FAIL \(name)"); failed += 1; return }
            passed += 1
        }
        let chinese = ComposedSegment(languageID: "zh-Hant", reading: "ㄋㄧˇㄏㄠˇ", value: "你好", start: 0, length: 2)
        let english = ComposedSegment(languageID: "english-ime", reading: "everybody", value: "everybody", start: 2, length: 1)
        let expanded = ComposedSegment(languageID: "zh-Hant", reading: "ㄒㄧㄠˋ", value: "笑臉🙂", start: 3, length: 1)
        let segments = [chinese, english, expanded]
        check(CandidateScoringInput.precedingValues(segments: segments, before: 0).isEmpty, "句首沒有左文")
        check(CandidateScoringInput.precedingValues(segments: segments, before: 1) == ["你"], "中文詞內前綴")
        check(CandidateScoringInput.precedingValues(segments: segments, before: 3) == ["你好", "everybody"], "完整英文詞左文")
        check(CandidateScoringInput.precedingValues(segments: segments, before: 4) == ["你好", "everybody", "笑臉🙂"], "多字候選左文")
        check(CompositionPresentationBuilder.displayCursorLocation(forInsertionIndex: 4, segments: segments) == "你好everybody笑臉🙂".utf16.count, "多字候選 UTF-16 游標")

        let tokens = [InputToken(languageID: "zh-Hant", rawValue: "ㄕˋ")]
        let input = CandidateScoringInput.make(candidates: ["是", "事", "市", "式", "試", "室"], tokens: tokens, start: 0, length: 1, precedingValues: ["everybody"])!
        let ranker = CoreMLCandidateRanker()
        let originalMode = currentCandidateEngineMode
        defer { currentCandidateEngineMode = originalMode }
        for mode in CandidateEngineMode.allCases where mode.isSupported {
            currentCandidateEngineMode = mode
            let scalar = input.units.map { ranker.score(unit: $0, context: input.context) }
            let batch = ranker.scores(units: input.units, context: input.context)
            check(batch == scalar, "\(mode.rawValue) 批次／逐筆分數相同")
            let expected = zip(input.units, scalar).map { RankedCandidate(unit: $0.0, score: $0.1) }.sorted(by: candidateRanksBefore)
            check(ranker.ranked(units: input.units, context: input.context, limit: 3) .map(\.unit.surface) == Array(expected.prefix(3)).map(\.unit.surface), "\(mode.rawValue) 候選排序一致")
        }

        let round = Int(ProcessInfo.processInfo.environment["UNIFYIME_STRATEGY_ROUND"] ?? "0") ?? 0
        if round == 0 || round == 1 {
            let originalAlignment = currentCandidateCursorAlignment
            defer { currentCandidateCursorAlignment = originalAlignment }
            let path = ["你", "好", "嗎"].enumerated().map { ComposedSegment(languageID: "zh-Hant", reading: $0.element, value: $0.element, start: $0.offset, length: 1) }
            for alignment in [CandidateCursorAlignment.left, .right, .both] {
                currentCandidateCursorAlignment = alignment
                var state = UnifiedCompositionState(readings: ["你", "好", "嗎"], compositionCursorIndex: 1)
                let reachedEnd = UnifiedCompositionEngine.advanceCursorToNextSegment(segments: path, state: &state)
                let focus = CompositionPresentationBuilder.focusedSegment(forInsertionIndex: state.currentCompositionCursorIndex(), totalReadings: 3, in: path)
                check(!reachedEnd && focus?.start == 1, "第1輪：\(alignment.rawValue) 選字後只前進一詞")
            }
        }
        if round == 0 || round == 2 {
            currentCandidateCursorAlignment = .left
            var state = UnifiedCompositionState(readings: ["ㄋㄧˇ", "ㄏㄠˇ"], compositionCursorIndex: 2)
            check(UnifiedCompositionEngine.commitCandidate(index: 0, state: &state), "第2輪：確認整詞")
            let entries = UnifiedCompositionEngine.predict(state).presentation.candidateEntries
            if let index = entries.indices.first(where: { entries[$0].replacementKey.start == 1 && entries[$0].replacementKey.length == 1 && entries[$0].text != "好" && !entries[$0].isBopomofoLiteral }) {
                let expected = "你" + entries[index].text
                check(UnifiedCompositionEngine.commitCandidate(index: index, state: &state), "第2輪：重選詞內單字")
                check(UnifiedCompositionEngine.predict(state).presentation.markedText == expected, "第2輪：新選字不能被舊整詞鎖定覆蓋")
                let keys = Array(state.explicitLockedKeys)
                check(!keys.indices.contains { i in keys.indices.contains { j in i != j && keys[i].start < keys[j].start + keys[j].length && keys[j].start < keys[i].start + keys[i].length } }, "第2輪：確認範圍不互相重疊")
            } else { check(false, "第2輪：需有可重選的單字候選") }
        }
        if round == 0 || round == 3 {
            let language = "smoke-retry-" + UUID().uuidString
            let destination = fastChIMEDataDir.appendingPathComponent("user_freq_v2_\(language).tsv")
            try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            UserFrequencyStore.record(languageID: language, reading: "ㄕˋ", surface: "事")
            UserFrequencyStore.flush() // 目的地是目錄，模擬寫入失敗。
            try! FileManager.default.removeItem(at: destination)
            UserFrequencyStore.flush()
            let saved = (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
            check(saved.contains("ㄕˋ\t事\t1"), "第3輪：寫入失敗後仍能重試保存選字")
            let concurrent = "smoke-concurrent-" + UUID().uuidString
            DispatchQueue.concurrentPerform(iterations: 100) { index in
                UserFrequencyStore.record(languageID: concurrent, reading: "ㄕˋ", surface: "是")
                if index % 5 == 0 { UserFrequencyStore.flush() }
            }
            UserFrequencyStore.flush()
            let savedConcurrent = (try? String(contentsOf: fastChIMEDataDir.appendingPathComponent("user_freq_v2_\(concurrent).tsv"), encoding: .utf8)) ?? ""
            check(savedConcurrent.contains("ㄕˋ\t是\t100"), "第3輪：並行記錄與保存不遺失詞頻")
        }
        if round == 0 || round == 4 {
            let first = LexiconStore(overrideCharacterMap: ["ㄕˋ": ["是"]])
            let second = LexiconStore(overrideCharacterMap: ["ㄕˋ": ["事"]])
            check(first.resolveCandidates(for: "ㄕˋ").first == "是", "第4輪：第一詞庫覆寫優先序")
            check(second.resolveCandidates(for: "ㄕˋ").first == "事", "第4輪：第二詞庫不可沿用第一詞庫快取")
            check(first.resolveCandidates(for: "ㄕˋ").first == "是", "第4輪：交錯查詢仍維持各自優先序")
        }
        if round == 0 || round == 5 {
            var state = UnifiedCompositionState(readings: ["ㄋㄧˇ", "ㄏㄠˇ"], compositionCursorIndex: 1)
            UnifiedCompositionEngine.feed(token: "v", state: &state)
            check(UnifiedCompositionEngine.predict(state).presentation.markedText == "你ㄒ好", "第5輪：未完成音節顯示在詞內插入點")
            check(state.sourceInputs.joined() == "su3cl3" && state.pendingRawInput == "v", "第5輪：原鍵來源與未完成音節分開保存")
            UnifiedCompositionEngine.pressBackspace(state: &state)
            check(UnifiedCompositionEngine.predict(state).presentation.markedText == "你好", "第5輪：刪除未完成音節恢復原文")
            for (values, readings, expected) in [
                ("你好", ["ㄋㄧˇ", "ㄏㄠˇ"], "你ㄒ好"),
                ("你🙂好", ["ㄋㄧˇ", "ㄏㄠˇ"], "你ㄒ🙂好"),
                ("ㄋㄧˇㄏㄠˇ", ["ㄋㄧˇ", "ㄏㄠˇ"], "ㄋㄧˇㄒㄏㄠˇ"),
                ("一二", ["ㄧ", "ㄦˋ"], "一ㄒ二")
            ] {
                let key = CompositionSegmentKey(start: 0, length: readings.count, reading: readings.joined())
                var locked = UnifiedCompositionState(readings: readings, compositionCursorIndex: 1,
                    segmentOverrides: [key: values], explicitLockedKeys: [key])
                UnifiedCompositionEngine.feed(token: "v", state: &locked)
                check(UnifiedCompositionEngine.predict(locked).presentation.markedText == expected,
                    "第5輪：插入點保留鎖定、原注音、多字候選與數字（\(values)）")
                UnifiedCompositionEngine.pressBackspace(state: &locked)
                check(UnifiedCompositionEngine.predict(locked).presentation.markedText == values,
                    "第5輪：刪除插入音節後保留原鎖定（\(values)）")
            }

        }
        if round == 0 || round == 6 {
            let lexicon = SessionCtl.traditionalChineseProvider.lexicon
            let readings = ["ㄑㄩ", "ㄒㄧㄠ"]
            let matches = lexicon.compositionMatches(readings: readings)
            check(matches.contains { $0.surface == "取消" && $0.reading == "ㄑㄩˇㄒㄧㄠ" && $0.inferredToneCount == 1 }, "補調：召回最少缺調的取消")
            check(matches.contains { $0.surface == "取笑" && $0.inferredToneCount == 2 }, "補調：保留其他完整詞候選")
            check(!lexicon.resolveCandidates(for: readings.joined()).contains("取消"), "補調：精確查詢不變成跨調查詢")
            let protectedPhrase = UnifiedCompositionEngine.resolveWalk(["ㄕㄨ", "ㄖㄨˋ", "ㄈㄚˇ", "ㄊㄧㄝ", "ㄍㄟˇ", "ㄨㄛˇ"])
            check(protectedPhrase.map(\.value).joined() == "輸入法貼給我", "補調：不跨過精確完整詞的邊界")
            for (input, expected) in [
                (["ㄕㄨ", "ㄖㄨˋ", "ㄈㄚˇ", "ㄊㄧㄝ", "ㄍㄟˇ", "ㄨㄛˇ"], "輸入法貼給我"),
                (["ㄕˇ", "ㄩㄥˋ", "ㄑㄧㄢˊ", "ㄧㄠ", "ㄑㄩㄝˋ", "ㄖㄣˋ"], "使用前要確認")
            ] {
                let state = UnifiedCompositionState(readings: input)
                check(UnifiedCompositionEngine.predict(state).presentation.markedText == expected,
                    "補調：低頻詞不強迫合併正常單字（\(expected)）")
            }
            let scoring = CandidateScoringInput.make(matches: matches, tokens: readings.map { InputToken(languageID: "zh-Hant", rawValue: $0) }, start: 0, length: 2, precedingValues: [])!
            check(scoring.units.allSatisfy { $0.readingOrToken == readings.joined() }, "補調：評分保留原始讀音供詞頻學習")
            let heuristic = HeuristicCandidateRanker()
            check(heuristic.scores(units: scoring.units, context: scoring.context) == scoring.units.map { heuristic.score(unit: $0, context: scoring.context) }, "補調：批次與逐筆評分一致")

            check(!lexicon.compositionMatches(readings: ["ㄑㄩˋ", "ㄒㄧㄠ"]).contains { $0.surface == "取消" }, "補調：尊重明確聲調")
            check(lexicon.compositionMatches(readings: ["ㄍㄨㄥ", "ㄙ"]).allSatisfy { $0.inferredToneCount == 0 }, "補調：已存在精確詞時不補調")
            check(lexicon.compositionMatches(readings: ["ㄑㄩ"]).allSatisfy { $0.inferredToneCount == 0 }, "補調：不猜單字聲調")
            for (input, expected) in [(readings, "取消"), (["ㄉㄧㄢ", "ㄋㄠ"], "電腦"), (["ㄒㄧㄣ", "ㄎㄨ"], "辛苦"), (["ㄑㄩ", "ㄒㄧㄠˋ"], "取笑"), (["ㄑㄩˇ", "ㄒㄧㄠ"], "取消")] {
                var state = UnifiedCompositionState(readings: input)
                let prediction = UnifiedCompositionEngine.predict(state)
                check(prediction.presentation.markedText == expected, "補調：整詞組字（\(input.joined())）")
                check(prediction.presentation.candidateEntries.contains { $0.text == expected }, "補調：組字與選字使用同一候選（\(expected)）")
                check(UnifiedCompositionEngine.commitCandidate(index: 0, state: &state), "補調：確認整詞（\(expected)）")
                check(state.allReadings == input && state.sourceInputs == input.map(UnifiedCompositionState.sourceInput(for:)), "補調：保留原讀音與原始鍵位（\(expected)）")
            }
            let key = CompositionSegmentKey(start: 0, length: 1, reading: "ㄑㄩ")
            let state = UnifiedCompositionState(readings: readings, segmentOverrides: [key: "區"], explicitLockedKeys: [key])
            check(UnifiedCompositionEngine.predict(state).presentation.markedText == "區消", "補調：人工選字不被補詞覆蓋")
        }
        print("策略驗證：\(passed) 通過／\(failed) 失敗")
        if failed > 0 { exit(2) }
    }
}
