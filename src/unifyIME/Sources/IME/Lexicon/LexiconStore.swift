import Foundation

struct LexiconStore {
    struct PhraseContextStats {
        let surfaceWeights: [String: Double]
        let readingSurfaceWeights: [String: [String: Double]]
        let readingCandidateCounts: [String: Int]
        let readingBestLengths: [String: Int]

        static let empty = PhraseContextStats(
            surfaceWeights: [:],
            readingSurfaceWeights: [:],
            readingCandidateCounts: [:],
            readingBestLengths: [:]
        )
    }

    private static let toneMarks = CharacterSet(charactersIn: "ˇˋˊ˙")
    private static let allowedCandidatePunctuation = CharacterSet(charactersIn: "，。、！？：；（）「」『』《》〈〉—…．·")
    // 資源在程序生命週期內不變，共用底層資料；覆寫與查詢快取仍屬於各實例。
    private static let sourceCommonCharacterMap = loadCommonCharacterMap()
    private static let sourcePhraseCandidateMap = loadPhraseCandidateMap()
    private static let sourceReadingPrefixes = loadReadingPrefixes(
        phraseCandidateMap: sourcePhraseCandidateMap, commonCharacterMap: sourceCommonCharacterMap)
    private static let phraseContextStats = readPhraseContextStats()
    private static let sourceCharacterReadings: [Character: Set<String>] = {
        var result: [Character: Set<String>] = [:]
        for (reading, values) in sourceCommonCharacterMap {
            for value in values where value.count == 1 && isDisplayableCandidate(value) {
                result[value.first!, default: []].insert(reading)
            }
        }
        return result
    }()
    /// 不同覆寫表不可共用讀音查詢結果。
    private let candidateCache = BoundedLRUCache<String, [String]>(capacity: 512)
    struct CompositionMatch {
        let surface: String
        let reading: String
        let inferredToneCount: Int
    }

    private final class ToneCompletionIndex {
        private let lock = NSLock()
        private var index: [String: [String]]?

        func readings(for base: String, build: () -> [String: [String]]) -> [String] {
            lock.lock()
            defer { lock.unlock() }
            if index == nil { index = build() }
            return index?[base] ?? []
        }
    }
    private let toneCompletionIndex = ToneCompletionIndex()
    let overrideCharacterMap: [String: [String]]
    let phraseCandidateMap: [String: [String]]
    let commonCharacterMap: [String: [String]]
    let readingPrefixes: Set<String>

