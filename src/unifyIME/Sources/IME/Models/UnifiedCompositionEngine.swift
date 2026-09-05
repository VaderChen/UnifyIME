import Foundation

struct CompositionSegmentKey: Hashable {
    let start: Int
    let length: Int
    let reading: String
}

struct UnifiedCompositionState {
    var readings: [String] = []
    var trailingReadings: [String] = []
    var currentReading = ""
    var compositionCursorIndex: Int?
    var rawReadingSymbols: [String] = []
    var selectedCandidateIndex = 0
    var segmentOverrides: [CompositionSegmentKey: String] = [:]
    var explicitLockedKeys = Set<CompositionSegmentKey>()

    var allReadings: [String] {
        readings + trailingReadings
    }

    var hasComposition: Bool {
        !readings.isEmpty || !currentReading.isEmpty
    }

    func currentCompositionCursorIndex() -> Int {
        let total = readings.count
        return max(0, min(total, compositionCursorIndex ?? total))
    }
}

struct UnifiedCompositionPrediction {
    let presentation: CompositionPresentationState
}

struct PredictionSnapshot {
    let prediction: UnifiedCompositionPrediction
    let candidateEntries: [CandidateEntry]
    let selectedCandidateIndex: Int
    let totalReadings: Int
    let insertionIndex: Int
    let shouldPreviewSelection: Bool
    let segmentOverrides: [CompositionSegmentKey: String]
    let explicitLockedKeys: Set<CompositionSegmentKey>
    let previewSegmentOverrides: [CompositionSegmentKey: String]
    let previewLockedKeys: Set<CompositionSegmentKey>

    var presentation: CompositionPresentationState { prediction.presentation }
    var candidates: [String] { candidateEntries.map(\.text) }

    private var selectedEntry: CandidateEntry? {
        guard candidateEntries.indices.contains(selectedCandidateIndex) else { return nil }
        return candidateEntries[selectedCandidateIndex]
    }

    var displayedSegments: [ComposedSegment] {
        guard shouldPreviewSelection else {
            let lockedBase = UnifiedCompositionEngine.applyExplicitLocks(
                to: presentation.displayedSegments,
                segmentOverrides: segmentOverrides,
                explicitLockedKeys: explicitLockedKeys
            )
            return UnifiedCompositionEngine.applyExplicitLocks(
                to: lockedBase,
                segmentOverrides: previewSegmentOverrides,
                explicitLockedKeys: previewLockedKeys
            )
        }
        guard let focus = presentation.focusedSegment,
              let selectedEntry else { return presentation.displayedSegments }
        return Self.materializeSelection(
            entry: selectedEntry,
            focus: focus,
            baseSegments: presentation.baseSegments
        )
    }

    var focusedSegment: ComposedSegment? {
        presentation.focusedSegment
    }

    var markedText: String { displayedSegments.map(\.value).joined() }

    var cursorLocation: Int {
        CompositionPresentationBuilder.displayCursorLocation(
            forInsertionIndex: insertionIndex,
            segments: displayedSegments
        )
    }

    var debugText: String {
        CompositionPresentationBuilder.debugComposingText(
            segments: displayedSegments,
            focus: CompositionPresentationBuilder.focusedSegment(
                forInsertionIndex: insertionIndex,
                totalReadings: totalReadings,
                in: displayedSegments
            )
        ).text
    }

    var focusInfo: String? {
        CompositionPresentationBuilder.debugComposingText(
            segments: displayedSegments,
            focus: CompositionPresentationBuilder.focusedSegment(
                forInsertionIndex: insertionIndex,
                totalReadings: totalReadings,
                in: displayedSegments
            )
        ).focus
    }

