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
        let window = sourceWindow(state: primaryState, rawBuffer: rawBuffer, behavior: primaryBehavior)
        let exactFullEnglishCandidate = EnglishIMEEngine.exactSurfaceCandidates(for: rawBuffer).first
        let hasExactFullEnglishMatch = exactFullEnglishCandidate != nil
        let hasStableEnglishPrefix = isStableWholeEnglishPrefix(rawBuffer)
        // 短英文也可能是完整注音鍵序；詞庫已有中文依據時保留中文路徑。
        let pendingReading = primaryState.currentReading
        let lexicon = SessionCtl.traditionalChineseProvider.lexicon
        let hasExactPendingChinese = !(lexicon.commonCharacterMap[pendingReading] ?? []).isEmpty
        let ambiguousShortEnglish = rawBuffer.count <= 3 && (hasExactPendingChinese ||
            primarySegments.contains { LexiconStore.isDisplayableCandidate($0.value) })
        let prefersWholeEnglishSpan = (hasExactFullEnglishMatch && !ambiguousShortEnglish) || hasStableEnglishPrefix
        let previousIncrementalAnalysis = cachedIncrementalAnalysis(
            for: String(rawBuffer.dropLast())
        )
        var fixedPrimaryCoverages = prefersWholeEnglishSpan
            ? []
            : buildFixedPrimaryCoverages(
                from: primarySegments,
                rawBufferLength: rawBuffer.count,
                activeRawStart: window?.rawStart,
                state: primaryState,
                primaryTargetID: primaryTargetID,
                primaryLanguageID: primaryLanguageID
            )
        if ambiguousShortEnglish, fixedPrimaryCoverages.isEmpty, hasExactPendingChinese,
           let value = lexicon.commonCharacterMap[pendingReading]?.first {
            fixedPrimaryCoverages = [RawSpanCoverage(targetID: primaryTargetID, start: 0,
                end: rawBuffer.count, text: value, score: 100_000)]
        }
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
                // 不跨會話沿用僅依字串快取的決策；已確認內容由來源範圍保護。
                fixedPrimaryCoverages = nonOverlappingCoverages(stablePrimaryPrefix + strongEnglishCoverages)
            }
        }
        let analyzed = MixedMergeSupport.analyze(
            rawBuffer: rawBuffer,
            primaryTargetID: primaryTargetID,
            fixedPrimaryCoverages: fixedPrimaryCoverages,
            preferIncrementalTailOptimization: previousIncrementalAnalysis != nil
        )
        var analysis: MixedMergeAnalysis
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
        if let englishText = exactFullEnglishCandidate,
           !analysis.detectedEnglishCandidates.contains(where: {
               $0.rawStart == 0 && $0.rawEnd == rawBuffer.count && $0.text == englishText
           }) {
            analysis = MixedMergeAnalysis(merge: analysis.merge,
                detectedEnglishCandidates: analysis.detectedEnglishCandidates + [(0, rawBuffer.count, englishText)])
        }
        storeIncrementalAnalysis(analysis, for: rawBuffer)


        let merge = analysis.merge
        let usesSecondaryTarget = merge.coverages.contains { $0.targetID != primaryTargetID }
        guard merge.fullCoverage, usesSecondaryTarget else {
            return MixedCompositionResolution(analysis: analysis, materializedState: nil)
        }

        guard let window else {
            return MixedCompositionResolution(analysis: analysis, materializedState: nil)
        }
        // 自動辨識不能跨越人工確認；使用者仍可用局部候選明確更正。
        guard !window.state.explicitLockedKeys.contains(where: {
            $0.start < window.range.upperBound && window.range.lowerBound < $0.start + $0.length
        }) else { return MixedCompositionResolution(analysis: analysis, materializedState: nil) }
        let replacement = materialize(
            merge: merge,
            rawBuffer: rawBuffer,
            primaryTargetID: primaryTargetID,
            primaryBehavior: primaryBehavior
        )
        guard replacement.sourceInputs.joined() == rawBuffer else {
            return MixedCompositionResolution(analysis: analysis, materializedState: nil)
        }
        var state = window.state
        state.invalidateAutomaticDecisions()
        state.readings = state.allReadings
        state.trailingReadings = []
        state.rebaseOverrides(replacing: window.range, insertedCount: replacement.readings.count,
            insertedRawInputs: replacement.sourceInputs)
        state.readings.replaceSubrange(window.range, with: replacement.readings)
        for (key, value) in replacement.segmentOverrides {
            let shifted = CompositionSegmentKey(start: window.range.lowerBound + key.start,
                length: key.length, reading: key.reading)
            state.segmentOverrides[shifted] = value
            state.automaticLockedKeys.insert(shifted)
        }
        state.compositionCursorIndex = window.range.lowerBound + replacement.readings.count
        state.rawReadingSymbols = state.readings.joined().map(String.init)
        return MixedCompositionResolution(analysis: analysis, materializedState: state)
    }

    private static func sourceWindow(state: UnifiedCompositionState, rawBuffer: String,
        behavior: CompositionLanguageBehavior) -> (state: UnifiedCompositionState, range: Range<Int>, rawStart: Int)? {
        guard !rawBuffer.isEmpty else { return nil }
        var completed = state
        if !completed.currentReading.isEmpty { behavior.feed(token: "<space>", state: &completed) }
        let units = completed.sourceInputs
        let end = completed.currentCompositionCursorIndex()
        guard end <= units.count else { return nil }
        let rawEnd = units.prefix(end).reduce(0) { $0 + $1.count }
        let rawStart = rawEnd - rawBuffer.count
        guard rawStart >= 0 else { return nil }
        var offset = 0
        for start in 0..<end {
            if offset == rawStart, units[start..<end].joined() == rawBuffer {
                return (completed, start..<end, rawStart)
            }
            offset += units[start].count
        }
        return nil
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

    private static func buildFixedPrimaryCoverages(
        from segments: [ComposedSegment],
        rawBufferLength: Int,
        activeRawStart: Int?,
        state: UnifiedCompositionState,
        primaryTargetID: String,
        primaryLanguageID: String
    ) -> [RawSpanCoverage] {
        guard rawBufferLength > 0, let activeRawStart else { return [] }
        var result: [RawSpanCoverage] = []
        for segment in segments {
            let key = CompositionSegmentKey(start: segment.start, length: segment.length, reading: segment.reading)
            guard segment.languageID == primaryLanguageID,
                  let span = state.inputSpan(for: key),
                  span.start >= activeRawStart, span.end <= activeRawStart + rawBufferLength,
                  span.end > span.start,
                  !segment.value.unicodeScalars.contains(where: { bopomofoGarbageSet.contains($0) }) else { continue }
            result.append(RawSpanCoverage(targetID: primaryTargetID,
                start: span.start - activeRawStart, end: span.end - activeRawStart,
                text: segment.value, score: 100_000 + Double((span.end - span.start) * 100)))
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
        var sourceInputs: [String] = []
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
                    sourceInputs.append("")
                    let key = CompositionSegmentKey(start: index, length: 1, reading: " ")
                    overrides[key] = " "
                    lockedKeys.insert(key)
                }
            }
            previousTargetID = coverage.targetID

            if coverage.targetID != primaryTargetID {
                let index = readings.count
                readings.append(coverage.text)
                sourceInputs.append(String(chars[coverage.start..<coverage.end]))
                let key = CompositionSegmentKey(start: index, length: 1, reading: coverage.text)
                overrides[key] = coverage.text
                lockedKeys.insert(key)
                continue
            }

            let rawSlice = String(chars[coverage.start..<coverage.end])
            var primaryState = UnifiedCompositionState()
            primaryBehavior.feed(token: rawSlice, state: &primaryState)
            if !primaryState.currentReading.isEmpty {
                primaryBehavior.feed(token: "<space>", state: &primaryState)
            }
            let materializedReadings = primaryState.allReadings
            let startIndex = readings.count
            readings.append(contentsOf: materializedReadings)
            sourceInputs.append(contentsOf: primaryState.sourceInputs)
            if !materializedReadings.isEmpty {
                // 只暫存局部多音節詞的自動決策，不將整個來源區段視為人工確認。
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
            explicitLockedKeys: [],
            automaticLockedKeys: lockedKeys,
            readingRawInputs: sourceInputs
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
