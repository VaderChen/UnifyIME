import Foundation

/// 由 performance_smoke.py 注入隔離執行檔，同一探針可量測修改前後來源。
enum PerformanceProbe {
    private struct Digest {
        var value: UInt64 = 14_695_981_039_346_656_037
        mutating func add(_ text: String) {
            for byte in text.utf8 {
                value = (value ^ UInt64(byte)) &* 1_099_511_628_211
            }
            value = (value ^ 255) &* 1_099_511_628_211
        }
    }

    static func run(_ scenario: String) {
        if scenario.hasPrefix("function-") {
            FunctionPerformanceProbe.run(scenario)
            return
        }
        let started = DispatchTime.now().uptimeNanoseconds
        var result: [String: Any] = ["scenario": scenario]
        var digest = Digest()
        switch scenario {
        case "english":
            let engine = EnglishIMEEngine()
            digest.add(engine.resolveCandidates(for: "pro").joined(separator: "\t"))
            result["cold_ms"] = elapsed(since: started)
            let warm = DispatchTime.now().uptimeNanoseconds
            let readings = ["pro", "project", "a", "app", "apple", "test", "everyb", "very", "good", "openai", "mac", "unavailableword"]
            for index in 0..<12_000 {
                digest.add(engine.resolveCandidates(for: readings[index % readings.count]).joined(separator: "\t"))
            }
            result["lookup_ms"] = elapsed(since: warm)
        case "chinese":
            // 同時保留多個詞庫與統計使用者，反映共用資料是否真的節省記憶體。
            let stores = (0..<3).map { _ in LexiconStore(overrideCharacterMap: [:]) }
            let stats = (0..<3).map { _ in LexiconStore.loadPhraseContextStats() }
            result["cold_ms"] = elapsed(since: started)
            let warm = DispatchTime.now().uptimeNanoseconds
            let readings = Array(stores[0].commonCharacterMap.keys.sorted().prefix(512))
            for index in 0..<12_000 {
                digest.add(stores[index % stores.count].resolveCandidates(for: readings[index % readings.count]).joined(separator: "\t"))
            }
            result["lookup_ms"] = elapsed(since: warm)
            withExtendedLifetime((stores, stats)) {
                result["phrase_readings"] = stores[0].phraseCandidateMap.count
                result["stats_surfaces"] = stats[0].surfaceWeights.count
            }
        case "english-contract":
            let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("src/englishIME/Resources/english_words.tsv")
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { fatalError("缺少英文詞庫") }
            var keys = Set<String>()
            for line in text.split(whereSeparator: \.isNewline) {
                guard let token = line.split(separator: "\t", omittingEmptySubsequences: false).first else { continue }
                var prefix = ""
                for character in token {
                    prefix.append(character)
                    keys.insert(prefix)
                }
            }
            let engine = EnglishIMEEngine()
            for key in keys.sorted() {
                digest.add(key)
                digest.add(EnglishIMEEngine.canExtendToken(key) ? "1" : "0")
                digest.add(EnglishIMEEngine.exactSurfaceCandidates(for: key).joined(separator: "\t"))
                digest.add(engine.resolveCandidates(for: key).joined(separator: "\t"))
            }
            result["keys"] = keys.count
        case "chinese-contract":
            let store = LexiconStore(overrideCharacterMap: [:])
            let keys = Set(store.commonCharacterMap.keys).union(store.phraseCandidateMap.keys)
            for key in keys.sorted() {
                digest.add(key)
                digest.add(store.resolveCandidates(for: key).joined(separator: "\t"))
            }
            for prefix in store.readingPrefixes.sorted() { digest.add(prefix) }
            let stats = LexiconStore.loadPhraseContextStats()
            for key in stats.readingSurfaceWeights.keys.sorted() {
                digest.add(key)
                for surface in stats.readingSurfaceWeights[key]!.keys.sorted() {
                    digest.add(surface)
                    digest.add(String(stats.readingSurfaceWeights[key]![surface]!))
                }
                digest.add(String(stats.readingCandidateCounts[key] ?? 0))
                digest.add(String(stats.readingBestLengths[key] ?? 0))
            }
            result["keys"] = keys.count
        case "ranking":
            let input = CandidateScoringInput.make(candidates: ["是", "事", "市", "式", "試", "室"],
                tokens: [InputToken(languageID: "zh-Hant", rawValue: "ㄕˋ")], start: 0, length: 1,
                precedingValues: ["everybody"])!
            let ranker = CoreMLCandidateRanker()
            let scalar = input.units.map { ranker.score(unit: $0, context: input.context) }
            precondition(scalar.allSatisfy(\.isFinite))
            precondition(scalar == ranker.scores(units: input.units, context: input.context))
            let expected = zip(input.units, scalar).map { RankedCandidate(unit: $0.0, score: $0.1) }
                .sorted(by: candidateRanksBefore).prefix(3).map(\.unit.surface)
            precondition(ranker.ranked(units: input.units, context: input.context, limit: 3).map(\.unit.surface) == expected)
            for score in scalar { digest.add(String(score)) }
            result["model_loaded"] = ranker.isModelLoaded
        case "diagnostics":
            var evaluations = 0
            func message() -> String { evaluations += 1; return "診斷求值測試" }
            imeDebugLog(message())
            appendRuntimeTrace(message())
            appendFocusedTrace(message())
            precondition(evaluations == (isRuntimeTraceEnabled ? 3 : 0), "診斷訊息只在啟用時求值一次")
            digest.add(String(evaluations))
        default:
            fatalError("未知效能情境：\(scenario)")
        }
        result["elapsed_ms"] = elapsed(since: started)
        result["digest"] = String(digest.value, radix: 16)
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }

    private static func elapsed(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
}