    private static func resourceURL(named name: String, ext: String) -> URL? {
        if let bundled = Bundle.main.url(forResource: name, withExtension: ext) {
            return bundled
        }

        let fm = FileManager.default
        let relativePath = "Resources/\(name).\(ext)"
        var candidates: [URL] = []

        if let executableURL = Bundle.main.executableURL {
            let macOSDir = executableURL.deletingLastPathComponent()
            let contentsDir = macOSDir.deletingLastPathComponent()
            candidates.append(contentsDir.appendingPathComponent(relativePath))
            candidates.append(macOSDir.appendingPathComponent("\(name).\(ext)"))
        }

        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        candidates.append(cwd.appendingPathComponent(relativePath))
        candidates.append(cwd.appendingPathComponent("src/unifyIME/\(relativePath)"))
        candidates.append(cwd.appendingPathComponent("fastChIME/\(relativePath)"))

        var ancestor = cwd
        for _ in 0..<5 {
            candidates.append(ancestor.appendingPathComponent(relativePath))
            candidates.append(ancestor.appendingPathComponent("fastChIME/\(relativePath)"))
            ancestor.deleteLastPathComponent()
        }

        for candidate in candidates {
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    init(overrideCharacterMap: [String: [String]]) {
        phraseCandidateMap = Self.sourcePhraseCandidateMap
        let sourceCommon = Self.sourceCommonCharacterMap
        self.overrideCharacterMap = Self.validatedOverrides(overrideCharacterMap,
            common: sourceCommon, phrases: phraseCandidateMap)
        // 通過驗證後才合併，反查、前綴與中英辨識也只會看到合法配對。
        commonCharacterMap = self.overrideCharacterMap.reduce(into: sourceCommon) { result, entry in
            result[entry.key] = entry.value + (result[entry.key] ?? []).filter { !entry.value.contains($0) }
        }
        var prefixes = Self.sourceReadingPrefixes
        for reading in self.overrideCharacterMap.keys
            where sourceCommon[reading] == nil && phraseCandidateMap[reading] == nil {
            Self.insertProperPrefixes(of: reading, into: &prefixes)
        }
        readingPrefixes = prefixes
    }

    func resolveCandidates(for buffer: String) -> [String] {
        if let cached = candidateCache.value(for: buffer) {
            return PersonalVocabularyStore.candidates(reading: buffer, base: cached)
        }

        var merged: [String] = []
        var seen = Set<String>()
        appendCandidates(forReading: buffer, into: &merged, seen: &seen)
        // 沒有調號代表第一聲，不代表可跨調或以鄰鍵補字。
        // 未完成音節由組字狀態處理，不能污染精確讀音查詢。
        let filtered = merged.filter(Self.isDisplayableCandidate(_:))
        var resolved = filtered.isEmpty ? (merged.isEmpty ? [buffer] : merged) : filtered
        if isSingleSyllableReading(buffer) {
            let singles = resolved.filter { $0.count == 1 }
            let longer = resolved.filter { $0.count > 1 }
            if !singles.isEmpty {
                resolved = singles + longer
            }
        }
        candidateCache.store(resolved, for: buffer)
        return PersonalVocabularyStore.candidates(reading: buffer, base: resolved)
    }

    /// 多音節分詞只接受精確來源詞條，但不限定來源必須是 phrase_map。
    func compositionCandidates(reading: String, syllableCount: Int) -> [String] {
        guard syllableCount > 0 else { return [] }
        if syllableCount == 1 {
            return resolveCandidates(for: reading).filter { $0.count == 1 }
        }
        var base: [String] = []
        var seen = Set<String>()
        appendCandidates(forReading: reading, into: &base, seen: &seen)
        return PersonalVocabularyStore.candidates(reading: reading, base: base).filter {
            $0.count == syllableCount && Self.isDisplayableCandidate($0)
        }
    }

    /// 精確整詞不存在時，才補足未標聲調；不更改音節、明確聲調或單字查詢。
    func compositionMatches(readings: [String], allowToneCompletion: Bool = true) -> [CompositionMatch] {
        let reading = readings.joined()
        let exact = compositionCandidates(reading: reading, syllableCount: readings.count)
        if !exact.isEmpty {
            return exact.map { CompositionMatch(surface: $0, reading: reading, inferredToneCount: 0) }
        }
        guard allowToneCompletion, (2...8).contains(readings.count),
              readings.contains(where: { !containsToneMark($0) }),
              readings.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy {
                  (0x3105...0x3129).contains($0.value) || Self.toneMarks.contains($0)
              } }) else { return [] }
        let bases = readings.map(normalizeReading)
        let variants = toneCompletionIndex.readings(for: bases.joined()) {
            var keys = Set<String>()
            for map in [phraseCandidateMap, commonCharacterMap] {
                for (key, values) in map where values.contains(where: {
                    (2...8).contains($0.count) && $0.unicodeScalars.allSatisfy(HanCharacter.contains)
                }) { keys.insert(key) }
            }
            return Dictionary(grouping: keys, by: normalizeReading).mapValues { $0.sorted() }
        }
        var matches: [CompositionMatch] = []
        for variant in variants {
            let syllables = SessionCtl.splitReadingIntoSyllables(variant)
            guard syllables.count == readings.count else { continue }
            var distance = 0
            var compatible = true
            for index in readings.indices {
                guard normalizeReading(syllables[index]) == bases[index],
                      !containsToneMark(readings[index]) || readings[index] == syllables[index] else {
                    compatible = false
                    break
                }
                if readings[index] != syllables[index] { distance += 1 }
            }
            guard compatible, distance > 0 else { continue }
            for surface in compositionCandidates(reading: variant, syllableCount: readings.count) {
                matches.append(CompositionMatch(surface: surface, reading: variant, inferredToneCount: distance))
            }
        }
        // 先以最少補調數選擇同詞異讀；最終仍由共用詞頻及上下文評分決定。
        matches.sort {
            if $0.inferredToneCount != $1.inferredToneCount { return $0.inferredToneCount < $1.inferredToneCount }
            if $0.reading != $1.reading { return $0.reading < $1.reading }
            return $0.surface < $1.surface
        }
        var seen = Set<String>()
        return matches.filter { seen.insert($0.surface).inserted }
    }

