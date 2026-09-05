import Foundation

extension SessionCtl {
    struct SelfTestCase {
        let sentence: String
        let readings: [String]?
    }

    struct GoldSegment {
        let text: String
        let reading: String
    }

    struct RankerSample: Codable {
        let sample_id: String
        let case_id: String
        let step_id: Int
        let source: String
        let tags: [String]
        let language_id: String
        let all_tokens: [String]
        let combined_token: String
        let focused_token: String
        let preceding_values: [String]
        let following_tokens: [String]
        let candidate_surface: String
        let candidate_reading_or_token: String
        let span_start: Int
        let span_length: Int
        let provider_score: Double
        let base_rank: Int
        let label: Double
        let sample_weight: Double
    }

    struct DatasetDumpResult {
        let totalCases: Int
        let resolvedCases: Int
        let sampleCount: Int
    }

    struct SentenceBeamPath {
        let segments: [ComposedSegment]
        let localScore: Double
    }

    static let datasetCandidateRanker = HeuristicCandidateRanker()

    struct RankerABRecord: Codable {
        let sentence: String
        let segment_index: Int
        let segment_text: String
        let reading: String
        let candidates: [String]
        let heuristic_scores: [Double]
        let coreml_scores: [Double]
        let heuristic_order: [String]
        let coreml_order: [String]
    }

    static func runSelfTest(cases: [SelfTestCase]) -> Int32 {
        var failures = 0
        for (idx, testCase) in cases.enumerated() {
            let sentence = testCase.sentence
            let readings = testCase.readings
            let output = readings.map(simulateIncrementalInput(readings:)) ?? "（無法反查讀音）"
            let ok = output == sentence
            if !ok { failures += 1 }
            print("[\(idx + 1)] \(ok ? "PASS" : "FAIL")")
            print("句子: \(sentence)")
            if let readings {
                print("讀音: \(readings.joined(separator: " / "))")
                print("鍵序: \(keySequence(for: readings))")
            } else {
                print("讀音: （無法反查）")
            }
            print("輸出: \(output)")
            if !ok { print("差異: 預期=\(sentence) 實際=\(output)") }
            print("---")
        }
        print("總結: \(cases.count - failures)/\(cases.count) 通過")
        return failures == 0 ? 0 : 2
    }

    static func defaultSelfTestCases() -> [SelfTestCase] {
        let reverseMap = buildReverseLexicon()
        let sentences = [
            "我今天想試試看這個輸入法",
            "你現在可以正常打字聊天嗎",
            "這個功能看起來已經很穩定了",
            "請幫我把候選詞排序調整一下",
            "我們等一下再回頭修選字視窗",
            "如果有問題就直接把畫面貼給我",
            "這次改完之後反應速度快很多了",
            "他說明天早上要先去公司開會",
            "我希望連續輸入時不要一直卡住",
            "試試看變這個字現在能不能選到"
        ]
        return sentences.map { SelfTestCase(sentence: $0, readings: reverseReadings(for: $0, reverseMap: reverseMap)) }
    }

    static func buildReverseLexicon() -> [String: [String]] {
        var reverse: [String: [String]] = [:]
        func add(_ text: String, reading: String) {
            guard !text.isEmpty, !reading.isEmpty else { return }
            var list = reverse[text, default: []]
            if !list.contains(reading) { list.append(reading) }
            reverse[text] = list
        }
        for (text, readings) in traditionalChineseProvider.buildReverseLexicon() {
            for reading in readings { add(text, reading: reading) }
        }
        return reverse
    }

    private static func reverseReadingPreferenceScore(text: String, reading: String) -> Int {
        let candidates = resolveCandidates(for: reading)
        if let index = candidates.firstIndex(of: text) {
            return index
        }
        return Int.max / 4
    }

    static func reverseReadings(for sentence: String, reverseMap: [String: [String]]) -> [String]? {
        struct ReverseChoice {
            let readings: [String]
            let segmentCount: Int
            let preferenceScore: Int
        }

        let chars = Array(sentence)
        let count = chars.count
        var best: [ReverseChoice?] = Array(repeating: nil, count: count + 1)
        best[count] = ReverseChoice(readings: [], segmentCount: 0, preferenceScore: 0)

        for start in stride(from: count - 1, through: 0, by: -1) {
            var choice: ReverseChoice? = nil
            for end in stride(from: count, through: start + 1, by: -1) {
                let text = String(chars[start..<end])
                guard let readings = reverseMap[text], let tail = best[end] else { continue }
                for reading in readings {
                    let candidate = ReverseChoice(
                        readings: [reading] + tail.readings,
                        segmentCount: 1 + tail.segmentCount,
                        preferenceScore: reverseReadingPreferenceScore(text: text, reading: reading) + tail.preferenceScore
                    )
                    if choice == nil
                        || candidate.segmentCount < choice!.segmentCount
                        || (candidate.segmentCount == choice!.segmentCount && candidate.preferenceScore < choice!.preferenceScore) {
                        choice = candidate
                    }
                }
            }
            best[start] = choice
        }
        return best[0]?.readings
    }

