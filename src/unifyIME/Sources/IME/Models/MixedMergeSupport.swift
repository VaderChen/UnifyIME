import Foundation

struct MixedMergeAnalysis {
    let merge: RawSpanMergeResult
    let detectedEnglishCandidates: [(rawStart: Int, rawEnd: Int, text: String)]
}

struct MixedCompositionResolution {
    let analysis: MixedMergeAnalysis
    let materializedState: UnifiedCompositionState?
}

/// Shared mixed-input resolution used by both the live IME and CLI replay.
/// Keeping span analysis and state materialization here prevents the two entry
/// points from silently developing different Chinese/English boundary rules.
enum MixedCompositionResolver {
    private static let bopomofoGarbageSet = CharacterSet(
        charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˇˋˊ˙"
    )
    private static let englishCoverageCacheLock = NSLock()
    private static let englishCoverageCacheCapacity = 256
    private static var englishCoverageCandidateCache: [String: [RawSpanCoverage]] = [:]
    private static var englishCoverageCacheOrder: [String] = []
    private static let incrementalMergeCacheLock = NSLock()
    private static let incrementalMergeCacheCapacity = 256
    private static let incrementalTailReanalysisLength = 12
    private static var incrementalMergeCache: [String: MixedMergeAnalysis] = [:]
    private static var incrementalMergeCacheOrder: [String] = []

    static func resolve(
        rawBuffer: String,
        primaryTargetID: String,
        primaryLanguageID: String,
        primaryBehavior: CompositionLanguageBehavior,
        primaryState: UnifiedCompositionState,
        primarySegments: [ComposedSegment]
    ) -> MixedCompositionResolution {
        let exactFullEnglishCandidate = EnglishIMEEngine.exactSurfaceCandidates(for: rawBuffer).first
        let hasExactFullEnglishMatch = exactFullEnglishCandidate != nil
        let hasStableEnglishPrefix = isStableWholeEnglishPrefix(rawBuffer)
        let prefersWholeEnglishSpan = hasExactFullEnglishMatch || hasStableEnglishPrefix
        let previousIncrementalAnalysis = cachedIncrementalAnalysis(
            for: String(rawBuffer.dropLast())
        )
        var fixedPrimaryCoverages = prefersWholeEnglishSpan
            ? []
            : buildFixedPrimaryCoverages(
                from: primarySegments,
                rawBufferLength: rawBuffer.count,
                primaryTargetID: primaryTargetID,
                primaryLanguageID: primaryLanguageID,
                primaryBehavior: primaryBehavior
            )
        if !prefersWholeEnglishSpan {
            let strongEnglishCoverages = strongestExactEnglishCoverages(in: rawBuffer)
            if !strongEnglishCoverages.isEmpty {
                // Keep only the stable Chinese prefix before the first exact
                // English span. Recompute gaps between/after English spans
                // locally: those are the regions where a whole-buffer phonetic
                // preview can be polluted (for example 一啟 vs 一起). This also
                // avoids replaying the unchanged sentence prefix on every key.
                let firstEnglishStart = strongEnglishCoverages.map(\.start).min() ?? 0
                let stablePrimaryPrefix = fixedPrimaryCoverages.filter {
                    $0.end <= firstEnglishStart
                }
                let inheritedStableCoverages = previousIncrementalAnalysis?.merge.coverages.filter {
                    $0.end <= max(0, rawBuffer.count - incrementalTailReanalysisLength - 1)
                } ?? []
                fixedPrimaryCoverages = nonOverlappingCoverages(
                    stablePrimaryPrefix + inheritedStableCoverages + strongEnglishCoverages
                )
            }
        }
        let analyzed = MixedMergeSupport.analyze(
            rawBuffer: rawBuffer,
            primaryTargetID: primaryTargetID,
            fixedPrimaryCoverages: fixedPrimaryCoverages,
            preferIncrementalTailOptimization: previousIncrementalAnalysis != nil
        )
        let analysis: MixedMergeAnalysis
        if prefersWholeEnglishSpan,
           let englishTargetID = CompositionLanguageRegistry.targets.first(where: { $0.id == "english-ime" })?.id {
            let englishText = exactFullEnglishCandidate ?? rawBuffer
            let exactCoverage = RawSpanCoverage(
                targetID: englishTargetID,
                start: 0,
                end: rawBuffer.count,
                text: englishText,
                score: (hasExactFullEnglishMatch ? 1_000_000 : 900_000) + Double(rawBuffer.count * 100)
            )
            var detected = analyzed.detectedEnglishCandidates
            if !detected.contains(where: {
                $0.rawStart == 0 && $0.rawEnd == rawBuffer.count && $0.text == englishText
            }) {
                detected.append((rawStart: 0, rawEnd: rawBuffer.count, text: englishText))
            }
            analysis = MixedMergeAnalysis(
                merge: RawSpanMergeResult(
                    coverages: [exactCoverage],
                    mergedText: englishText,
                    coveredRawLength: rawBuffer.count,
                    fullCoverage: true
                ),
                detectedEnglishCandidates: detected
            )
        } else {
            analysis = analyzed
        }
        storeIncrementalAnalysis(analysis, for: rawBuffer)

        let primaryCoveredRawLength: Int = {
            let segmentRawLength = primarySegments.reduce(0) { partial, segment in
                partial + effectiveRawLength(
                    for: segment,
                    primaryLanguageID: primaryLanguageID,
                    primaryBehavior: primaryBehavior
                )
            }
            if segmentRawLength > 0 { return segmentRawLength }
            return primaryState.currentReading.count
        }()
        let primaryHasGarbage: Bool = {
            if primarySegments.contains(where: { segment in
                segment.value.unicodeScalars.contains { bopomofoGarbageSet.contains($0) }
            }) {
                return true
            }
            if primarySegments.isEmpty,
               !primaryState.currentReading.isEmpty,
               primaryState.currentReading.unicodeScalars.contains(where: { bopomofoGarbageSet.contains($0) }) {
                return true
            }
            return false
        }()

        let merge = analysis.merge
        let usesSecondaryTarget = merge.coverages.contains { $0.targetID != primaryTargetID }
        let primaryFullyCoversBuffer = !prefersWholeEnglishSpan
            && primaryCoveredRawLength >= rawBuffer.count
            && !primaryHasGarbage
        guard !primaryFullyCoversBuffer, merge.fullCoverage, usesSecondaryTarget else {
            return MixedCompositionResolution(analysis: analysis, materializedState: nil)
        }

        let state = materialize(
            merge: merge,
            rawBuffer: rawBuffer,
            primaryTargetID: primaryTargetID,
            primaryBehavior: primaryBehavior
        )
        return MixedCompositionResolution(analysis: analysis, materializedState: state)
    }