    func normalizeReading(_ reading: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in reading.unicodeScalars where !Self.toneMarks.contains(scalar) {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    func containsToneMark(_ reading: String) -> Bool {
        reading.unicodeScalars.contains { Self.toneMarks.contains($0) }
    }

    func canExtendToLongerPhrase(_ reading: String) -> Bool {
        readingPrefixes.contains(reading)
    }

    static func isDisplayableCandidate(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        for scalar in candidate.unicodeScalars {
            if HanCharacter.contains(scalar) { continue }
            if allowedCandidatePunctuation.contains(scalar) { continue }
            return false
        }
        return true
    }

    private static func loadCommonCharacterMap() -> [String: [String]] {
        var result = [String: [String]]()
        if let url = resourceURL(named: "common_map", ext: "tsv"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }
                let key = String(parts[0])
                let value = String(parts[1])
                if !key.isEmpty, !value.isEmpty {
                    if result[key]?.contains(value) != true {
                        result[key, default: []].append(value)
                    }
                }
            }
        }
        return result
    }

    /// 覆寫只能調整合法讀音的來源順位，不得建立去調或錯配別名。
    /// 新短語可依每個字的正式讀音組成；整詞讀音優先保留詞庫中的異讀與變調。
    static func validatedOverrides(_ overrides: [String: [String]]) -> [String: [String]] {
        validatedOverrides(overrides, common: sourceCommonCharacterMap, phrases: sourcePhraseCandidateMap)
    }

    private static func validatedOverrides(_ overrides: [String: [String]],
        common: [String: [String]], phrases: [String: [String]]) -> [String: [String]] {
        guard !overrides.isEmpty else { return [:] }
        let characterReadings = sourceCharacterReadings
        return overrides.reduce(into: [:]) { result, entry in
            let (reading, values) = entry
            let valid = values.filter { value in
                if common[reading]?.contains(value) == true || phrases[reading]?.contains(value) == true { return true }
                guard !value.isEmpty, value.count <= 8 else { return false }
                var suffixes: Set<String> = [reading]
                for character in value {
                    var next: Set<String> = []
                    for suffix in suffixes {
                        for syllable in characterReadings[character] ?? [] where suffix.hasPrefix(syllable) {
                            next.insert(String(suffix.dropFirst(syllable.count)))
                        }
                    }
                    suffixes = next
                    if suffixes.isEmpty { return false }
                }
                return suffixes.contains("")
            }
            if !valid.isEmpty { result[reading] = valid }
        }
    }

