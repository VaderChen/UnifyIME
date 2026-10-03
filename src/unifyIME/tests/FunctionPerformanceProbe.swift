import Foundation

/// 相同探針分別編譯修改前後來源；浮點特徵以位元比對，避免只比較顯示文字。
enum FunctionPerformanceProbe {
    private struct Digest {
        var value: UInt64 = 14_695_981_039_346_656_037
        mutating func add(_ bits: UInt64) { value = (value ^ bits) &* 1_099_511_628_211 }
        mutating func add(_ string: String) {
            for byte in string.utf8 { add(UInt64(byte)) }
            add(255)
        }
        mutating func add(_ values: [Double]) { for value in values { add(value.bitPattern) } }
    }
    private struct FixtureRanker: UnifiedCandidateRanker {
        func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double { unit.providerScore }
    }
    private static func elapsed(_ start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }
    static func run(_ scenario: String) {
        var digest = Digest()
        var result: [String: Any] = ["scenario": scenario]
        let started = DispatchTime.now().uptimeNanoseconds
        let surfaces = ["", "是", "事情", "專案", "中English", "abc", "かな", "𠀀", "﨑", "a\u{301}", "👨‍👩‍👧‍👦", "ㄕˋ", "更多中文字與ABC0123456789"]
        let tokens = (0..<18).map { InputToken(languageID: $0 % 4 == 0 ? "en" : "zh-Hant",
            rawValue: ["ㄕˋ", "ㄑㄧㄥˊ", "ㄓㄨㄢ", "project", "", "ㄅㄚ˙"][$0 % 6]) }
        let input = CandidateScoringInput.make(candidates: surfaces, tokens: tokens, start: 4,
            length: 2, precedingValues: ["", "很早", "", "previous", "事情", "中English", ""])!
        switch scenario {
        case "function-top-k":
            let ranker = FixtureRanker()
            let units = (0..<4_000).map { index in
                CandidateUnit(languageID: "zh-Hant", surface: "候選\(index)", readingOrToken: "ㄕˋ",
                    spanStart: 0, spanLength: 1, providerScore: Double((index &* 7919) % 113), baseRank: index % 17)
            }
            for count in [0, 1, 19, 20, 100, units.count] {
                var fixture = Array(units.prefix(count))
                fixture.append(contentsOf: [Double.nan, .infinity, -.infinity, -0.0].enumerated().map { i, score in
                    CandidateUnit(languageID: "en", surface: "特殊\(i)", readingOrToken: "", spanStart: 0,
                        spanLength: 0, providerScore: score, baseRank: 0)
                })
                for limit in [-1, 0, 1, 2, 7, 20, count + 10] {
                    let reference = Array(fixture.filter { $0.providerScore.isFinite }.map {
                        RankedCandidate(unit: $0, score: $0.providerScore)
                    }.sorted(by: candidateRanksBefore).prefix(max(0, limit)))
                    let actual = ranker.ranked(units: fixture, context: input.context, limit: limit)
                    precondition(actual == reference, "Top-K 的平手順序、非有限分數或邊界不同")
                    for item in actual { digest.add(item.unit.surface); digest.add(item.score.bitPattern) }
                }
            }
            let warm = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<300 {
                for item in ranker.ranked(units: units, context: input.context, limit: 20) {
                    digest.add(item.unit.surface)
                }
            }
            result["selection_ms"] = elapsed(warm)
        case "function-features":
            let encoder = RankingFeatureEncoder()
            let listwise = ListwiseFeatureEncoder()
            let sentence = SentenceFeatureEncoder()
            var inputs: [CandidateScoringInput] = []
            for start in 0..<tokens.count {
                for length in 1...min(8, tokens.count - start) {
                    let matches = surfaces.enumerated().map { rank, surface in
                        LexiconStore.CompositionMatch(surface: surface, reading: "ㄕˋ", inferredToneCount: rank % 3)
                    }
                    let fixture = CandidateScoringInput.make(matches: matches, tokens: tokens, start: start,
                        length: length, precedingValues: Array((surfaces + ["", ""]).prefix(start)))!
                    inputs.append(fixture)
                    for unit in fixture.units {
                        digest.add(unit.surface); digest.add(unit.readingOrToken); digest.add(unit.lexiconReading ?? "nil")
                        digest.add(UInt64(unit.inferredToneCount)); digest.add(UInt64(unit.spanStart))
                    }
                    digest.add(fixture.context.precedingValues.joined(separator: "|"))
                }
            }
            precondition(CandidateScoringInput.make(candidates: [], tokens: tokens, start: -1, length: 1, precedingValues: []) == nil)
            precondition(CandidateScoringInput.make(candidates: [], tokens: tokens, start: 18, length: 1, precedingValues: []) == nil)
            _ = encoder.encode(unit: input.units[1], context: input.context)
            var warm = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<8 {
                for fixture in inputs {
                    for unit in fixture.units {
                        for contract in [CandidateFeatureContract.legacySegmentsV1, .boundedSegmentsV2] {
                            digest.add(encoder.encode(unit: unit, context: fixture.context, contract: contract).values)
                        }
                    }
                }
            }
            result["ranking_features_ms"] = elapsed(warm)
            warm = DispatchTime.now().uptimeNanoseconds
            for index in 0..<2_000 {
                let fixture = inputs[index % inputs.count]
                let units = Array((fixture.units + fixture.units).prefix(index % 27))
                let encoded = listwise.encode(units: units, context: fixture.context)
                for value in encoded.tokenIDs { digest.add(UInt64(UInt32(bitPattern: value))) }
                for value in encoded.tokenTypes { digest.add(UInt64(UInt32(bitPattern: value))) }
                for value in encoded.numericFeatures + encoded.candidateMask { digest.add(UInt64(value.bitPattern)) }
            }
            result["listwise_features_ms"] = elapsed(warm)
            warm = DispatchTime.now().uptimeNanoseconds
            for index in 0..<4_000 {
                let segments = surfaces.prefix(index % (surfaces.count + 1)).enumerated().map { offset, surface in
                    ComposedSegment(languageID: "zh-Hant", reading: tokens[offset].rawValue, value: surface, start: offset, length: 1)
                }
                let path = SentenceCandidatePath(text: segments.map(\.value).joined(), readings: segments.map(\.reading),
                    segments: segments, localScore: Double(index % 7))
                digest.add(sentence.encode(path: path, context: SentenceRerankerContext(
                    committedLeftContext: Array(surfaces.suffix(index % 5)), committedRightContext: Array(surfaces.prefix(index % 4)))))
            }
            result["sentence_features_ms"] = elapsed(warm)
        case "function-frequency":
            let language = "function-probe"
            try! FileManager.default.createDirectory(at: fastChIMEDataDir, withIntermediateDirectories: true)
            var rows = (0..<5_000).flatMap { reading in (0..<10).map { "reading\(reading)\t字\($0)\t\($0 + 1)" } }
            rows += ["duplicate\t重複\t2", "duplicate\t重複\t9"]
            try! rows.joined(separator: "\n").write(to: fastChIMEDataDir.appendingPathComponent("user_freq_v2_\(language).tsv"), atomically: true, encoding: .utf8)
            precondition(UserFrequencyStore.frequency(languageID: language, reading: "duplicate", surface: "重複") == 9)
            UserFrequencyStore.record(languageID: language, reading: "DUPLICATE", surface: "重複")
            precondition(UserFrequencyStore.frequency(languageID: language, reading: "duplicate", surface: "重複") == 9)
            var warm = DispatchTime.now().uptimeNanoseconds
            for index in 0..<2_000 {
                UserFrequencyStore.record(languageID: language, reading: "READING\(index % 5_000)", surface: "字\(index % 10)")
            }
            result["record_ms"] = elapsed(warm)
            warm = DispatchTime.now().uptimeNanoseconds
            for index in 0..<20_000 {
                digest.add(UInt64(UserFrequencyStore.frequency(languageID: language, reading: "reading\(index % 5_000)", surface: "字\(index % 10)")))
            }
            result["frequency_ms"] = elapsed(warm)
            for index in 0..<5_000 {
                let map = UserFrequencyStore.frequencyMap(languageID: language, reading: "reading\(index)")
                for surface in map.keys.sorted() { digest.add(surface); digest.add(UInt64(map[surface]!)) }
            }
            UserFrequencyStore.flush()
        case "function-vocabulary":
            try! FileManager.default.createDirectory(at: fastChIMEDataDir, withIntermediateDirectories: true)
            let entries = (0..<5_000).map { PersonalVocabularyStore.Entry(syllables: ["ㄕˋ"],
                surface: String(UnicodeScalar(0x4e00 + $0)!), priority: $0 % 50) }
            let initial = PersonalVocabularyStore.Document(revision: 0, entries: entries)
            try! JSONEncoder().encode(initial).write(to: PersonalVocabularyStore.url, options: .atomic)
            let changes = (0..<100).map { index in (entry: PersonalVocabularyStore.Entry(syllables: ["ㄕˋ"],
                surface: entries[index * 47].surface, priority: 123), remove: index % 3 == 0) }
            var expected = entries
            for change in changes {
                expected.removeAll { $0.reading == change.entry.reading && $0.surface == change.entry.surface }
                if !change.remove { expected.append(change.entry) }
            }
            let warm = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<10 {
                let actual = try! PersonalVocabularyStore.batch(revision: 0, changes: changes, dryRun: true)
                precondition(actual.document.entries.map(\.surface) == expected.map(\.surface))
                precondition(actual.document.entries.map(\.priority) == expected.map(\.priority))
                for entry in actual.document.entries { digest.add(entry.surface); digest.add(UInt64(entry.priority)) }
            }
            result["batch_ms"] = elapsed(warm)
            precondition((try! PersonalVocabularyStore.read()).revision == 0)
            let saved = try! PersonalVocabularyStore.batch(revision: 0, changes: changes, dryRun: false)
            precondition(saved.document.revision == 1 && PersonalVocabularyStore.loadedRevision == 1)
            do { _ = try PersonalVocabularyStore.batch(revision: 0, changes: changes, dryRun: false); preconditionFailure("舊 revision 不得寫入") } catch {}
            digest.add(PersonalVocabularyStore.candidates(reading: "ㄕˋ", base: ["是", "是", "事"]).joined(separator: "|"))
        case "function-walk":
            let lexicon = LexiconStore(overrideCharacterMap: [:])
            let walker = ReadingWalker(lexicon: lexicon, ranker: HeuristicCandidateRanker(), languageID: "zh-Hant")
            let readings = [["ㄓㄨㄥ", "ㄨㄣˊ"], ["ㄓㄨㄥ", "ㄨㄣ"], ["ㄕˋ", "ㄑㄧㄥˊ"],
                ["ㄓㄨㄢ", "ㄢˋ"], ["ㄒㄧㄠ", "ㄌㄩˋ"], ["ㄐㄧˋ", "ㄧˋ", "ㄊㄧˇ"],
                ["ㄋㄧˇ", "ㄏㄠˇ", "ㄓㄨㄥ", "ㄨㄣ", "ㄕˋ", "ㄑㄧㄥˊ"], ["", "abc"], []]
            let cold = DispatchTime.now().uptimeNanoseconds
            for values in readings { _ = lexicon.compositionMatches(readings: values) }
            result["tone_index_ms"] = elapsed(cold)
            let warm = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<30 {
                for values in readings {
                    for match in lexicon.compositionMatches(readings: values) {
                        digest.add(match.surface); digest.add(match.reading); digest.add(UInt64(match.inferredToneCount))
                    }
                    let inputTokens = values.map { InputToken(languageID: "zh-Hant", rawValue: $0) }
                    for segment in walker.resolveWalk(inputTokens) {
                        digest.add(segment.value); digest.add(segment.reading)
                        digest.add(UInt64(segment.start)); digest.add(UInt64(segment.length)); digest.add(UInt64(segment.rawLength))
                    }
                }
            }
            result["walk_ms"] = elapsed(warm)
            for raw in ["", "su3cl3", "abc", "project", "a\u{301}", "👨‍👩‍👧‍👦", "ㄕˋ", " abc"] {
                digest.add(SessionCtl.mapKeySequence(raw) ?? "nil")
            }
        default: fatalError("未知函式探針：\(scenario)")
        }
        result["elapsed_ms"] = elapsed(started)
        result["digest"] = String(digest.value, radix: 16)
        print(String(data: try! JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), encoding: .utf8)!)
    }
}