    private static func materializeSelection(
        entry: CandidateEntry,
        focus: ComposedSegment,
        baseSegments: [ComposedSegment]
    ) -> [ComposedSegment] {
        baseSegments.flatMap { segment in
            guard segment.start == focus.start && segment.length == focus.length else { return [segment] }
            if entry.replacementKey.start == focus.start && entry.replacementKey.length == focus.length {
                return [ComposedSegment(
                    languageID: entry.languageID,
                    reading: segment.reading,
                    value: entry.text,
                    start: segment.start,
                    length: segment.length,
                    rawLength: segment.rawLength
                )]
            }

            let syllables = UnifiedCompositionEngine.splitReadingIntoSyllables(focus.reading)
            let originalChars = Array(focus.value)
            guard syllables.count == focus.length,
                  originalChars.count >= focus.length,
                  entry.replacementKey.length == 1
            else {
                return [ComposedSegment(
                    languageID: entry.languageID,
                    reading: segment.reading,
                    value: entry.text,
                    start: segment.start,
                    length: segment.length,
                    rawLength: segment.rawLength
                )]
            }

            let localOffset = entry.replacementKey.start - focus.start
            guard localOffset >= 0, localOffset < focus.length else { return [segment] }

            var segments: [ComposedSegment] = []
            if localOffset > 0 {
                let prefixReading = syllables.prefix(localOffset).joined()
                segments.append(
                    ComposedSegment(
                        languageID: segment.languageID,
                        reading: prefixReading,
                        value: String(originalChars.prefix(localOffset)),
                        start: focus.start,
                        length: localOffset,
                        rawLength: prefixReading.count
                    )
                )
            }
            segments.append(
                ComposedSegment(
                    languageID: entry.languageID,
                    reading: entry.replacementKey.reading,
                    value: entry.text,
                    start: entry.replacementKey.start,
                    length: 1,
                    rawLength: entry.replacementKey.reading.count
                )
            )
            let suffixLength = focus.length - localOffset - 1
            if suffixLength > 0 {
                let suffixReading = syllables.suffix(suffixLength).joined()
                segments.append(
                    ComposedSegment(
                        languageID: segment.languageID,
                        reading: suffixReading,
                        value: String(originalChars.suffix(suffixLength)),
                        start: entry.replacementKey.start + 1,
                        length: suffixLength,
                        rawLength: suffixReading.count
                    )
                )
            }
            return segments
        }
    }
}

struct MultiTargetCompositionState {
    var perTargetStates: [String: UnifiedCompositionState]

    init(targets: [CompositionLanguageTarget]) {
        perTargetStates = Dictionary(uniqueKeysWithValues: targets.map { ($0.id, UnifiedCompositionState()) })
    }

    subscript(targetID: String) -> UnifiedCompositionState? {
        get { perTargetStates[targetID] }
        set { perTargetStates[targetID] = newValue }
    }
}

struct TargetedCompositionPrediction {
    let targetID: String
    let prediction: UnifiedCompositionPrediction
}

struct MultilingualPrediction {
    let perTargetPredictions: [TargetedCompositionPrediction]
    let mergedCandidates: [String]
    let topPrediction: TargetedCompositionPrediction?
}