    static func reverseSegments(for sentence: String, reverseMap: [String: [String]]) -> [GoldSegment]? {
        struct ReverseSegmentChoice {
            let segments: [GoldSegment]
            let segmentCount: Int
            let preferenceScore: Int
        }

        let chars = Array(sentence)
        let count = chars.count
        var best: [ReverseSegmentChoice?] = Array(repeating: nil, count: count + 1)
        best[count] = ReverseSegmentChoice(segments: [], segmentCount: 0, preferenceScore: 0)

        for start in stride(from: count - 1, through: 0, by: -1) {
            var choice: ReverseSegmentChoice? = nil
            for end in stride(from: count, through: start + 1, by: -1) {
                let text = String(chars[start..<end])
                guard let readings = reverseMap[text], let tail = best[end] else { continue }
                for reading in readings {
                    let candidate = ReverseSegmentChoice(
                        segments: [GoldSegment(text: text, reading: reading)] + tail.segments,
                        segmentCount: 1 + tail.segmentCount,
                        preferenceScore: reverseReadingPreferenceScore(text: text, reading: reading) + tail.preferenceScore
                    )
                    if choice == nil
                        || candidate.segmentCount < choice!.segmentCount
                        || (candidate.segmentCount == choice!.segmentCount && candidate.preferenceScore < choice!.preferenceScore) {
                        choice = candidate
                    }
                }
            }
            best[start] = choice
        }
        return best[0]?.segments
    }

    static func inverseBopomofoMap() -> [String: String] {
        var inverse: [String: String] = [:]
        for (key, value) in bopomofoMap where inverse[value] == nil {
            inverse[value] = key
        }
        return inverse
    }

    static func keySequence(for readings: [String]) -> String {
        let inverse = inverseBopomofoMap()
        return readings.map { reading in
            reading.map { scalar in
                inverse[String(scalar)] ?? "?"
            }.joined()
        }.joined(separator: " ")
    }

    static func keyTokens(for readings: [String]) -> [String] {
        let inverse = inverseBopomofoMap()
        return readings.flatMap { reading in
            reading.map { scalar in
                inverse[String(scalar)] ?? "?"
            }
        }
    }

    static func simulateIncrementalInput(readings: [String]) -> String {
        var committed: [String] = []
        var current = ""

        for reading in readings {
            for scalar in reading {
                let incoming = String(scalar)
                if shouldFinalizeCurrentReading(current: current, incoming: incoming) {
                    if !current.isEmpty {
                        committed.append(current)
                        current = ""
                    }
                }
                current.append(incoming)
            }
        }

        if !current.isEmpty {
            committed.append(current)
        }
        return UnifiedCompositionEngine.resolveCommittedText(allReadings: committed)
    }

    static func splitReadingIntoSyllables(_ reading: String) -> [String] {
        var syllables: [String] = []
        var current = ""

        for scalar in reading {
            let incoming = String(scalar)
            if shouldFinalizeCurrentReading(current: current, incoming: incoming) {
                if !current.isEmpty {
                    syllables.append(current)
                    current = ""
                }
            }
            current.append(incoming)
        }

        if !current.isEmpty {
            syllables.append(current)
        }
        return syllables
    }

    static func overridePhraseLockedMap(for allReadings: [String]) -> [Int: ComposedSegment] {
        guard !allReadings.isEmpty else { return [:] }
        let phraseEntries: [(syllables: [String], reading: String, value: String)] = overrideCharacterMap.compactMap { reading, values in
            guard let value = values.first else { return nil }
            let syllables = splitReadingIntoSyllables(reading)
            guard syllables.count > 1 else { return nil }
            return (syllables, reading, value)
        }.sorted {
            if $0.syllables.count != $1.syllables.count { return $0.syllables.count > $1.syllables.count }
            return $0.reading.count > $1.reading.count
        }

        var locked: [Int: ComposedSegment] = [:]
        var index = 0
        while index < allReadings.count {
            var matched: (syllables: [String], reading: String, value: String)?
            for entry in phraseEntries {
                let end = index + entry.syllables.count
                guard end <= allReadings.count else { continue }
                if Array(allReadings[index..<end]) == entry.syllables {
                    matched = entry
                    break
                }
            }
            if let matched {
                locked[index] = ComposedSegment(
                    languageID: traditionalChineseProvider.languageID,
                    reading: matched.reading,
                    value: matched.value,
                    start: index,
                    length: matched.syllables.count
                )
                index += matched.syllables.count
            } else {
                index += 1
            }
        }
        return locked
    }

