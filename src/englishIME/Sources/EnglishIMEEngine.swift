import Foundation

private struct EnglishLexiconEntry {
    let normalized: String
    let surface: String
    let weight: Int
    let translation: String
}

private enum EnglishLexiconStore {
    private static let lock = NSLock()
    private static var cachedEntries: [EnglishLexiconEntry]?
    private static var cachedExactMap: [String: [EnglishLexiconEntry]]?
    private static var cachedPrefixMap: [String: [EnglishLexiconEntry]]?

    static func entries() -> [EnglishLexiconEntry] {
        lock.lock()
        defer { lock.unlock() }
        if let cachedEntries, let cachedExactMap, let cachedPrefixMap {
            _ = cachedExactMap
            _ = cachedPrefixMap
            return cachedEntries
        }

        var loadedEntries: [EnglishLexiconEntry] = []
        var exactMap: [String: [EnglishLexiconEntry]] = [:]
        var prefixMap: [String: [EnglishLexiconEntry]] = [:]

        if let url = resourceURL(named: "english_words", ext: "tsv"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard parts.count >= 4 else { continue }
                let normalized = String(parts[0])
                let surface = String(parts[1])
                let weight = Int(parts[2]) ?? 0
                let translation = String(parts[3])
                guard !normalized.isEmpty, !surface.isEmpty else { continue }
                let entry = EnglishLexiconEntry(
                    normalized: normalized,
                    surface: surface,
                    weight: weight,
                    translation: translation
                )
                loadedEntries.append(entry)
                exactMap[normalized, default: []].append(entry)
                if normalized.count > 1 {
                    for i in 1..<normalized.count {
                        prefixMap[String(normalized.prefix(i)), default: []].append(entry)
                    }
                }
            }
        }

        loadedEntries.sort { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            if lhs.normalized != rhs.normalized { return lhs.normalized < rhs.normalized }
            return lhs.surface < rhs.surface
        }
        for key in exactMap.keys {
            exactMap[key]?.sort { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                return lhs.surface < rhs.surface
            }
        }
        for key in prefixMap.keys {
            prefixMap[key]?.sort { lhs, rhs in
                if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
                if lhs.normalized != rhs.normalized { return lhs.normalized < rhs.normalized }
                return lhs.surface < rhs.surface
            }
        }

        cachedEntries = loadedEntries
        cachedExactMap = exactMap
        cachedPrefixMap = prefixMap
        return loadedEntries
    }

    static func exactCandidates(for normalized: String) -> [EnglishLexiconEntry] {
        _ = entries()
        return cachedExactMap?[normalized] ?? []
    }

    static func prefixCandidates(for normalized: String, limit: Int = 20) -> [EnglishLexiconEntry] {
        guard !normalized.isEmpty else { return [] }
        _ = entries()
        return Array((cachedPrefixMap?[normalized] ?? []).prefix(limit))
    }

    static func canExtend(prefix normalized: String) -> Bool {
        _ = entries()
        return cachedPrefixMap?[normalized] != nil
    }

    static func exactSurfaceMatches(for normalized: String, surface: String) -> Bool {
        exactCandidates(for: normalized).contains { $0.surface.caseInsensitiveCompare(surface) == .orderedSame }
    }

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
        candidates.append(cwd.appendingPathComponent("src/englishIME/\(relativePath)"))

        var ancestor = cwd
        for _ in 0..<5 {
            candidates.append(ancestor.appendingPathComponent(relativePath))
            candidates.append(ancestor.appendingPathComponent("src/englishIME/\(relativePath)"))
            ancestor.deleteLastPathComponent()
        }

        for candidate in candidates where fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        return nil
    }
}

private func normalizeEnglishToken(_ token: String) -> String {
    guard !token.isEmpty else { return "" }
    let normalized = token.lowercased()
    let allowed = normalized.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" }
    guard allowed, normalized.contains(where: \.isLetter) else { return "" }
    return normalized
}

private func isViableEnglishReading(_ normalized: String) -> Bool {
    guard !normalized.isEmpty else { return false }
    if !EnglishLexiconStore.exactCandidates(for: normalized).isEmpty { return true }
    if EnglishLexiconStore.canExtend(prefix: normalized) { return true }
    if inflectionBase(for: normalized) != nil { return true }
    return false
}

private func isExactEnglishReading(_ normalized: String) -> Bool {
    guard !normalized.isEmpty else { return false }
    if !EnglishLexiconStore.exactCandidates(for: normalized).isEmpty { return true }
    if inflectionBase(for: normalized) != nil { return true }
    return false
}

private func inflectionBase(for normalized: String) -> String? {
    guard normalized.count > 1 else { return nil }
    if normalized.hasSuffix("s") {
        let base = String(normalized.dropLast())
        if !EnglishLexiconStore.exactCandidates(for: base).isEmpty {
            return base
        }
    }
    return nil
}

private func isExplicitEnglishBoundary(_ token: String) -> Bool {
    switch token {
    case "<space>", "<enter>", ".", ",", "!", "?":
        return true
    default:
        return false
    }
}