enum UnifiedCompositionEngine {
    private static let phoneticIME = PhoneticIME()
    private static let bopomofoScalars = CharacterSet(charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˇˋˊ˙")
    private static let englishRawAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'-")
    private static let maxChineseCoverageRawLength = 12

    private static func predictionMaterialized(
        _ targeted: TargetedCompositionPrediction,
        state: UnifiedCompositionState
    ) -> Bool {
        let prediction = targeted.prediction
        if targeted.targetID == "english-ime" {
            if !state.readings.isEmpty || !state.trailingReadings.isEmpty {
                return true
            }
            guard !state.currentReading.isEmpty else { return false }
            guard state.currentReading.count >= 2 else { return false }
            if prediction.presentation.displayedSegments.contains(where: {
                $0.value.caseInsensitiveCompare(state.currentReading) == .orderedSame
            }) {
                return true
            }
            return false
        }
        if !prediction.presentation.displayedSegments.isEmpty { return true }
        if !prediction.presentation.markedText.isEmpty { return true }
        if !prediction.presentation.candidateEntries.isEmpty { return true }
        return state.hasComposition
    }

    private static func candidateScore(
        _ targeted: TargetedCompositionPrediction,
        state: UnifiedCompositionState
    ) -> Int {
        let prediction = targeted.prediction
        var score = 0
        score += prediction.presentation.displayedSegments.reduce(0) { $0 + max(1, $1.value.count) * max(1, $1.length) }
        score += prediction.presentation.candidateEntries.first?.text.count ?? 0
        score += state.readings.count * 8
        score += state.currentReading.count * 4
        score += state.trailingReadings.count * 2
        if !state.currentReading.isEmpty,
           prediction.presentation.displayedSegments.contains(where: {
               $0.value.caseInsensitiveCompare(state.currentReading) == .orderedSame
           }) {
            score += 1000
        }
        return score
    }

    static func token(for rawChars: String, chars: String? = nil, keyCode: Int? = nil) -> String {
        phoneticIME.token(for: rawChars, chars: chars, keyCode: keyCode)
    }

    static func feed(token: String, state: inout UnifiedCompositionState) {
        phoneticIME.feed(token: token, state: &state)
    }

    static func feed(rawChars: String, chars: String? = nil, keyCode: Int? = nil, state: inout UnifiedCompositionState) {
        phoneticIME.feed(rawChars: rawChars, chars: chars, keyCode: keyCode, state: &state)
    }

    static func predict(_ state: UnifiedCompositionState) -> UnifiedCompositionPrediction {
        phoneticIME.predict(state)
    }

    static func feedAll(token: String, state: inout MultiTargetCompositionState) {
        for target in CompositionLanguageRegistry.targets {
            guard var targetState = state[target.id] else { continue }
            target.behavior.feed(token: token, state: &targetState)
            state[target.id] = targetState
        }
    }

    static func predictAll(_ state: MultiTargetCompositionState) -> MultilingualPrediction {
        let targets = CompositionLanguageRegistry.targets

        let predictions: [TargetedCompositionPrediction]
        if targets.count <= 2 {
            // Sequential is faster than GCD dispatch + lock for ≤2 targets
            predictions = targets.compactMap { target in
                guard let targetState = state[target.id] else { return nil }
                return TargetedCompositionPrediction(
                    targetID: target.id,
                    prediction: target.behavior.predict(targetState)
                )
            }
        } else {
            let lock = NSLock()
            var unorderedPredictions: [(Int, TargetedCompositionPrediction)] = []
            unorderedPredictions.reserveCapacity(targets.count)
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let target = targets[index]
                guard let targetState = state[target.id] else { return }
                let prediction = TargetedCompositionPrediction(
                    targetID: target.id,
                    prediction: target.behavior.predict(targetState)
                )
                lock.lock()
                unorderedPredictions.append((index, prediction))
                lock.unlock()
            }
            predictions = unorderedPredictions
                .sorted { $0.0 < $1.0 }
                .map(\.1)
        }

        let materialized = predictions.filter { targeted in
            guard let targetState = state[targeted.targetID] else { return false }
            return predictionMaterialized(targeted, state: targetState)
        }

        let rankedTargets = materialized.sorted { lhs, rhs in
            let leftState = state[lhs.targetID] ?? UnifiedCompositionState()
            let rightState = state[rhs.targetID] ?? UnifiedCompositionState()
            let leftScore = candidateScore(lhs, state: leftState)
            let rightScore = candidateScore(rhs, state: rightState)
            if leftScore != rightScore { return leftScore > rightScore }
            let leftIndex = CompositionLanguageRegistry.targets.firstIndex { $0.id == lhs.targetID } ?? .max
            let rightIndex = CompositionLanguageRegistry.targets.firstIndex { $0.id == rhs.targetID } ?? .max
            return leftIndex < rightIndex
        }

        let mergedSource = rankedTargets.isEmpty ? predictions.prefix(1) : rankedTargets[...]
        var merged: [String] = []
        for entry in mergedSource {
            for candidate in entry.prediction.presentation.candidateEntries.map(\.text) where !merged.contains(candidate) {
                merged.append(candidate)
            }
        }

        let topPrediction: TargetedCompositionPrediction?
        if let firstRanked = rankedTargets.first {
            topPrediction = firstRanked
        } else if let primary = CompositionLanguageRegistry.targets.first(where: { state[$0.id] != nil }),
                  let fallback = predictions.first(where: { $0.targetID == primary.id }) {
            topPrediction = fallback
        } else {
            topPrediction = predictions.first
        }

        return MultilingualPrediction(
            perTargetPredictions: predictions,
            mergedCandidates: merged,
            topPrediction: topPrediction
        )
    }

