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
    /// 快取跟隨不可變的詞庫實例；不同覆寫表不可共用讀音查詢結果。
    private final class CandidateCache {
        private let lock = NSLock()
        private var values: [String: [String]] = [:]
        private var order: [String] = []
        private let capacity = 512

        func lookup(_ reading: String) -> [String]? {
            lock.lock()
            defer { lock.unlock() }
            guard let candidates = values[reading] else { return nil }
            touch(reading)
            return candidates
        }

        func store(_ candidates: [String], for reading: String) {
            lock.lock()
            defer { lock.unlock() }
            values[reading] = candidates
            touch(reading)
            while order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
        }

        private func touch(_ reading: String) {
            order.removeAll { $0 == reading }
            order.append(reading)
        }
    }
    private let candidateCache = CandidateCache()
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
        phraseCandidateMap = Self.loadPhraseCandidateMap()
        let sourceCommon = Self.loadCommonCharacterMap()
        self.overrideCharacterMap = Self.validatedOverrides(overrideCharacterMap,
            common: sourceCommon, phrases: phraseCandidateMap)
        // 通過驗證後才合併，反查、前綴與中英辨識也只會看到合法配對。
        commonCharacterMap = self.overrideCharacterMap.reduce(into: sourceCommon) { result, entry in
            result[entry.key] = entry.value + (result[entry.key] ?? []).filter { !entry.value.contains($0) }
        }
        readingPrefixes = Self.loadReadingPrefixes(
            phraseCandidateMap: phraseCandidateMap,
            commonCharacterMap: commonCharacterMap
        )
    }

    func resolveCandidates(for buffer: String) -> [String] {
        if let cached = candidateCache.lookup(buffer) {
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

    func normalizeReading(_ reading: String) -> String {
        reading.unicodeScalars.filter { !Self.toneMarks.contains($0) }.map(String.init).joined()
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
                    var list = result[key, default: []]
                    if !list.contains(value) {
                        list.append(value)
                    }
                    result[key] = list
                }
            }
        }
        return result
    }

    /// 覆寫只能調整合法讀音的來源順位，不得建立去調或錯配別名。
    /// 新短語可依每個字的正式讀音組成；整詞讀音優先保留詞庫中的異讀與變調。
    static func validatedOverrides(_ overrides: [String: [String]]) -> [String: [String]] {
        validatedOverrides(overrides, common: loadCommonCharacterMap(), phrases: loadPhraseCandidateMap())
    }

    private static func validatedOverrides(_ overrides: [String: [String]],
        common: [String: [String]], phrases: [String: [String]]) -> [String: [String]] {
        var characterReadings: [Character: Set<String>] = [:]
        for (reading, values) in common {
            for value in values where value.count == 1 && isDisplayableCandidate(value) {
                characterReadings[value.first!, default: []].insert(reading)
            }
        }
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
            var list = weighted[reading, default: []]
            if !list.contains(where: { $0.phrase == phrase }) {
                list.append((phrase: phrase, weight: weight))
            }
            weighted[reading] = list
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
            let scalars = Array(key)
            guard scalars.count > 1 else { continue }
            for i in 1..<scalars.count {
                prefixes.insert(String(scalars.prefix(i)))
            }
        }
        for key in commonCharacterMap.keys {
            let scalars = Array(key)
            guard scalars.count > 1 else { continue }
            for i in 1..<scalars.count {
                prefixes.insert(String(scalars.prefix(i)))
            }
        }
        return prefixes
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