struct EnglishIMEEngine: CompositionLanguageBehavior {
    static func exactSurfaceCandidates(for token: String) -> [String] {
        let normalized = normalizeEnglishToken(token)
        guard !normalized.isEmpty else { return [] }
        return EnglishLexiconStore.exactCandidates(for: normalized).map(\.surface)
    }

    static func canExtendToken(_ token: String) -> Bool {
        let normalized = normalizeEnglishToken(token)
        guard !normalized.isEmpty else { return false }
        return EnglishLexiconStore.canExtend(prefix: normalized)
    }

    static func isExactWord(_ token: String) -> Bool {
        let normalized = normalizeEnglishToken(token)
        guard !normalized.isEmpty else { return false }
        if EnglishLexiconStore.exactSurfaceMatches(for: normalized, surface: token) {
            return true
        }
        return inflectionBase(for: normalized) != nil
    }

    func feed(token: String, state: inout UnifiedCompositionState) {
        switch token {
        case "<esc>":
            state = UnifiedCompositionState()
            return
        case "<backspace>", "<delete>":
            if !state.rawReadingSymbols.isEmpty {
                _ = state.rawReadingSymbols.popLast()
            } else if !state.currentReading.isEmpty {
                state.currentReading.removeLast()
            } else if !state.readings.isEmpty {
                _ = state.readings.popLast()
            }
            state.selectedCandidateIndex = 0
            state.compositionCursorIndex = state.readings.count
            return
        case "<left>":
            guard state.currentReading.isEmpty, !state.readings.isEmpty else { return }
            state.compositionCursorIndex = max(0, state.currentCompositionCursorIndex() - 1)
            state.selectedCandidateIndex = 0
            return
        case "<right>":
            guard state.currentReading.isEmpty, !state.readings.isEmpty else { return }
            state.compositionCursorIndex = min(state.readings.count, state.currentCompositionCursorIndex() + 1)
            state.selectedCandidateIndex = 0
            return
        case "<up>":
            let candidates = activeCandidates(for: state)
            guard !candidates.isEmpty else { return }
            state.selectedCandidateIndex = state.selectedCandidateIndex > 0 ? (state.selectedCandidateIndex - 1) : (candidates.count - 1)
            return
        case "<down>":
            let candidates = activeCandidates(for: state)
            guard !candidates.isEmpty else { return }
            state.selectedCandidateIndex = (state.selectedCandidateIndex + 1) % candidates.count
            return
        case "<space>", "<enter>":
            materializePendingWord(state: &state, on: token)
            return
        default:
            break
        }

        let normalized = normalizeEnglishToken(token)
        guard !normalized.isEmpty else {
            materializePendingWord(state: &state, on: token)
            return
        }
        let existingBuffer = state.currentReading + state.rawReadingSymbols.joined()
        let prospective = existingBuffer + normalized
        if state.currentReading.isEmpty, state.currentCompositionCursorIndex() < state.readings.count {
            state.trailingReadings = Array(state.readings.suffix(from: state.currentCompositionCursorIndex()))
            state.readings = Array(state.readings.prefix(state.currentCompositionCursorIndex()))
        }
        if isViableEnglishReading(prospective) {
            state.currentReading = prospective
            state.rawReadingSymbols = []
        } else if isExactEnglishReading(state.currentReading) {
            state.rawReadingSymbols.append(normalized)
        } else if isViableEnglishReading(normalized) {
            resetPendingWord(state: &state)
            state.currentReading = normalized
        } else {
            resetPendingWord(state: &state)
            return
        }
        state.compositionCursorIndex = state.readings.count
        state.selectedCandidateIndex = 0
    }

    func predict(_ state: UnifiedCompositionState) -> UnifiedCompositionPrediction {
        let baseSegments = baseSegments(for: state)
        let presentation = CompositionPresentationBuilder.build(
            baseSegments: baseSegments,
            totalReadings: state.allReadings.count + (state.currentReading.isEmpty ? 0 : 1),
            insertionIndex: state.readings.count + (state.currentReading.isEmpty ? 0 : 1),
            selectedCandidateIndex: state.selectedCandidateIndex,
            visibleCandidateLimit: 20
        ) { focus in
            guard let focus else { return [] }
            return resolveCandidates(for: focus.reading).map {
                CandidateEntry(
                    text: $0,
                    languageID: "en",
                    replacementKey: CompositionSegmentKey(start: focus.start, length: focus.length, reading: focus.reading)
                )
            }
        }
        return UnifiedCompositionPrediction(
            presentation: presentation
        )
    }

    func resolveCandidates(for reading: String) -> [String] {
        let normalized = normalizeEnglishToken(reading)
        guard !normalized.isEmpty else { return [] }

        var merged: [String] = []
        var seen = Set<String>()

        for entry in EnglishLexiconStore.exactCandidates(for: normalized) {
            if seen.insert(entry.surface).inserted {
                merged.append(entry.surface)
            }
        }

        for entry in EnglishLexiconStore.prefixCandidates(for: normalized) {
            if seen.insert(entry.surface).inserted {
                merged.append(entry.surface)
            }
        }
        if merged.isEmpty, inflectionBase(for: normalized) != nil {
            merged.append(normalized)
        }
        return merged
    }