    private static func cachedIncrementalAnalysis(for rawBuffer: String) -> MixedMergeAnalysis? {
        guard !rawBuffer.isEmpty else { return nil }
        incrementalMergeCacheLock.lock()
        let cached = incrementalMergeCache[rawBuffer]
        if cached != nil {
            incrementalMergeCacheOrder.removeAll { $0 == rawBuffer }
            incrementalMergeCacheOrder.append(rawBuffer)
        }
        incrementalMergeCacheLock.unlock()
        return cached
    }

    private static func storeIncrementalAnalysis(_ analysis: MixedMergeAnalysis, for rawBuffer: String) {
        incrementalMergeCacheLock.lock()
        incrementalMergeCache[rawBuffer] = analysis
        incrementalMergeCacheOrder.removeAll { $0 == rawBuffer }
        incrementalMergeCacheOrder.append(rawBuffer)
        while incrementalMergeCacheOrder.count > incrementalMergeCacheCapacity {
            let evicted = incrementalMergeCacheOrder.removeFirst()
            incrementalMergeCache.removeValue(forKey: evicted)
        }
        incrementalMergeCacheLock.unlock()
    }

    private static func nonOverlappingCoverages(_ coverages: [RawSpanCoverage]) -> [RawSpanCoverage] {
        let sorted = coverages.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.end > $1.end
        }
        var result: [RawSpanCoverage] = []
        var cursor = 0
        for coverage in sorted {
            guard coverage.end > coverage.start, coverage.start >= cursor else { continue }
            result.append(coverage)
            cursor = coverage.end
        }
        return result
    }

    /// Keeps an unfinished English word intact after the user has already
    /// typed a trustworthy English prefix. For example, `everyb` remains one
    /// provisional span because `every` is exact and the whole token can still
    /// extend to `everybody`, instead of becoming `every` + a Chinese `b` span.
    private static func isStableWholeEnglishPrefix(_ rawBuffer: String) -> Bool {
        let characters = Array(rawBuffer)
        guard characters.count >= 4,
              rawBuffer.unicodeScalars.allSatisfy({
                  $0.isASCII && CharacterSet.letters.contains($0)
              })
        else {
            return false
        }

        for end in stride(from: characters.count - 1, through: 3, by: -1) {
            let prefix = String(characters.prefix(end))
            guard EnglishIMEEngine.isExactWord(prefix) else { continue }
            if EnglishIMEEngine.canExtendToken(rawBuffer) {
                return true
            }
            let suffix = String(characters.suffix(from: end))
            if !suffix.isEmpty,
               !EnglishIMEEngine.isExactWord(suffix),
               EnglishIMEEngine.canExtendToken(suffix) {
                return true
            }
        }
        return false
    }

    /// Picks a non-overlapping set of exact English words from a longer mixed
    /// raw buffer. These spans replace overlapping fixed Chinese preview spans;
    /// otherwise a locally valid phonetic segment can permanently hide words
    /// such as `project`, `everybody`, or `input token` in a long sentence.
    private static func strongestExactEnglishCoverages(in rawBuffer: String) -> [RawSpanCoverage] {
        guard let englishTargetID = CompositionLanguageRegistry.targets.first(where: { $0.id == "english-ime" })?.id else {
            return []
        }
        let characters = Array(rawBuffer)
        guard characters.count >= 4 else { return [] }

        let coverageCandidates = cachedEnglishCoverageCandidates(
            in: rawBuffer,
            englishTargetID: englishTargetID
        )
        var candidatesByStart: [Int: [RawSpanCoverage]] = [:]
        for coverage in coverageCandidates {
            candidatesByStart[coverage.start, default: []].append(coverage)
        }

        struct ExactSpanChoice {
            let score: Int
            let coveredLength: Int
            let coverages: [RawSpanCoverage]
        }
        var memo: [Int: ExactSpanChoice] = [:]

        func solve(_ index: Int) -> ExactSpanChoice {
            if index >= characters.count {
                return ExactSpanChoice(score: 0, coveredLength: 0, coverages: [])
            }
            if let cached = memo[index] { return cached }
            var best = solve(index + 1)
            for coverage in candidatesByStart[index] ?? [] {
                let length = coverage.end - coverage.start
                let tail = solve(coverage.end)
                let candidate = ExactSpanChoice(
                    score: length * length + tail.score,
                    coveredLength: length + tail.coveredLength,
                    coverages: [coverage] + tail.coverages
                )
                if candidate.score > best.score
                    || (candidate.score == best.score && candidate.coveredLength > best.coveredLength)
                    || (candidate.score == best.score
                        && candidate.coveredLength == best.coveredLength
                        && candidate.coverages.count < best.coverages.count) {
                    best = candidate
                }
            }
            memo[index] = best
            return best
        }

        return solve(0).coverages
    }

    private static func cachedEnglishCoverageCandidates(
        in rawBuffer: String,
        englishTargetID: String
    ) -> [RawSpanCoverage] {
        englishCoverageCacheLock.lock()
        if let cached = englishCoverageCandidateCache[rawBuffer] {
            englishCoverageCacheOrder.removeAll { $0 == rawBuffer }
            englishCoverageCacheOrder.append(rawBuffer)
            englishCoverageCacheLock.unlock()
            return cached
        }
        let previousBuffer = String(rawBuffer.dropLast())
        let previousCandidates = englishCoverageCandidateCache[previousBuffer]
        englishCoverageCacheLock.unlock()

        let characters = Array(rawBuffer)
        // Exact spans remain valid when the buffer grows. A provisional span
        // is only valid at the current tail and must not be inherited by the
        // next prefix, or `veryw` can remain locked after `w...` becomes Chinese.
        var result = previousCandidates?.filter {
            !EnglishIMEEngine.exactSurfaceCandidates(for: $0.text).isEmpty
        } ?? []
        if previousCandidates != nil {
            let end = characters.count
            if end >= 4 {
                for start in 0...(end - 4) {
                    if let outcome = englishCoverageScanOutcome(
                        characters: characters,
                        start: start,
                        end: end,
                        englishTargetID: englishTargetID
                    ), let coverage = outcome.coverage {
                        result.append(coverage)
                    }
                }
            }
        } else {
            for start in 0..<characters.count {
                guard characters[start].isLetter, start + 4 <= characters.count else { continue }
                for end in (start + 4)...characters.count {
                    guard let outcome = englishCoverageScanOutcome(
                        characters: characters,
                        start: start,
                        end: end,
                        englishTargetID: englishTargetID
                    ) else {
                        break
                    }
                    if let coverage = outcome.coverage {
                        result.append(coverage)
                    }
                    if !outcome.canContinue { break }
                }
            }
        }

        englishCoverageCacheLock.lock()
        englishCoverageCandidateCache[rawBuffer] = result
        englishCoverageCacheOrder.removeAll { $0 == rawBuffer }
        englishCoverageCacheOrder.append(rawBuffer)
        while englishCoverageCacheOrder.count > englishCoverageCacheCapacity {
            let evicted = englishCoverageCacheOrder.removeFirst()
            englishCoverageCandidateCache.removeValue(forKey: evicted)
        }
        englishCoverageCacheLock.unlock()
        return result
    }

    /// Returns exact English spans already collected by the incremental
    /// coverage cache. MixedMergeSupport used to scan every start/end pair a
    /// second time just to populate candidate metadata, making each new key in
    /// a long sentence repeat O(n²) dictionary lookups.
    static func detectedEnglishCandidates(in rawBuffer: String) -> [(rawStart: Int, rawEnd: Int, text: String)] {
        guard let englishTargetID = CompositionLanguageRegistry.targets.first(where: { $0.id == "english-ime" })?.id else {
            return []
        }
        let coverages = cachedEnglishCoverageCandidates(
            in: rawBuffer,
            englishTargetID: englishTargetID
        )
        var seen = Set<String>()
        var result: [(rawStart: Int, rawEnd: Int, text: String)] = []
        for coverage in coverages {
            guard !EnglishIMEEngine.exactSurfaceCandidates(for: coverage.text).isEmpty else { continue }
            let key = "\(coverage.start):\(coverage.end):\(coverage.text)"
            guard seen.insert(key).inserted else { continue }
            result.append((coverage.start, coverage.end, coverage.text))
        }
        return result
    }

    private static func englishCoverageScanOutcome(
        characters: [Character],
        start: Int,
        end: Int,
        englishTargetID: String
    ) -> (coverage: RawSpanCoverage?, canContinue: Bool)? {
        guard start >= 0, end <= characters.count, end - start >= 4 else { return nil }
        let token = String(characters[start..<end])
        guard token.unicodeScalars.allSatisfy({
            $0.isASCII && CharacterSet.letters.contains($0)
        }) else {
            return nil
        }
        let exactCandidates = EnglishIMEEngine.exactSurfaceCandidates(for: token)
        let isStablePrefix = exactCandidates.isEmpty
            && end == characters.count
            && isStableWholeEnglishPrefix(token)
        let englishText = exactCandidates.first ?? (isStablePrefix ? token : nil)
        let coverage = englishText.map { text -> RawSpanCoverage in
            let length = end - start
            return RawSpanCoverage(
                targetID: englishTargetID,
                start: start,
                end: end,
                text: text,
                score: (isStablePrefix ? 180_000 : 200_000) * Double(length)
                    + Double(length * length * 100)
            )
        }
        let canContinue = !exactCandidates.isEmpty
            || isStablePrefix
            || EnglishIMEEngine.canExtendToken(token)
        return (coverage, canContinue)
    }

    private static func effectiveRawLength(
        for segment: ComposedSegment,
        primaryLanguageID: String,
        primaryBehavior: CompositionLanguageBehavior
    ) -> Int {
        guard segment.languageID == primaryLanguageID else {
            return max(0, segment.rawLength)
        }
        let sequence = primaryBehavior.keySequence(for: [segment.reading])
            .replacingOccurrences(of: " ", with: "")
        return max(1, sequence.count)
    }

    private static func buildFixedPrimaryCoverages(
        from segments: [ComposedSegment],
        rawBufferLength: Int,
        primaryTargetID: String,
        primaryLanguageID: String,
        primaryBehavior: CompositionLanguageBehavior
    ) -> [RawSpanCoverage] {
        guard rawBufferLength > 0 else { return [] }
        let totalRawLength = segments.reduce(0) { partial, segment in
            partial + effectiveRawLength(
                for: segment,
                primaryLanguageID: primaryLanguageID,
                primaryBehavior: primaryBehavior
            )
        }
        let activeWindowStart = max(0, totalRawLength - rawBufferLength)
        var result: [RawSpanCoverage] = []
        var rawCursor = 0

        for segment in segments {
            let segmentRawLength = effectiveRawLength(
                for: segment,
                primaryLanguageID: primaryLanguageID,
                primaryBehavior: primaryBehavior
            )
            let segmentStart = rawCursor
            let segmentEnd = rawCursor + segmentRawLength
            rawCursor = segmentEnd
            guard segment.languageID == primaryLanguageID,
                  segmentRawLength > 0,
                  segmentStart >= activeWindowStart,
                  !segment.value.unicodeScalars.contains(where: { bopomofoGarbageSet.contains($0) })
            else {
                continue
            }
            let start = max(0, segmentStart - activeWindowStart)
            let end = min(rawBufferLength, segmentEnd - activeWindowStart)
            guard end > start else { continue }
            result.append(
                RawSpanCoverage(
                    targetID: primaryTargetID,
                    start: start,
                    end: end,
                    text: segment.value,
                    score: 100_000 + Double(segmentRawLength * 100)
                )
            )
        }
        return result
    }

    private static func materialize(
        merge: RawSpanMergeResult,
        rawBuffer: String,
        primaryTargetID: String,
        primaryBehavior: CompositionLanguageBehavior
    ) -> UnifiedCompositionState {
        let chars = Array(rawBuffer)
        var readings: [String] = []
        var overrides: [CompositionSegmentKey: String] = [:]
        var lockedKeys = Set<CompositionSegmentKey>()
        var previousTargetID: String?

        for coverage in merge.coverages {
            if let previousTargetID {
                let currentIsSecondary = coverage.targetID != primaryTargetID
                let previousIsSecondary = previousTargetID != primaryTargetID
                if currentIsSecondary || previousIsSecondary {
                    let index = readings.count
                    readings.append(" ")
                    let key = CompositionSegmentKey(start: index, length: 1, reading: " ")
                    overrides[key] = " "
                    lockedKeys.insert(key)
                }
            }
            previousTargetID = coverage.targetID

            if coverage.targetID != primaryTargetID {
                let index = readings.count
                readings.append(coverage.text)
                let key = CompositionSegmentKey(start: index, length: 1, reading: coverage.text)
                overrides[key] = coverage.text
                lockedKeys.insert(key)
                continue
            }

            let rawSlice = String(chars[coverage.start..<coverage.end])
            var primaryState = UnifiedCompositionState()
            primaryBehavior.feed(token: rawSlice, state: &primaryState)
            if !primaryState.currentReading.isEmpty {
                primaryState.readings.append(primaryState.currentReading)
                primaryState.currentReading = ""
            }
            let materializedReadings = primaryState.allReadings
            let startIndex = readings.count
            readings.append(contentsOf: materializedReadings)
            if !materializedReadings.isEmpty {
                // Preserve only locally confirmed multi-syllable phrases.
                // Locking an entire raw coverage can freeze a partial final
                // syllable (卻 + 任) before the next coverage forms 確認.
                for segment in primaryBehavior.resolveWalk(materializedReadings) where segment.length > 1 {
                    guard !segment.value.unicodeScalars.contains(where: { bopomofoGarbageSet.contains($0) }) else {
                        continue
                    }
                    let key = CompositionSegmentKey(
                        start: startIndex + segment.start,
                        length: segment.length,
                        reading: segment.reading
                    )
                    overrides[key] = segment.value
                    lockedKeys.insert(key)
                }
            }
        }

        return UnifiedCompositionState(
            readings: readings,
            trailingReadings: [],
            currentReading: "",
            compositionCursorIndex: readings.count,
            rawReadingSymbols: readings.joined().map { String($0) },
            selectedCandidateIndex: 0,
            segmentOverrides: overrides,
            explicitLockedKeys: lockedKeys
        )
    }
}