    private static func loadPhraseCandidateMap() -> [String: [String]] {
        var weighted = [String: [(phrase: String, weight: Double)]]()
        guard let url = resourceURL(named: "phrase_map", ext: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return [:]
        }
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let reading = String(parts[0])
            let phrase = String(parts[1])
            guard !reading.isEmpty, !phrase.isEmpty else { continue }
            let weight = parts.count >= 3 ? Double(parts[2]) ?? 0.0 : 0.0
            if weighted[reading]?.contains(where: { $0.phrase == phrase }) != true {
                weighted[reading, default: []].append((phrase: phrase, weight: weight))
            }
        }
        // Sort each reading's candidates by weight descending
        var result = [String: [String]]()
        for (reading, entries) in weighted {
            result[reading] = entries
                .sorted { $0.weight > $1.weight }
                .map(\.phrase)
        }
        return result
    }

    static func loadPhraseContextStats() -> PhraseContextStats {
        phraseContextStats
    }

    private static func readPhraseContextStats() -> PhraseContextStats {
        guard let url = resourceURL(named: "phrase_map", ext: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .empty
        }

        var surfaceWeights = [String: Double]()
        var readingSurfaceWeights = [String: [String: Double]]()
        var readingCandidateCounts = [String: Int]()
        var readingBestLengths = [String: Int]()

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let reading = String(parts[0])
            let phrase = String(parts[1])
            guard !reading.isEmpty, !phrase.isEmpty else { continue }

            let rawWeight = parts.count >= 3 ? Double(parts[2]) ?? 1.0 : 1.0
            guard rawWeight.isFinite else { continue }
            let weight = max(rawWeight, 1.0)
            surfaceWeights[phrase] = max(surfaceWeights[phrase] ?? 0.0, weight)
            readingSurfaceWeights[reading, default: [:]][phrase] = max(readingSurfaceWeights[reading]?[phrase] ?? 0, weight)
            readingCandidateCounts[reading, default: 0] += 1
            readingBestLengths[reading] = max(readingBestLengths[reading] ?? 0, phrase.count)
        }

        return PhraseContextStats(
            surfaceWeights: surfaceWeights,
            readingSurfaceWeights: readingSurfaceWeights,
            readingCandidateCounts: readingCandidateCounts,
            readingBestLengths: readingBestLengths
        )
    }

    private static func loadReadingPrefixes(
        phraseCandidateMap: [String: [String]],
        commonCharacterMap: [String: [String]]
    ) -> Set<String> {
        var prefixes = Set<String>()
        for key in phraseCandidateMap.keys {
            insertProperPrefixes(of: key, into: &prefixes)
        }
        for key in commonCharacterMap.keys {
            insertProperPrefixes(of: key, into: &prefixes)
        }
        return prefixes
    }

    private static func insertProperPrefixes(of reading: String, into prefixes: inout Set<String>) {
        var prefix = ""
        for character in reading.dropLast() {
            prefix.append(character)
            prefixes.insert(prefix)
        }
    }

    private func appendCandidates(forReading reading: String, into merged: inout [String], seen: inout Set<String>, limit: Int? = nil) {
        let startCount = merged.count
        let preferPhrasesFirst = reading.count > 1

        if let overrides = overrideCharacterMap[reading], !overrides.isEmpty {
            for value in overrides where !seen.contains(value) {
                seen.insert(value)
                merged.append(value)
                if let limit, merged.count - startCount >= limit { return }
            }
        }
        let candidateSources: [[String]]
        if preferPhrasesFirst {
            candidateSources = [
                phraseCandidateMap[reading] ?? [],
                commonCharacterMap[reading] ?? []
            ]
        } else {
            candidateSources = [
                commonCharacterMap[reading] ?? [],
                phraseCandidateMap[reading] ?? []
            ]
        }
        for source in candidateSources {
            for value in source where !seen.contains(value) {
                seen.insert(value)
                merged.append(value)
                if let limit, merged.count - startCount >= limit { return }
            }
        }
    }

    private func isSingleSyllableReading(_ reading: String) -> Bool {
        let symbolCount = reading.filter { char in
            !String(char).unicodeScalars.contains { Self.toneMarks.contains($0) }
        }.count
        return symbolCount > 0 && symbolCount <= 4
    }

}