    static func commitCandidate(index: Int, state: inout UnifiedCompositionState) -> Bool {
        phoneticIME.commitCandidate(index: index, state: &state)
    }

    /// Advances the composition cursor to focus on the NEXT segment after the currently focused one.
    /// `segments` should come from the unified presentation (e.g. `snapshot().displayedSegments`)
    /// so that it covers segments from any language target.
    /// Returns `true` when there is no next segment (reachedEnd) — caller should auto-commit.
    static func advanceCursorToNextSegment(
        segments: [ComposedSegment],
        state: inout UnifiedCompositionState
    ) -> Bool {
        let allCount = state.allReadings.count
        guard !segments.isEmpty, allCount > 0 else { return true }

        let cursor = state.currentCompositionCursorIndex()

        // Find the index of the currently focused segment (the one the user just confirmed).
        let targetReadingIndex = max(0, cursor > 0 ? cursor - 1 : 0)
        guard let currentIdx = segments.firstIndex(where: {
            $0.start <= targetReadingIndex && targetReadingIndex < $0.start + $0.length
        }) else {
            // Cursor doesn't map to any segment — treat as reached end.
            state.compositionCursorIndex = allCount
            state.selectedCandidateIndex = 0
            return true
        }

        let nextIdx = currentIdx + 1
        if nextIdx < segments.count {
            // Advance cursor to end of the next segment so it becomes the new focused segment.
            let nextSeg = segments[nextIdx]
            state.compositionCursorIndex = nextSeg.start + nextSeg.length
            state.selectedCandidateIndex = 0
            return false
        }

        // No next segment — already on the last one. Reached end.
        state.compositionCursorIndex = allCount
        state.selectedCandidateIndex = 0
        return true
    }

    static func reset(state: inout UnifiedCompositionState) {
        phoneticIME.reset(state: &state)
    }

    static func moveCursor(delta: Int, state: inout UnifiedCompositionState) -> Bool {
        phoneticIME.moveCursor(delta: delta, state: &state)
    }

    static func pressSpace(state: inout UnifiedCompositionState) {
        phoneticIME.pressSpace(state: &state)
    }

    static func pressBackspace(state: inout UnifiedCompositionState) {
        phoneticIME.pressBackspace(state: &state)
    }

    static func pressDeleteForward(state: inout UnifiedCompositionState) {
        phoneticIME.pressDeleteForward(state: &state)
    }

    static func finalizePendingReadingForCommit(state: inout UnifiedCompositionState) {
        phoneticIME.finalizePendingReadingForCommit(state: &state)
    }

    static func resolveCommittedText(allReadings: [String]) -> String {
        CompositionLanguageRegistry.primary.resolveCommittedText(allReadings: allReadings)
    }

    static func resolveWalk(_ readings: [String]) -> [ComposedSegment] {
        CompositionLanguageRegistry.primary.resolveWalk(readings)
    }