enum MixedMergeSupport {
    private static let lock = NSLock()
    private static let capacity = 64
    private static var cache: [String: MixedMergeAnalysis] = [:]
    private static var cacheOrder: [String] = []

    private static func cacheKey(
        rawBuffer: String,
        primaryTargetID: String,
        fixedPrimaryCoverages: [RawSpanCoverage],
        preferIncrementalTailOptimization: Bool
    ) -> String {
        let fixedSignature = fixedPrimaryCoverages
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                if $0.targetID != $1.targetID { return $0.targetID < $1.targetID }
                return $0.text < $1.text
            }
            .map { "\($0.targetID):\($0.start)-\($0.end)=\($0.text)" }
            .joined(separator: "|")
        return [primaryTargetID, rawBuffer, preferIncrementalTailOptimization ? "incremental" : "full", fixedSignature]
            .joined(separator: "\u{1E}")
    }

    static func analyze(
        rawBuffer: String,
        primaryTargetID: String,
        fixedPrimaryCoverages: [RawSpanCoverage] = [],
        preferIncrementalTailOptimization: Bool = false
    ) -> MixedMergeAnalysis {
        profileRuntime("mixedMerge.analyze", details: "buffer_len=\(rawBuffer.count)") {
            let cacheKey = cacheKey(
                rawBuffer: rawBuffer,
                primaryTargetID: primaryTargetID,
                fixedPrimaryCoverages: fixedPrimaryCoverages,
                preferIncrementalTailOptimization: preferIncrementalTailOptimization
            )
            lock.lock()
            if let cached = cache[cacheKey] {
                cacheOrder.removeAll { $0 == cacheKey }
                cacheOrder.append(cacheKey)
                lock.unlock()
                return profileRuntime("mixedMerge.cacheHit", details: "buffer_len=\(rawBuffer.count)") {
                    cached
                }
            }
            lock.unlock()

            let merge = profileRuntime("mixedMerge.mergeSpanCoverages", details: "buffer_len=\(rawBuffer.count)") {
                UnifiedCompositionEngine.mergeSpanCoverages(
                    for: rawBuffer,
                    fixedCoverages: fixedPrimaryCoverages,
                    preferIncrementalTailOptimization: preferIncrementalTailOptimization
                )
            }
            let englishScan = profileRuntime("mixedMerge.englishSpanScan", details: "buffer_len=\(rawBuffer.count)") {
                let detected = MixedCompositionResolver.detectedEnglishCandidates(in: rawBuffer)
                let seen = Set(detected.map { "\($0.rawStart):\($0.rawEnd):\($0.text)" })
                return (seen, detected)
            }

            let bufferLength = rawBuffer.count
            var seenEnglish = englishScan.0
            var detectedEnglishCandidates = englishScan.1
            for candidate in merge.coverages
                .filter({ $0.targetID != primaryTargetID && $0.start == 0 && $0.end == bufferLength })
                .map(\.text)
            {
                let key = "0:\(bufferLength):\(candidate)"
                if seenEnglish.insert(key).inserted {
                    detectedEnglishCandidates.append((rawStart: 0, rawEnd: bufferLength, text: candidate))
                }
            }

            let analysis = MixedMergeAnalysis(
                merge: merge,
                detectedEnglishCandidates: detectedEnglishCandidates
            )

            lock.lock()
            cache[cacheKey] = analysis
            cacheOrder.removeAll { $0 == cacheKey }
            cacheOrder.append(cacheKey)
            while cacheOrder.count > capacity {
                let evicted = cacheOrder.removeFirst()
                cache.removeValue(forKey: evicted)
            }
            lock.unlock()
            return analysis
        }
    }
}
