import Foundation

private let lexiconRecallLimit = 20

struct LexiconStore {
    struct PhraseContextStats {
        let surfaceWeights: [String: Double]
        let readingCandidateCounts: [String: Int]
        let readingBestLengths: [String: Int]

        static let empty = PhraseContextStats(
            surfaceWeights: [:],
            readingCandidateCounts: [:],
            readingBestLengths: [:]
        )
    }

    private static let toneMarks = CharacterSet(charactersIn: "ˇˋˊ˙")
    private static let allowedCandidatePunctuation = CharacterSet(charactersIn: "，。、！？：；（）「」『』《》〈〉—…．·")
    private static let bopomofoKeyRows = [
        Array("1234567890-"),
        Array("qwertyuiop"),
        Array("asdfghjkl;"),
        Array("zxcvbnm,./")
    ]
    private static let bopomofoKeyToSymbol: [Character: Character] = [
        "1": "ㄅ", "q": "ㄆ", "a": "ㄇ", "z": "ㄈ",
        "2": "ㄉ", "w": "ㄊ", "s": "ㄋ", "x": "ㄌ",
        "e": "ㄍ", "d": "ㄎ", "c": "ㄏ",
        "r": "ㄐ", "f": "ㄑ", "v": "ㄒ",
        "5": "ㄓ", "t": "ㄔ", "g": "ㄕ", "b": "ㄖ",
        "y": "ㄗ", "h": "ㄘ", "n": "ㄙ",
        "u": "ㄧ", "j": "ㄨ", "m": "ㄩ",
        "8": "ㄚ", "i": "ㄛ", "k": "ㄜ", ",": "ㄝ",
        "9": "ㄞ", "o": "ㄟ", "l": "ㄠ", ".": "ㄡ",
        "0": "ㄢ", "p": "ㄣ", ";": "ㄤ", "/": "ㄥ",
        "-": "ㄦ",
        "3": "ˇ", "4": "ˋ", "6": "ˊ", "7": "˙"
    ]
    private static let bopomofoNeighborMap = buildBopomofoNeighborMap()
    private static let candidateCacheLock = NSLock()
    private static let candidateCacheCapacity = 512
    private static var candidateCache: [String: [String]] = [:]
    private static var candidateCacheOrder: [String] = []
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
        self.overrideCharacterMap = overrideCharacterMap
        phraseCandidateMap = Self.loadPhraseCandidateMap()
        commonCharacterMap = Self.loadCommonCharacterMap(overrides: overrideCharacterMap)
        readingPrefixes = Self.loadReadingPrefixes(
            phraseCandidateMap: phraseCandidateMap,
            commonCharacterMap: commonCharacterMap
        )
    }

    func resolveCandidates(for buffer: String) -> [String] {
        Self.candidateCacheLock.lock()
        if let cached = Self.candidateCache[buffer] {
            Self.touchCachedReading(buffer)
            Self.candidateCacheLock.unlock()
            return cached
        }
        Self.candidateCacheLock.unlock()

        var merged: [String] = []
        var seen = Set<String>()
        appendCandidates(forReading: buffer, into: &merged, seen: &seen)
        let neutralNormalized = neutralToneNormalizedReading(buffer)
        if neutralNormalized != buffer {
            appendCandidates(forReading: neutralNormalized, into: &merged, seen: &seen)
        }
        let normalized = normalizeReading(buffer)
        if normalized != buffer {
            appendCandidates(forReading: normalized, into: &merged, seen: &seen)
        }
        let shouldUseToneFallbacks = isSingleSyllableReading(buffer) && merged.count <= 2
        if shouldUseToneFallbacks && !containsToneMark(buffer) {
            let toneExpandedReadings = toneExpandedVariants(for: buffer)
            for reading in toneExpandedReadings {
                appendCandidates(forReading: reading, into: &merged, seen: &seen, limit: 2)
                if merged.count >= lexiconRecallLimit {
                    break
                }
            }
        } else if shouldUseToneFallbacks {
            for reading in siblingToneVariants(for: buffer) {
                appendCandidates(forReading: reading, into: &merged, seen: &seen, limit: 2)
                if merged.count >= lexiconRecallLimit {
                    break
                }
            }
        }
        if isSingleSyllableReading(normalized != buffer ? normalized : buffer), merged.count <= 1 {
            let variants = neighborReadingVariants(for: normalized != buffer ? normalized : buffer)
            for variant in variants {
                appendCandidates(forReading: variant, into: &merged, seen: &seen, limit: 2)
                if merged.count >= lexiconRecallLimit {
                    break
                }
            }
        }
        let filtered = merged.filter(Self.isDisplayableCandidate(_:))
        var resolved = filtered.isEmpty ? (merged.isEmpty ? [buffer] : merged) : filtered
        if isSingleSyllableReading(buffer) || isSingleSyllableReading(normalized != buffer ? normalized : buffer) {
            let singles = resolved.filter { $0.count == 1 }
            let longer = resolved.filter { $0.count > 1 }
            if !singles.isEmpty {
                resolved = singles + longer
            }
        }
        Self.candidateCacheLock.lock()
        Self.storeCachedCandidates(resolved, for: buffer)
        Self.candidateCacheLock.unlock()
        return resolved
    }

    private static func touchCachedReading(_ reading: String) {
        candidateCacheOrder.removeAll { $0 == reading }
        candidateCacheOrder.append(reading)
    }

    private static func storeCachedCandidates(_ candidates: [String], for reading: String) {
        candidateCache[reading] = candidates
        touchCachedReading(reading)
        while candidateCacheOrder.count > candidateCacheCapacity {
            let evicted = candidateCacheOrder.removeFirst()
            candidateCache.removeValue(forKey: evicted)
        }
    }

    func normalizeReading(_ reading: String) -> String {
        reading.unicodeScalars.filter { !Self.toneMarks.contains($0) }.map(String.init).joined()
    }

    func neutralToneNormalizedReading(_ reading: String) -> String {
        reading.replacingOccurrences(of: "˙", with: "")
    }

    func containsToneMark(_ reading: String) -> Bool {
        reading.unicodeScalars.contains { Self.toneMarks.contains($0) }
    }

    func canExtendToLongerPhrase(_ reading: String) -> Bool {
        if readingPrefixes.contains(reading) {
            return true
        }
        let normalized = normalizeReading(reading)
        return normalized != reading && readingPrefixes.contains(normalized)
    }

    static func isDisplayableCandidate(_ candidate: String) -> Bool {
        guard !candidate.isEmpty else { return false }
        for scalar in candidate.unicodeScalars {
            let value = scalar.value
            let isCommonHan =
                (0x3400...0x4DBF).contains(value) ||
                (0x4E00...0x9FFF).contains(value)
            if isCommonHan { continue }
            if allowedCandidatePunctuation.contains(scalar) { continue }
            return false
        }
        return true
    }

    private static func loadCommonCharacterMap(overrides: [String: [String]]) -> [String: [String]] {
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
        for (key, overrideValues) in overrides {
            var list = result[key, default: []]
            for value in overrideValues.reversed() {
                list.removeAll { $0 == value }
                list.insert(value, at: 0)
            }
            result[key] = list
        }
        return result
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
        var readingCandidateCounts = [String: Int]()
        var readingBestLengths = [String: Int]()

        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 2 else { continue }
            let reading = String(parts[0])
            let phrase = String(parts[1])
            guard !reading.isEmpty, !phrase.isEmpty else { continue }

            let rawWeight = parts.count >= 3 ? Double(parts[2]) ?? 1.0 : 1.0
            let weight = max(rawWeight, 1.0)
            surfaceWeights[phrase] = max(surfaceWeights[phrase] ?? 0.0, weight)
            readingCandidateCounts[reading, default: 0] += 1
            readingBestLengths[reading] = max(readingBestLengths[reading] ?? 0, phrase.count)
        }

        return PhraseContextStats(
            surfaceWeights: surfaceWeights,
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

    private func neighborReadingVariants(for reading: String) -> [String] {
        guard !reading.isEmpty else { return [] }
        let symbols = Array(reading)
        var variants: [String] = []

        for (index, symbol) in symbols.enumerated() {
            guard let neighbors = Self.bopomofoNeighborMap[symbol], !neighbors.isEmpty else { continue }
            for neighbor in neighbors {
                var mutated = symbols
                mutated[index] = neighbor
                let candidate = String(mutated)
                if candidate != reading, !variants.contains(candidate) {
                    variants.append(candidate)
                    if variants.count >= 12 {
                        return variants
                    }
                }
            }
        }

        return variants
    }

    private func toneExpandedVariants(for reading: String) -> [String] {
        guard !reading.isEmpty, !containsToneMark(reading) else { return [] }
        let tones: [Character] = ["ˇ", "ˋ", "ˊ", "˙"]
        return tones.map { reading + String($0) }
    }

    private func siblingToneVariants(for reading: String) -> [String] {
        guard let toneIndex = reading.lastIndex(where: { scalar in
            scalar.unicodeScalars.contains { Self.toneMarks.contains($0) }
        }) else {
            return []
        }

        let base = String(reading[..<toneIndex])
        let currentTone = reading[toneIndex]
        let tones: [Character] = ["ˇ", "ˋ", "ˊ", "˙"]
        var variants = [base]
        for tone in tones where tone != currentTone {
            variants.append(base + String(tone))
        }
        return variants
    }

    private func isSingleSyllableReading(_ reading: String) -> Bool {
        let symbolCount = reading.filter { char in
            !String(char).unicodeScalars.contains { Self.toneMarks.contains($0) }
        }.count
        return symbolCount > 0 && symbolCount <= 4
    }

    private static func buildBopomofoNeighborMap() -> [Character: [Character]] {
        var result = [Character: [Character]]()

        for (rowIndex, row) in bopomofoKeyRows.enumerated() {
            for (columnIndex, key) in row.enumerated() {
                guard let symbol = bopomofoKeyToSymbol[key] else { continue }
                var neighbors: [Character] = []

                for neighborRow in max(0, rowIndex - 1)...min(bopomofoKeyRows.count - 1, rowIndex + 1) {
                    let rowKeys = bopomofoKeyRows[neighborRow]
                    for neighborColumn in max(0, columnIndex - 1)...min(rowKeys.count - 1, columnIndex + 1) {
                        let neighborKey = rowKeys[neighborColumn]
                        guard neighborKey != key, let neighborSymbol = bopomofoKeyToSymbol[neighborKey] else { continue }
                        if toneMarks.contains(UnicodeScalar(String(neighborSymbol))!) { continue }
                        if !neighbors.contains(neighborSymbol) {
                            neighbors.append(neighborSymbol)
                        }
                    }
                }

                if !toneMarks.contains(UnicodeScalar(String(symbol))!) {
                    result[symbol] = neighbors
                }
            }
        }

        return result
    }
}