    static func generateDynamicSelfTestCases(batchSize: Int = 10, minChars: Int = 15, maxChars: Int = 20) -> [SelfTestCase] {
        struct Token {
            let text: String
            let reading: String
        }

        var tokens: [Token] = []
        for reading in traditionalChineseProvider.lexicon.phraseCandidateMap.keys.sorted() {
            guard let top = resolveCandidates(for: reading).first,
                  top.count >= 2 && top.count <= 5,
                  isDisplayableCandidate(top) else { continue }
            tokens.append(Token(text: top, reading: reading))
        }
        for reading in traditionalChineseProvider.lexicon.commonCharacterMap.keys.sorted() {
            guard let top = resolveCandidates(for: reading).first,
                  top.count == 1,
                  isDisplayableCandidate(top) else { continue }
            tokens.append(Token(text: top, reading: reading))
        }
        if tokens.isEmpty { return defaultSelfTestCases() }

        var generator = SystemRandomNumberGenerator()
        var cases: [SelfTestCase] = []
        for _ in 0..<batchSize {
            var sentence = ""
            var readings: [String] = []
            var guardCount = 0
            while sentence.count < minChars && guardCount < 200 {
                guardCount += 1
                guard let token = tokens.randomElement(using: &generator) else { break }
                if sentence.count + token.text.count > maxChars { continue }
                sentence += token.text
                readings.append(token.reading)
            }
            if sentence.count < minChars {
                continue
            }
            cases.append(SelfTestCase(sentence: sentence, readings: readings))
        }
        return cases.isEmpty ? defaultSelfTestCases() : cases
    }

    static func generateShortWordTestCases(batchSize: Int = 10) -> [SelfTestCase] {
        var tokens: [SelfTestCase] = []
        for reading in traditionalChineseProvider.lexicon.phraseCandidateMap.keys.sorted() {
            guard let top = resolveCandidates(for: reading).first,
                  (2...4).contains(top.count),
                  isDisplayableCandidate(top) else { continue }
            tokens.append(SelfTestCase(sentence: top, readings: [reading]))
        }
        if tokens.isEmpty { return defaultSelfTestCases() }
        var generator = SystemRandomNumberGenerator()
        return Array(tokens.shuffled(using: &generator).prefix(batchSize))
    }

    static func generateSingleCharacterTestCases(batchSize: Int = 500) -> [SelfTestCase] {
        var tokens: [SelfTestCase] = []
        for reading in traditionalChineseProvider.lexicon.commonCharacterMap.keys.sorted() {
            guard let top = resolveCandidates(for: reading).first,
                  top.count == 1,
                  isDisplayableCandidate(top) else { continue }
            tokens.append(SelfTestCase(sentence: top, readings: [reading]))
        }
        if tokens.isEmpty { return defaultSelfTestCases() }
        var generator = SystemRandomNumberGenerator()
        return Array(tokens.shuffled(using: &generator).prefix(batchSize))
    }

    static func generateShortSentenceTestCases(batchSize: Int = 10) -> [SelfTestCase] {
        generateDynamicSelfTestCases(batchSize: batchSize, minChars: 15, maxChars: 20)
    }

    static func generateShortArticleCase(targetChars: Int = 300) -> SelfTestCase {
        let sentences = generateDynamicSelfTestCases(batchSize: 30, minChars: 15, maxChars: 20)
        var chosen: [SelfTestCase] = []
        var total = 0
        for item in sentences {
            chosen.append(item)
            total += item.sentence.count
            if total >= targetChars { break }
        }
        let sentence = chosen.map(\.sentence).joined()
        let readings = chosen.compactMap(\.readings).flatMap { $0 }
        return SelfTestCase(sentence: sentence, readings: readings)
    }

    static func generateLongArticleTestCases(batchSize: Int = 5, targetChars: Int = 300) -> [SelfTestCase] {
        (0..<batchSize).map { _ in generateShortArticleCase(targetChars: targetChars) }
    }

    static func generateFullSelfTestCases() -> [SelfTestCase] {
        let singles = generateSingleCharacterTestCases(batchSize: 500)
        let words = generateShortWordTestCases(batchSize: 500)
        let sentences = generateShortSentenceTestCases(batchSize: 300)
        let articles = generateLongArticleTestCases(batchSize: 5, targetChars: 300)
        return singles + words + sentences + articles
    }
}