    static func applyExplicitLocks(
        to segments: [ComposedSegment],
        segmentOverrides: [CompositionSegmentKey: String],
        explicitLockedKeys: Set<CompositionSegmentKey>
    ) -> [ComposedSegment] {
        let explicitLocks = explicitLockedKeys.compactMap { key -> (CompositionSegmentKey, String)? in
            guard let value = segmentOverrides[key] else { return nil }
            return (key, value)
        }
        guard !explicitLocks.isEmpty else { return segments }

        return segments.flatMap { segment -> [ComposedSegment] in
            let segmentStart = segment.start
            let segmentEnd = segment.start + segment.length
            let locks = explicitLocks
                .filter { key, _ in
                    key.start >= segmentStart && key.start + key.length <= segmentEnd
                }
                .sorted {
                    if $0.0.start != $1.0.start { return $0.0.start < $1.0.start }
                    return $0.0.length < $1.0.length
                }
            guard !locks.isEmpty else { return [segment] }

            let syllables = splitReadingIntoSyllables(segment.reading)
            let chars = Array(segment.value)
            guard syllables.count == segment.length, chars.count >= segment.length else {
                if let exact = locks.first(where: { $0.0.start == segment.start && $0.0.length == segment.length }) {
                    return [
                        ComposedSegment(
                            languageID: segment.languageID,
                            reading: exact.0.reading,
                            value: exact.1,
                            start: exact.0.start,
                            length: exact.0.length,
                            rawLength: exact.0.reading.count
                        )
                    ]
                }
                return [segment]
            }

            var pieces: [ComposedSegment] = []
            var localCursor = 0
            for (key, value) in locks {
                let localStart = key.start - segment.start
                guard localStart >= localCursor else { continue }
                if localStart > localCursor {
                    let prefixReading = syllables[localCursor..<localStart].joined()
                    pieces.append(
                        ComposedSegment(
                            languageID: segment.languageID,
                            reading: prefixReading,
                            value: String(chars[localCursor..<localStart]),
                            start: segment.start + localCursor,
                            length: localStart - localCursor,
                            rawLength: prefixReading.count
                        )
                    )
                }
                pieces.append(
                    ComposedSegment(
                        languageID: segment.languageID,
                        reading: key.reading,
                        value: value,
                        start: key.start,
                        length: key.length,
                        rawLength: key.reading.count
                    )
                )
                localCursor = localStart + key.length
            }
            if localCursor < segment.length {
                let suffixReading = syllables[localCursor..<segment.length].joined()
                pieces.append(
                    ComposedSegment(
                        languageID: segment.languageID,
                        reading: suffixReading,
                        value: String(chars[localCursor..<segment.length]),
                        start: segment.start + localCursor,
                        length: segment.length - localCursor,
                        rawLength: suffixReading.count
                    )
                )
            }
            return pieces
        }
    }

    static func simulateIncrementalInput(readings: [String]) -> String {
        CompositionLanguageRegistry.primary.simulateIncrementalInput(readings: readings)
    }

    static func splitReadingIntoSyllables(_ reading: String) -> [String] {
        CompositionLanguageRegistry.primary.splitReadingIntoSyllables(reading)
    }

    static func rankCandidates(
        _ candidates: [String],
        allReadings: [String],
        combinedReading: String,
        spanLength: Int,
        precedingValues: [String],
        followingReadings: [String],
        focusedReading: String
    ) -> [String] {
        CompositionLanguageRegistry.primary.rankCandidates(
            candidates,
            allReadings: allReadings,
            combinedReading: combinedReading,
            spanLength: spanLength,
            precedingValues: precedingValues,
            followingReadings: followingReadings,
            focusedReading: focusedReading
        )
    }

    private static func displayText(for prediction: UnifiedCompositionPrediction) -> String {
        let segmentsText = prediction.presentation.displayedSegments.map(\.value).joined()
        if !segmentsText.isEmpty { return segmentsText }
        return prediction.presentation.markedText
    }

    private static func coveredRawLength(for prediction: UnifiedCompositionPrediction, state: UnifiedCompositionState) -> Int {
        let segmentRaw = prediction.presentation.displayedSegments.reduce(0) { $0 + $1.rawLength }
        if segmentRaw > 0 { return segmentRaw }
        if !state.currentReading.isEmpty { return state.currentReading.count }
        return 0
    }