    func resolveWalk(_ readings: [String]) -> [ComposedSegment] {
        let raw = readings.joined()
        let normalized = normalizeEnglishToken(raw)
        guard !normalized.isEmpty else { return [] }
        let value = resolveCandidates(for: normalized).first ?? normalized
        return [
            ComposedSegment(
                languageID: "en",
                reading: normalized,
                value: value,
                start: 0,
                length: readings.count,
                rawLength: normalized.count
            )
        ]
    }

    func resolveCommittedText(allReadings: [String]) -> String {
        let normalized = normalizeEnglishToken(allReadings.joined())
        guard !normalized.isEmpty else { return "" }
        return resolveCandidates(for: normalized).first ?? normalized
    }

    func splitReadingIntoSyllables(_ reading: String) -> [String] {
        let normalized = normalizeEnglishToken(reading)
        return normalized.isEmpty ? [] : [normalized]
    }

    func rankCandidates(
        _ candidates: [String],
        allReadings: [String],
        combinedReading: String,
        spanLength: Int,
        precedingValues: [String],
        followingReadings: [String],
        focusedReading: String
    ) -> [String] {
        let normalized = normalizeEnglishToken(focusedReading.isEmpty ? combinedReading : focusedReading)
        let priority = resolveCandidates(for: normalized)
        let priorityMap = Dictionary(uniqueKeysWithValues: priority.enumerated().map { ($1, $0) })
        return candidates.sorted { lhs, rhs in
            let left = priorityMap[lhs] ?? Int.max
            let right = priorityMap[rhs] ?? Int.max
            if left != right { return left < right }
            return lhs < rhs
        }
    }

    func buildReverseLexicon() -> [String: [String]] {
        let entries = EnglishLexiconStore.entries()
        var result: [String: [String]] = [:]
        for entry in entries {
            var values = result[entry.surface, default: []]
            if !values.contains(entry.normalized) {
                values.append(entry.normalized)
            }
            result[entry.surface] = values
        }
        return result
    }

    func reverseReadings(for sentence: String, reverseMap: [String: [String]]) -> [String]? {
        let normalized = normalizeEnglishToken(sentence)
        guard !normalized.isEmpty else { return nil }
        if let values = reverseMap[sentence], let first = values.first {
            return [first]
        }
        if !isViableEnglishReading(normalized) {
            return nil
        }
        return [normalized]
    }

    func simulateIncrementalInput(readings: [String]) -> String {
        resolveCommittedText(allReadings: readings)
    }

    func keySequence(for readings: [String]) -> String {
        normalizeEnglishToken(readings.joined())
    }

    private func activeCandidates(for state: UnifiedCompositionState) -> [String] {
        if !state.currentReading.isEmpty {
            return resolveCandidates(for: state.currentReading)
        }
        guard let last = state.readings.last else { return [] }
        return resolveCandidates(for: last)
    }

    private func finalizeCurrentWord(state: inout UnifiedCompositionState) {
        guard !state.currentReading.isEmpty else { return }
        state.readings.append(state.currentReading)
        if !state.trailingReadings.isEmpty {
            state.readings.append(contentsOf: state.trailingReadings)
            state.trailingReadings = []
        }
        state.currentReading = ""
        state.compositionCursorIndex = state.readings.count
        state.selectedCandidateIndex = 0
    }

    private func materializePendingWord(state: inout UnifiedCompositionState, on token: String) {
        guard !state.currentReading.isEmpty || !state.rawReadingSymbols.isEmpty else { return }
        if isExactEnglishReading(state.currentReading),
           (!state.rawReadingSymbols.isEmpty || isExplicitEnglishBoundary(token)) {
            finalizeCurrentWord(state: &state)
        } else {
            resetPendingWord(state: &state)
        }
    }

    private func resetPendingWord(state: inout UnifiedCompositionState) {
        state.currentReading = ""
        state.rawReadingSymbols = []
        if !state.trailingReadings.isEmpty {
            state.readings.append(contentsOf: state.trailingReadings)
            state.trailingReadings = []
        }
        state.compositionCursorIndex = state.readings.count
        state.selectedCandidateIndex = 0
    }

    private func baseSegments(for state: UnifiedCompositionState) -> [ComposedSegment] {
        var segments: [ComposedSegment] = []
        for (index, reading) in state.readings.enumerated() {
            let value = resolveCandidates(for: reading).first ?? reading
            segments.append(
                ComposedSegment(languageID: "en", reading: reading, value: value, start: index, length: 1, rawLength: reading.count)
            )
        }
        if !state.currentReading.isEmpty {
            guard isViableEnglishReading(state.currentReading) else { return segments }
            segments.append(
                ComposedSegment(
                    languageID: "en",
                    reading: state.currentReading,
                    value: state.currentReading,
                    start: state.readings.count,
                    length: 1,
                    rawLength: state.currentReading.count
                )
            )
        }
        return segments
    }
}