    private static func qualityPenalty(text: String) -> Double {
        guard !text.isEmpty else { return 10_000 }
        let bopomofoCount = text.unicodeScalars.filter { bopomofoScalars.contains($0) }.count
        let asciiCount = text.unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) }.count
        var penalty = Double(bopomofoCount * 500)
        if bopomofoCount > 0 && asciiCount > 0 {
            penalty += 1000
        }
        return penalty
    }

    private static func isEnglishRawCandidate(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var letterCount = 0
        for scalar in token.unicodeScalars {
            guard scalar.isASCII, englishRawAllowed.contains(scalar) else { return false }
            if CharacterSet.letters.contains(scalar) {
                letterCount += 1
            }
        }
        return letterCount >= 2
    }

    private static func prunedCoveragesByStart(_ coverages: [RawSpanCoverage], limitPerStart: Int) -> [Int: [RawSpanCoverage]] {
        let grouped = Dictionary(grouping: coverages, by: \.start)
        var result: [Int: [RawSpanCoverage]] = [:]
        result.reserveCapacity(grouped.count)
        for (start, items) in grouped {
            result[start] = Array(
                items.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    let leftLength = $0.end - $0.start
                    let rightLength = $1.end - $1.start
                    if leftLength != rightLength { return leftLength > rightLength }
                    return $0.end > $1.end
                }
                .prefix(limitPerStart)
            )
        }
        return result
    }

    static func spanCoverages(
        for rawBuffer: String,
        uncoveredRanges: [Range<Int>]? = nil,
        preferIncrementalTailOptimization: Bool = false
    ) -> [RawSpanCoverage] {
        let chars = Array(rawBuffer)
        guard !chars.isEmpty else { return [] }
        var result: [RawSpanCoverage] = []
        var bopomofoKeyMappableCache: [Character: Bool] = [:]
        var qualityPenaltyCache: [String: Double] = [:]
        var committedReadingCache: [String: String?] = [:]
        var predictedTextCache: [String: String] = [:]
        let charStrings = chars.map(String.init)
        let activeRanges = uncoveredRanges?.filter { !$0.isEmpty } ?? [0..<chars.count]

        func qualityPenaltyCached(_ text: String) -> Double {
            if let cached = qualityPenaltyCache[text] {
                return cached
            }
            let value = qualityPenalty(text: text)
            qualityPenaltyCache[text] = value
            return value
        }

        func committedReadingText(for reading: String) -> String? {
            if let cached = committedReadingCache[reading] {
                return cached
            }
            let committed = resolveWalk([reading]).map(\.value).joined()
            let value: String? = (!committed.isEmpty && committed != reading) ? committed : nil
            committedReadingCache[reading] = value
            return value
        }

        func predictionSignature(for state: UnifiedCompositionState, targetID: String) -> String {
            [
                targetID,
                state.readings.joined(separator: "\u{1F}"),
                state.trailingReadings.joined(separator: "\u{1F}"),
                state.currentReading,
                state.rawReadingSymbols.joined(separator: "\u{1F}")
            ].joined(separator: "\u{1E}")
        }

        for target in CompositionLanguageRegistry.targets {
            if target.id == "english-ime" {
                // English: direct HashMap lookup, no feed+predict needed
                for range in activeRanges {
                    for start in range.lowerBound..<range.upperBound {
                        guard chars[start].isLetter else { continue }
                        for end in (start + 1)...range.upperBound {
                            let token = String(chars[start..<end])
                            guard isEnglishRawCandidate(token) else { continue }
                            let exactCandidates = EnglishIMEEngine.exactSurfaceCandidates(for: token)
                            let canExtend = EnglishIMEEngine.canExtendToken(token)

                            // Unknown pure-letter substrings previously stayed
                            // eligible forever. On a phonetic raw stream that
                            // made every start scan all the way to the end, even
                            // when the token was neither a word nor a prefix.
                            // Only the active tail needs a provisional unknown
                            // span; interior unknown spans can stop immediately.
                            let isActiveTail = end == range.upperBound
                            if exactCandidates.isEmpty && !canExtend && !isActiveTail {
                                break
                            }

                            // Always keep a provisional raw-English coverage so
                            // unfinished latin spans do not fall back to garbage
                            // bopomofo preview while the user is still typing.
                            // For uninterrupted latin runs inside mixed input,
                            // prefer a provisional English span over garbage
                            // bopomofo fallback. Exact English candidates still
                            // outrank this, but raw latin should beat low-value
                            // Chinese fallback coverages.
                            let isPureLetterSpan = token.unicodeScalars.allSatisfy {
                                $0.isASCII && CharacterSet.letters.contains($0)
                            }
                            let fallbackScore: Double
                            if isPureLetterSpan {
                                // Keep provisional english above garbage bopomofo,
                                // but below a good exact split such as "very" + "good".
                                fallbackScore = Double(token.count * 100) - 60.0
                            } else {
                                let fallbackPenalty = exactCandidates.isEmpty ? 12.0 : 24.0
                                fallbackScore = Double(token.count * 100) - fallbackPenalty
                            }
                            result.append(
                                RawSpanCoverage(
                                    targetID: target.id,
                                    start: start,
                                    end: end,
                                    text: token,
                                    score: fallbackScore
                                )
                            )

                            if let exact = exactCandidates.first {
                                let score = Double(token.count * 100) - qualityPenaltyCached(exact) - 1
                                result.append(
                                    RawSpanCoverage(
                                        targetID: target.id,
                                        start: start,
                                        end: end,
                                        text: exact,
                                        score: score
                                    )
                                )
                            }
                            if exactCandidates.isEmpty && !canExtend {
                                break
                            }
                        }
                    }
                }
            } else {
                // Chinese: incremental feed per start position to avoid redundant work
                for range in activeRanges {
                for start in range.lowerBound..<range.upperBound {
                    // Skip if this character can't map to bopomofo at all
                    let startChar = chars[start]
                    let startMappable = bopomofoKeyMappableCache[startChar] ?? {
                        let mapped = SessionCtl.mapKeySequence(String(startChar)) != nil
                        bopomofoKeyMappableCache[startChar] = mapped
                        return mapped
                    }()
                    guard startMappable else { continue }
                    var state = UnifiedCompositionState()
                    for end in (start + 1)...range.upperBound {
                        if end - start > maxChineseCoverageRawLength {
                            break
                        }
                        // Incrementally feed one more character
                        let ch = chars[end - 1]
                        let isMappable = bopomofoKeyMappableCache[ch] ?? {
                            let mapped = SessionCtl.mapKeySequence(String(ch)) != nil
                            bopomofoKeyMappableCache[ch] = mapped
                            return mapped
                        }()
                        guard isMappable else { break }
                        target.behavior.feed(token: charStrings[end - 1], state: &state)
                        // An interior substring ending in a partial bopomofo
                        // syllable cannot be a stable coverage boundary. The
                        // old path still ran the full walk/ranker here and then
                        // discarded most results. Keep provisional prediction
                        // only at the active tail where the user can actually
                        // be midway through a syllable.
                        if preferIncrementalTailOptimization,
                           !state.currentReading.isEmpty,
                           end < range.upperBound {
                            continue
                        }
                        let signature = predictionSignature(for: state, targetID: target.id)
                        var text = predictedTextCache[signature] ?? {
                            let prediction = target.behavior.predict(state)
                            let displayed = displayText(for: prediction)
                            predictedTextCache[signature] = displayed
                            return displayed
                        }()
                        if !state.currentReading.isEmpty && text == state.currentReading {
                            if let committed = committedReadingText(for: state.currentReading) {
                                text = committed
                            } else {
                                continue
                            }
                        }
                        guard !text.isEmpty else { continue }
                        let score = Double((end - start) * 100) - qualityPenaltyCached(text)
                        result.append(
                            RawSpanCoverage(
                                targetID: target.id,
                                start: start,
                                end: end,
                                text: text,
                                score: score
                            )
                        )
                    }
                }
                }
            }
        }

        return result.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end > $1.end }
            return $0.score > $1.score
        }
    }

    static func mergeSpanCoverages(
        for rawBuffer: String,
        fixedCoverages: [RawSpanCoverage] = [],
        preferIncrementalTailOptimization: Bool = false
    ) -> RawSpanMergeResult {
        profileRuntime("unified.mergeSpanCoverages.total", details: "buffer_len=\(rawBuffer.count)") {
            let chars = Array(rawBuffer)
            let sortedFixed = fixedCoverages.sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.end < $1.end
            }
            var uncoveredRanges: [Range<Int>] = []
            var cursor = 0
            for coverage in sortedFixed {
                guard coverage.start >= cursor else { continue }
                if cursor < coverage.start {
                    uncoveredRanges.append(cursor..<coverage.start)
                }
                cursor = max(cursor, coverage.end)
            }
            if cursor < chars.count {
                uncoveredRanges.append(cursor..<chars.count)
            }

            let coverages = profileRuntime("unified.mergeSpanCoverages.spanCoverages", details: "buffer_len=\(rawBuffer.count)") {
                spanCoverages(
                    for: rawBuffer,
                    uncoveredRanges: uncoveredRanges,
                    preferIncrementalTailOptimization: preferIncrementalTailOptimization
                )
            }
            let byStart = prunedCoveragesByStart(coverages, limitPerStart: 6)
            typealias DPState = (score: Double, pieces: [String], coverages: [RawSpanCoverage], covered: Int)

            func solveRange(_ range: Range<Int>) -> DPState {
                guard !range.isEmpty else { return (0, [], [], 0) }
                var memo: [Int: DPState] = [:]

                func solve(_ index: Int) -> DPState {
                    if let cached = memo[index] { return cached }
                    if index >= range.upperBound {
                        let empty: DPState = (0, [], [], 0)
                        memo[index] = empty
                        return empty
                    }

                    var best = solve(index + 1)
                    best.score -= 5
                    best.pieces.insert(String(chars[index]), at: 0)

                    for coverage in byStart[index] ?? [] {
                        guard coverage.end <= range.upperBound else { continue }
                        let tail = solve(coverage.end)
                        let candidate: DPState = (
                            coverage.score + tail.score,
                            [coverage.text] + tail.pieces,
                            [coverage] + tail.coverages,
                            (coverage.end - coverage.start) + tail.covered
                        )
                        if candidate.score > best.score {
                            best = candidate
                        }
                    }

                    memo[index] = best
                    return best
                }

                return solve(range.lowerBound)
            }

            let gapResults = profileRuntime("unified.mergeSpanCoverages.dp", details: "buffer_len=\(rawBuffer.count) gaps=\(uncoveredRanges.count)") {
                uncoveredRanges.map(solveRange)
            }

            var mergedPieces: [String] = []
            var mergedCoverages: [RawSpanCoverage] = []
            var coveredCount = 0
            var gapIndex = 0
            cursor = 0
            for coverage in sortedFixed {
                if gapIndex < uncoveredRanges.count, uncoveredRanges[gapIndex].lowerBound == cursor, uncoveredRanges[gapIndex].upperBound == coverage.start {
                    let gap = gapResults[gapIndex]
                    mergedPieces.append(contentsOf: gap.pieces)
                    mergedCoverages.append(contentsOf: gap.coverages)
                    coveredCount += gap.covered
                    cursor = uncoveredRanges[gapIndex].upperBound
                    gapIndex += 1
                }
                mergedPieces.append(coverage.text)
                mergedCoverages.append(coverage)
                coveredCount += coverage.end - coverage.start
                cursor = coverage.end
            }
            while gapIndex < uncoveredRanges.count {
                let gap = gapResults[gapIndex]
                mergedPieces.append(contentsOf: gap.pieces)
                mergedCoverages.append(contentsOf: gap.coverages)
                coveredCount += gap.covered
                gapIndex += 1
            }

            if uncoveredRanges.isEmpty, !sortedFixed.isEmpty {
                coveredCount = sortedFixed.reduce(0) { $0 + ($1.end - $1.start) }
            } else if uncoveredRanges.isEmpty {
                let empty: DPState = (0, [], [], 0)
                return RawSpanMergeResult(
                    coverages: empty.coverages,
                    mergedText: empty.pieces.joined(),
                    coveredRawLength: empty.covered,
                    fullCoverage: empty.covered == chars.count
                )
            }

            return RawSpanMergeResult(
                coverages: mergedCoverages.sorted {
                    if $0.start != $1.start { return $0.start < $1.start }
                    return $0.end < $1.end
                },
                mergedText: mergedPieces.joined(),
                coveredRawLength: coveredCount,
                fullCoverage: coveredCount == chars.count
            )
        }
    }
}
