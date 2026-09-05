import AppKit
import Carbon
import InputMethodKit
import UserNotifications

@objc(SessionCtl)
final class SessionCtl: IMKInputController, CandidateSelectionHandler {
    private struct InputEventSnapshot {
        let keyCode: UInt16
        let chars: String
        let raw: String
        let modifiers: NSEvent.ModifierFlags
        let timestamp: TimeInterval
    }

    private struct CandidateUIState {
        var isWindowRequested = false
        var lockedCursorLocation: Int?
    }

    private struct CompositionUndoSnapshot {
        let readings: [String]
        let trailingReadings: [String]
        let currentReading: String
        let compositionCursorIndex: Int?
        let rawReadingSymbols: [String]
        let rawInputTokens: [String]
        let selectedCandidateTextHint: String?
        let selectedCandidateIndex: Int
        let candidateMode: Bool
        let candidateUI: CandidateUIState
        let segmentOverrides: [CompositionSegmentKey: String]
        let explicitLockedKeys: Set<CompositionSegmentKey>
        let previewSegmentOverrides: [CompositionSegmentKey: String]
        let mergedCompositionActive: Bool
        let detectedEnglishCandidates: [(rawStart: Int, rawEnd: Int, text: String)]
        let targetState: MultiTargetCompositionState
        let replayedRawTokenCount: Int
        let rawReplayStateCache: [String: MultiTargetCompositionState]
        let cachedRawInputBuffer: String?
    }

    private var readings: [String] = []
    private var trailingReadings: [String] = []
    private var currentReading = ""
    private var compositionCursorIndex: Int?
    private var rawReadingSymbols: [String] = []
    private var rawInputTokens: [String] = []
    private let selectionSessionID = UUID().uuidString
    private var selectionSentenceID = UUID().uuidString
    private var selectionSequence = 0
    private var selectedCandidateTextHint: String?
    private var suspendSelectedCandidateTextHint = false
    private var selectedCandidateIndex = 0 {
        didSet {
            if suspendSelectedCandidateTextHint {
                selectedCandidateTextHint = nil
            } else if selectedCandidateIndex == 0 {
                selectedCandidateTextHint = nil
            } else if let cachedUnifiedPrediction {
                let previousEntries = candidateEntries(prediction: cachedUnifiedPrediction)
                if previousEntries.indices.contains(selectedCandidateIndex) {
                    selectedCandidateTextHint = previousEntries[selectedCandidateIndex].text
                }
            }
            invalidateSnapshot()
            if selectedCandidateIndex != oldValue {
                appendFocusedTrace("selectedIndex.change old=\(oldValue) new=\(selectedCandidateIndex) route=\(lastRouteDebug) candidateMode=\(candidateMode) basicRequested=\(basicCandidateWindowRequested) readings=\(readings.joined(separator: "/")) current=\(currentReading)")
            }
        }
    }
    private var lastInputDebug = "（尚未輸入）"
    private var lastRouteDebug = "（尚未觸發）"
    private var lastCommitReason = "（尚未送出）"
    private var pendingRawCommitReason = "commitRawText"
    private var candidateMode = false {
        didSet { invalidateSnapshot() }
    }
    private var candidateUI = CandidateUIState()
    private var basicCandidateWindowRequested: Bool {
        get { candidateUI.isWindowRequested }
        set {
            candidateUI.isWindowRequested = newValue
            if !newValue {
                candidateUI.lockedCursorLocation = nil
            }
        }
    }
    private var lockedDisplayCursorLocation: Int? {
        get { candidateUI.lockedCursorLocation }
        set { candidateUI.lockedCursorLocation = newValue }
    }
    private var suppressCommitUntil = Date.distantPast
    private var recentEvents: [InputEventSnapshot] = []
    private var segmentOverrides: [CompositionSegmentKey: String] = [:]
    private var explicitLockedKeys = Set<CompositionSegmentKey>()
    private var previewSegmentOverrides: [CompositionSegmentKey: String] = [:]
    private var mergedCompositionActive = false
    private var detectedEnglishCandidates: [(rawStart: Int, rawEnd: Int, text: String)] = []
    private var primaryTargetID: String { CompositionLanguageRegistry.targets[0].id }
    private var targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
    private var cachedUnifiedPrediction: UnifiedCompositionPrediction?
    private var pendingRawReplayWorkItem: DispatchWorkItem?
    private var pendingMergeWorkItem: DispatchWorkItem?
    private var replayedRawTokenCount = 0
    private var rawReplayStateCache: [String: MultiTargetCompositionState] = [:]
    private var cachedRawInputBuffer: String?
    private var compositionUndoStack: [CompositionUndoSnapshot] = []
    private var rawInputBuffer: String {
        if let cached = cachedRawInputBuffer { return cached }
        let buffer = rawInputTokens.filter { !$0.hasPrefix("<") }.joined()
        cachedRawInputBuffer = buffer
        return buffer
    }
    private func rawReplayCacheKey(for tokens: ArraySlice<String>) -> String {
        tokens.joined(separator: "\u{1F}")
    }
    private func rawReplayCacheKey(for tokens: [String]) -> String {
        tokens.joined(separator: "\u{1F}")
    }

    private func makeCompositionUndoSnapshot() -> CompositionUndoSnapshot {
        CompositionUndoSnapshot(
            readings: readings,
            trailingReadings: trailingReadings,
            currentReading: currentReading,
            compositionCursorIndex: compositionCursorIndex,
            rawReadingSymbols: rawReadingSymbols,
            rawInputTokens: rawInputTokens,
            selectedCandidateTextHint: selectedCandidateTextHint,
            selectedCandidateIndex: selectedCandidateIndex,
            candidateMode: candidateMode,
            candidateUI: candidateUI,
            segmentOverrides: segmentOverrides,
            explicitLockedKeys: explicitLockedKeys,
            previewSegmentOverrides: previewSegmentOverrides,
            mergedCompositionActive: mergedCompositionActive,
            detectedEnglishCandidates: detectedEnglishCandidates,
            targetState: targetState,
            replayedRawTokenCount: replayedRawTokenCount,
            rawReplayStateCache: rawReplayStateCache,
            cachedRawInputBuffer: cachedRawInputBuffer
        )
    }

    private func pushCompositionUndoSnapshot() {
        compositionUndoStack.append(makeCompositionUndoSnapshot())
        if compositionUndoStack.count > 128 {
            compositionUndoStack.removeFirst(compositionUndoStack.count - 128)
        }
    }

    private func clearCompositionUndoStack() {
        compositionUndoStack = []
    }

    private func resetSelectionSentenceTracking() {
        selectionSentenceID = UUID().uuidString
        selectionSequence = 0
    }

    private func restorePreviousCompositionStep(client: Any!) -> Bool {
        guard let snapshot = compositionUndoStack.popLast() else { return false }
        pendingRawReplayWorkItem?.cancel()
        pendingRawReplayWorkItem = nil
        pendingMergeWorkItem?.cancel()
        pendingMergeWorkItem = nil
        invalidateSnapshot()
        readings = snapshot.readings
        trailingReadings = snapshot.trailingReadings
        currentReading = snapshot.currentReading
        compositionCursorIndex = snapshot.compositionCursorIndex
        rawReadingSymbols = snapshot.rawReadingSymbols
        rawInputTokens = snapshot.rawInputTokens
        selectedCandidateTextHint = snapshot.selectedCandidateTextHint
        selectedCandidateIndex = snapshot.selectedCandidateIndex
        candidateMode = snapshot.candidateMode
        candidateUI = snapshot.candidateUI
        segmentOverrides = snapshot.segmentOverrides
        explicitLockedKeys = snapshot.explicitLockedKeys
        previewSegmentOverrides = snapshot.previewSegmentOverrides
        mergedCompositionActive = snapshot.mergedCompositionActive
        detectedEnglishCandidates = snapshot.detectedEnglishCandidates
        targetState = snapshot.targetState
        replayedRawTokenCount = snapshot.replayedRawTokenCount
        rawReplayStateCache = snapshot.rawReplayStateCache
        cachedRawInputBuffer = snapshot.cachedRawInputBuffer
        suppressCommitUntil = Date.distantPast
        if hasComposition {
            updateMarkedText(client)
        } else {
            clearMarkedText(client)
        }
        return true
    }
    private func traceState(_ label: String) {
        guard isRuntimeTraceEnabled else { return }
        appendRuntimeTrace(
            "\(label) build=\(runtimeBuildTag) hasComposition=\(hasComposition) cursor=\(currentCompositionCursorIndex()) readings=\(readings.joined(separator: "/")) trailing=\(trailingReadings.joined(separator: "/")) current=\(currentReading) rawBuffer=\(rawInputBuffer) composing=\(composingBuffer) selected=\(selectedCandidateIndex) candidateMode=\(candidateMode) recentEvents=\(recentEvents.count) pendingRaw=\(pendingRawCommitReason)"
        )
    }

    private static let bopomofoGarbageSet = CharacterSet(charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˇˋˊ˙")

    /// Schedule merge check to run after a short delay. Avoids blocking the keystroke handler.
    private func scheduleMergeCheck() {
        pendingMergeWorkItem?.cancel()
        // Quick pre-check: skip scheduling if no English chars in buffer
        guard rawInputBuffer.unicodeScalars.contains(where: { englishMergeTriggerSet.contains($0) }) else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingMergeWorkItem = nil
            self.recomputeRawSpanMerge()
            if self.mergedCompositionActive {
                self.refreshMarkedTextIfPossible()
            }
        }
        pendingMergeWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    private func flushPendingMerge() {
        guard pendingMergeWorkItem != nil else { return }
        pendingMergeWorkItem?.cancel()
        pendingMergeWorkItem = nil
        recomputeRawSpanMerge()
    }

    private func recomputeRawSpanMerge() {
        profileRuntime("session.recomputeRawSpanMerge", details: "buffer_len=\(rawInputBuffer.count)") {
            mergedCompositionActive = false
            detectedEnglishCandidates = []
            guard !rawInputBuffer.isEmpty else { return }
            let shouldConsiderSecondaryMerge = rawInputBuffer.unicodeScalars.contains { englishMergeTriggerSet.contains($0) }
            guard shouldConsiderSecondaryMerge else { return }
            guard rawInputBuffer.count <= maxMixedRawBufferLength else { return }
            let primaryPrediction = unifiedPrediction()
            let primarySegments = primaryPrediction.presentation.displayedSegments
            let resolution = MixedCompositionResolver.resolve(
                rawBuffer: rawInputBuffer,
                primaryTargetID: primaryTargetID,
                primaryLanguageID: Self.traditionalChineseProvider.languageID,
                primaryBehavior: CompositionLanguageRegistry.primary,
                primaryState: unifiedState(),
                primarySegments: primarySegments
            )
            let analysis = resolution.analysis
            detectedEnglishCandidates = analysis.detectedEnglishCandidates
            let merge = analysis.merge
            let usesSecondaryTarget = merge.coverages.contains { $0.targetID != primaryTargetID }
            let usesPrimaryTarget = merge.coverages.contains { $0.targetID == primaryTargetID }
            if isRuntimeTraceEnabled {
                let coverageSummary = merge.coverages.map { "\($0.targetID):\($0.start)-\($0.end)=\($0.text)" }.joined(separator: " || ")
                appendRuntimeTrace("rawSpanMerge buffer=\(rawInputBuffer) full=\(merge.fullCoverage) covered=\(merge.coveredRawLength) usesSecondary=\(usesSecondaryTarget) usesPrimary=\(usesPrimaryTarget) merged=\(merge.mergedText) coverages=\(coverageSummary)")
            }
            guard let materializedState = resolution.materializedState else { return }
            applyUnifiedState(materializedState)
            pendingRawReplayWorkItem?.cancel()
            pendingRawReplayWorkItem = nil
            pendingMergeWorkItem?.cancel()
            pendingMergeWorkItem = nil
            // rawReplayStateCache contains the unmerged state for every raw
            // prefix. Keep it after materializing the mixed presentation so
            // the next key only feeds the new suffix instead of replaying the
            // entire long sentence from the first key again.
            replayedRawTokenCount = rawInputTokens.count
            invalidateSnapshot()
            mergedCompositionActive = true
            if isRuntimeTraceEnabled {
                appendRuntimeTrace("applyMergedComposition readings=\(readings.joined(separator: "/")) overrides=\(segmentOverrides.count) locked=\(explicitLockedKeys.count)")
            }
        }
    }

    private func rebuildTargetsFromRawInputBuffer() {
        let tokens = rawInputTokens
        let buffer = rawInputBuffer
        guard !tokens.isEmpty else {
            targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
            rawReplayStateCache = [:]
            rawReplayStateCache[""] = targetState
            applyMultiTargetState(targetState)
            recomputeRawSpanMerge()
            appendRuntimeTrace("rebuildTargets buffer=(empty)")
            return
        }

        let currentKey = rawReplayCacheKey(for: tokens)
        var startIndex = 0
        var workingState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
        if let cached = rawReplayStateCache[currentKey] {
            workingState = cached
            startIndex = tokens.count
        } else {
            for length in stride(from: tokens.count - 1, through: 0, by: -1) {
                let prefixKey = rawReplayCacheKey(for: tokens.prefix(length))
                if let cached = rawReplayStateCache[prefixKey] {
                    workingState = cached
                    startIndex = length
                    break
                }
            }
        }

        for token in tokens[startIndex...] {
            var mutable = workingState
            UnifiedCompositionEngine.feedAll(token: token, state: &mutable)
            workingState = mutable
            let consumed = Array(tokens.prefix(startIndex + 1))
            if rawReplayStateCache.count > 64 {
                rawReplayStateCache.removeAll()
                rawReplayStateCache[""] = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
            }
            rawReplayStateCache[rawReplayCacheKey(for: consumed)] = workingState
            startIndex += 1
        }

        targetState = workingState
        if rawReplayStateCache[""] == nil {
            rawReplayStateCache[""] = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
        }
        replayedRawTokenCount = tokens.count
        applyMultiTargetState(targetState)
        recomputeRawSpanMerge()
        if isRuntimeTraceEnabled {
            let primaryPrediction = unifiedPrediction()
            appendRuntimeTrace("rebuildTargets buffer=\(buffer) primaryMarked=\(primaryPrediction.presentation.markedText)")
        }
    }

    private func scheduleRawReplay() {
        pendingRawReplayWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.firePendingRawReplay()
        }
        pendingRawReplayWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + currentPauseRecognitionMode.interval, execute: workItem)
    }

    private func firePendingRawReplay() {
        pendingRawReplayWorkItem = nil
        rebuildTargetsFromRawInputBuffer()
        refreshMarkedTextIfPossible()
    }

    func refreshMarkedTextIfPossible() {
        if let client = client() ?? IMEUIController.shared.activeClient {
            updateMarkedText(client)
        } else {
            appendRuntimeTrace("rawReplay.fire missingClient rawBuffer=\(rawInputBuffer) replayed=\(replayedRawTokenCount)")
        }
    }

    private func flushPendingRawReplay() {
        guard pendingRawReplayWorkItem != nil else { return }
        pendingRawReplayWorkItem?.cancel()
        pendingRawReplayWorkItem = nil
        rebuildTargetsFromRawInputBuffer()
    }

    private func resetRawReplayState() {
        pendingRawReplayWorkItem?.cancel()
        pendingRawReplayWorkItem = nil
        rawInputTokens = []
        cachedRawInputBuffer = nil
        replayedRawTokenCount = 0
        rawReplayStateCache = [:]
    }

    private func rebaseRawReplayOnCurrentState() {
        pendingRawReplayWorkItem?.cancel()
        pendingRawReplayWorkItem = nil
        rawInputTokens = []
        cachedRawInputBuffer = nil
        replayedRawTokenCount = 0
        rawReplayStateCache = ["": targetState]
    }

    private func unifiedState() -> UnifiedCompositionState {
        UnifiedCompositionState(
            readings: readings,
            trailingReadings: trailingReadings,
            currentReading: currentReading,
            compositionCursorIndex: compositionCursorIndex,
            rawReadingSymbols: rawReadingSymbols,
            selectedCandidateIndex: selectedCandidateIndex,
            segmentOverrides: segmentOverrides,
            explicitLockedKeys: explicitLockedKeys
        )
    }

    private func applyUnifiedState(_ state: UnifiedCompositionState) {
        invalidateSnapshot()
        targetState[primaryTargetID] = state
        readings = state.readings
        trailingReadings = state.trailingReadings
        currentReading = state.currentReading
        compositionCursorIndex = state.compositionCursorIndex
        rawReadingSymbols = state.rawReadingSymbols
        selectedCandidateIndex = state.selectedCandidateIndex
        segmentOverrides = state.segmentOverrides
        explicitLockedKeys = state.explicitLockedKeys
    }

    private func multiTargetState() -> MultiTargetCompositionState {
        targetState
    }

    private func applyMultiTargetState(_ state: MultiTargetCompositionState) {
        invalidateSnapshot()
        targetState = state
        guard let primaryState = state[primaryTargetID] else { return }
        applyUnifiedState(primaryState)
    }

    private func feedUnified(token: String) {
        clearPreviewSegmentOverrides()
        UnifiedCompositionEngine.feedAll(token: token, state: &targetState)
        applyMultiTargetState(targetState)
    }

    private func unifiedPrediction() -> UnifiedCompositionPrediction {
        if let cachedUnifiedPrediction {
            return cachedUnifiedPrediction
        }
        let prediction = UnifiedCompositionEngine.predict(unifiedState())
        cachedUnifiedPrediction = prediction
        return prediction
    }

    private func invalidateSnapshot() {
        cachedUnifiedPrediction = nil
    }

    private func mergedCandidates(baseCandidates: [String]) -> [String] {
        struct RankedCandidate {
            let text: String
            let score: Int
            let tieBreaker: Int
        }

        var ranked: [RankedCandidate] = []
        ranked.reserveCapacity(baseCandidates.count + detectedEnglishCandidates.count)

        for (index, candidate) in baseCandidates.enumerated() {
            let score = 10_000 - (index * 100)
            ranked.append(RankedCandidate(text: candidate, score: score, tieBreaker: index))
        }

        for (index, candidate) in detectedEnglishCandidates.enumerated() {
            let spanLength = candidate.rawEnd - candidate.rawStart
            let isFullSpan = candidate.rawStart == 0 && candidate.rawEnd == rawInputBuffer.count
            let isShortWord = candidate.text.count <= 2
            // English candidates appear around position 6 (after top-5 Chinese)
            var score = isFullSpan ? 9550 : 9540
            score += min(spanLength, 8)
            if isShortWord {
                score -= 5
            }
            ranked.append(RankedCandidate(text: candidate.text, score: score, tieBreaker: 10_000 + index))
        }

        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.tieBreaker < $1.tieBreaker
        }

        var seen = Set<String>()
        var merged: [String] = []
        merged.reserveCapacity(ranked.count)
        for entry in ranked {
            if seen.insert(entry.text).inserted {
                merged.append(entry.text)
            }
        }
        return merged
    }

    private func replacementKey(
        for focus: ComposedSegment,
        chosen: String,
        languageID: String
    ) -> CompositionSegmentKey {
        let syllables = UnifiedCompositionEngine.splitReadingIntoSyllables(focus.reading)
        let isSecondaryEnglishCandidate = languageID != primaryTargetID
        if (chosen.count == 1 || isSecondaryEnglishCandidate), focus.length > 1, syllables.count == focus.length {
            let cursorIndex = currentCompositionCursorIndex()
            let preferredIndex = switch currentCandidateCursorAlignment {
            case .left: cursorIndex > 0 ? cursorIndex - 1 : focus.start
            case .right: cursorIndex
            }
            let readingIndex = max(focus.start, min(focus.start + focus.length - 1, preferredIndex))
            let localOffset = max(0, min(focus.length - 1, readingIndex - focus.start))
            return CompositionSegmentKey(
                start: focus.start + localOffset,
                length: 1,
                reading: syllables[localOffset]
            )
        }
        return CompositionSegmentKey(start: focus.start, length: focus.length, reading: focus.reading)
    }

    private func candidateEntries(
        prediction: UnifiedCompositionPrediction
    ) -> [CandidateEntry] {
        let focus = prediction.presentation.focusedSegment
            ?? prediction.presentation.displayedSegments.last
        guard let focus else { return [] }
        let shouldSuppressGarbageBopomofoCandidates =
            !detectedEnglishCandidates.isEmpty &&
            focus.value.unicodeScalars.contains(where: { Self.bopomofoGarbageSet.contains($0) })
        let shouldSuppressSingleSyllableFallbacks =
            !detectedEnglishCandidates.isEmpty && focus.length > 1
        let baseCandidates = prediction.presentation.candidateEntries.filter { entry in
            if shouldSuppressGarbageBopomofoCandidates &&
                entry.text.unicodeScalars.contains(where: { Self.bopomofoGarbageSet.contains($0) }) {
                return false
            }
            if shouldSuppressGarbageBopomofoCandidates && entry.text.count <= 1 {
                return false
            }
            if shouldSuppressSingleSyllableFallbacks && entry.text.count <= 1 {
                return false
            }
            return true
        }

        let mixedEntries = detectedEnglishCandidates.map {
            CandidateEntry(
                text: $0.text,
                languageID: "english-ime",
                replacementKey: replacementKey(for: focus, chosen: $0.text, languageID: "english-ime")
            )
        }

        let orderedTexts = mergedCandidates(baseCandidates: baseCandidates.map(\.text))
        var byText: [String: CandidateEntry] = [:]
        for entry in baseCandidates + mixedEntries where byText[entry.text] == nil {
            byText[entry.text] = entry
        }
        return orderedTexts.compactMap { byText[$0] }
    }

    private func snapshot() -> PredictionSnapshot {
        let state = unifiedState()
        let prediction = unifiedPrediction()
        let entries = candidateEntries(prediction: prediction)
        let resolvedSelectedIndex: Int
        if let selectedCandidateTextHint,
           let matchedIndex = entries.firstIndex(where: { $0.text == selectedCandidateTextHint }) {
            resolvedSelectedIndex = matchedIndex
        } else {
            resolvedSelectedIndex = min(selectedCandidateIndex, max(entries.count - 1, 0))
        }
        return PredictionSnapshot(
            prediction: prediction,
            candidateEntries: entries,
            selectedCandidateIndex: resolvedSelectedIndex,
            totalReadings: state.allReadings.count,
            insertionIndex: state.currentCompositionCursorIndex(),
            shouldPreviewSelection: candidateMode || basicCandidateWindowRequested,
            segmentOverrides: state.segmentOverrides,
            explicitLockedKeys: state.explicitLockedKeys,
            previewSegmentOverrides: previewSegmentOverrides,
            previewLockedKeys: Set(previewSegmentOverrides.keys)
        )
    }

    private func clearPreviewSegmentOverrides() {
        guard !previewSegmentOverrides.isEmpty else { return }
        previewSegmentOverrides = [:]
        invalidateSnapshot()
    }

    private func applyLockedPreviewSegments(
        _ previewSegments: [ComposedSegment],
        replacingRange range: Range<Int>,
        to state: inout UnifiedCompositionState
    ) {
        let survivingLockedKeys = state.explicitLockedKeys.filter { key in
            let keyRange = key.start..<(key.start + key.length)
            return keyRange.upperBound <= range.lowerBound || keyRange.lowerBound >= range.upperBound
        }
        state.explicitLockedKeys = survivingLockedKeys
        state.segmentOverrides = state.segmentOverrides.filter { key, _ in
            let keyRange = key.start..<(key.start + key.length)
            return keyRange.upperBound <= range.lowerBound || keyRange.lowerBound >= range.upperBound
        }

        for segment in previewSegments {
            let key = CompositionSegmentKey(start: segment.start, length: segment.length, reading: segment.reading)
            state.segmentOverrides[key] = segment.value
            state.explicitLockedKeys.insert(key)
        }
    }

    private func setSelectedCandidateIndexDirectly(_ newValue: Int) {
        suspendSelectedCandidateTextHint = true
        selectedCandidateIndex = newValue
        suspendSelectedCandidateTextHint = false
    }

    static let bopomofoMap: [String: String] = [
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
    static let directPunctuationMap: [String: String] = [
        "?": "？",
        "!": "！",
        ":": "：",
        ";": "；",
        "(": "（",
        ")": "）",
        "[": "「",
        "]": "」",
        "{": "『",
        "}": "』",
        "<": "，",
        ">": "。",
        "\"": "、",
        "'": "、",
        "\\": "、"
    ]
    static let overrideCharacterMap: [String: [String]] = [
        "ㄋㄧˇ": ["你"],
        "ㄋㄧ": ["你"],
        "ㄨㄛˇ": ["我"],
        "ㄨㄛ": ["我"],
        "ㄊㄚ": ["他"],
        "ㄊㄚㄇㄣ": ["他們"],
        "ㄊㄚˇ": ["塔"],
        "ㄊㄚˋ": ["大"],
        "ㄕˋ": ["是", "試"],
        "ㄕ": ["是"],
        "ㄕˋㄕˋ": ["試試"],
        "ㄒㄧㄣ": ["新", "心"],
        "ㄅㄨˋ": ["不"],
        "ㄅㄨ": ["不"],
        "ㄧ": ["一"],
        "ㄧ˙": ["一"],
        "ㄦˋ": ["二"],
        "ㄙㄢ˙": ["三"],
        "ㄙˋ": ["四"],
        "ㄨˋ": ["物"],
        "ㄨˇ": ["五"],
        "ㄌㄧㄡˋ": ["六"],
        "ㄑㄧ": ["七"],
        "ㄑㄧˋ": ["氣"],
        "ㄅㄚ": ["八"],
        "ㄐㄧㄡˇ": ["九"],
        "ㄌㄜ˙": ["了"],
        "ㄌㄜ": ["了"],
        "ㄗㄞˋ": ["在"],
        "ㄗㄞˋㄘㄜˋㄕˋㄧㄒㄧㄚˋ": ["再測試一下"],
        "ㄗㄞˋㄏㄨㄟˊㄌㄞˊ": ["再回來"],
        "ㄗㄞˋㄧˋㄑㄧˇ": ["再一起"],
        "ㄗㄞ": ["在"],
        "ㄧㄡˇ": ["有"],
        "ㄧㄡ": ["有"],
        "ㄓㄨㄥ": ["中"],
        "ㄓㄨㄥㄨㄣˊ": ["中文"],
        "ㄓㄨㄥㄍㄨㄛˊ": ["中國"],
        "ㄒㄧㄢ": ["先"],
        "ㄒㄧㄢㄘㄜˋㄕˋㄧㄒㄧㄚˋ": ["先測試一下"],
        "ㄖㄣˊ": ["人"],
        "ㄖㄣ": ["人"],
        "ㄖㄣㄇㄣˊ": ["人們"],
        "ㄉㄚˋ": ["大"],
        "ㄒㄧㄠˇ": ["小"],
        "ㄒㄧㄠ": ["小"],
        "ㄊㄧㄢ": ["天"],
        "ㄐㄧㄣㄊㄧㄢ": ["今天"],
        "ㄇㄧㄥˊㄊㄧㄢ": ["明天"],
        "ㄐㄧㄠˇ": ["較", "角", "腳"],
        "ㄉㄧˋ": ["地"],
        "ㄉㄧ": ["地"],
        "ㄕㄤˋ": ["上"],
        "ㄕㄤ": ["上"],
        "ㄓㄥˋ": ["正", "鄭"],
        "ㄓㄥ": ["正"],
        "ㄒㄧㄚˋ": ["下"],
        "ㄒㄧㄚ": ["下"],
        "ㄌㄞˊ": ["來"],
        "ㄌㄞ": ["來"],
        "ㄑㄩˋ": ["去"],
        "ㄑㄩ": ["去"],
        "ㄎㄢˋ": ["看"],
        "ㄎㄢ": ["看"],
        "ㄏㄠˇ": ["好"],
        "ㄏㄠ": ["好"],
        "ㄏㄠˇㄇㄚ˙": ["好嗎"],
        "ㄏㄠˇㄉㄜ˙": ["好的"],
        "ㄇㄚ˙": ["嗎"],
        "ㄇㄚ": ["嗎"],
        "ㄇㄚˇ": ["嗎", "馬"],
        "ㄅㄚˇ": ["把"],
        "ㄅㄚˋ": ["把", "罷"],
        "ㄦˊㄅㄨˊㄕˋㄧㄡˇ": ["而不是有"],
        "ㄋㄜ˙": ["呢"],
        "ㄋㄜ": ["呢"],
        "ㄏㄜˊ": ["和"],
        "ㄇㄣˊ": ["們"],
        "ㄇㄣ": ["們"],
        "ㄓㄜˋ": ["這"],
        "ㄓㄜ": ["這"],
        "ㄓㄜˋㄍㄜ˙": ["這個"],
        "ㄋㄚˋ": ["那"],
        "ㄋㄚ": ["那"],
        "ㄋㄚˋㄍㄜ˙": ["那個"],
        "ㄕㄣˊ": ["什"],
        "ㄕㄣ": ["什"],
        "ㄇㄜ˙": ["麼"],
        "ㄇㄜ": ["麼"],
        "ㄕㄣˊㄇㄜ˙": ["什麼"],
        "ㄅㄧㄢˋ": ["變", "便"],
        "ㄒㄧㄝˇ": ["寫"],
        "ㄒㄧㄝ": ["寫"],
        "ㄒㄧㄝˇㄗˋ": ["寫字"],
        "ㄉㄚˇ": ["打"],
        "ㄉㄚˇㄗˋ": ["打字"],
        "ㄗˋ": ["字"],
        "ㄗ": ["字"],
        "ㄘㄜˋ": ["測"],
        "ㄘㄜ": ["測"],
        "ㄕˋㄐㄧㄝˋ": ["世界"],
        "ㄘㄜˋㄕˋㄧㄒㄧㄚˋ": ["測試一下"],
        "ㄉㄥˇㄧˊㄒㄧㄚˋ": ["等一下"],
        "ㄘㄜˋㄕˋㄅㄚ˙": ["測試吧"],
        "ㄉㄨㄛㄘㄜˋㄕˋㄅㄚ˙": ["多測試吧"],
        "ㄑㄧㄥˇ": ["請"],
        "ㄑㄧㄥˇㄅㄤ": ["請幫"],
        "ㄓˊㄐㄧㄝㄅㄚˋ": ["直接把"],
        "ㄒㄧㄢㄑㄩ": ["先去"],
        "ㄍㄟˇ": ["給"],
        "ㄒㄧㄢㄍㄟˇ": ["先給"],
        "ㄊㄧㄝㄐㄧˇㄨㄛ": ["貼給我"],
        "ㄐㄧˇㄨㄛ": ["給我"],
        "ㄏㄨㄛˋㄌㄢˊㄎㄨㄤˋ": ["和藍框"],
        "ㄧㄡˇㄙㄨㄛˇㄉㄧˋ": ["有所的"],
        "ㄨㄛˇㄧㄠˋㄗㄞˋ": ["我要再"],
        "ㄌㄢˊㄎㄨㄤ": ["藍框"],
        "ㄩˋㄗㄨㄟˋㄏㄡˋ": ["與最後"],
        "ㄉㄧˋㄨㄣˊㄗˋ": ["的文字"],
        "ㄗㄞˋㄔㄨㄒㄧㄢˋ": ["再出現"],
        "ㄅㄧㄝˊㄉㄜ˙ㄗ": ["別的字"],
        "ㄅㄧㄝˊㄉㄜ˙ㄗˋ": ["別的字"],
        "ㄧˋㄒㄧㄝ": ["一些"],
        "ㄧㄒㄧㄝ": ["一些"],
        "ㄐㄧㄚㄖㄨˋㄧㄒㄧㄝ": ["加入一些"],
        "ㄗㄞˋㄐㄧㄚㄖㄨˋㄧㄒㄧㄝ": ["再加入一些"],
        "ㄗㄞˋㄐㄧㄚㄖㄨˋ": ["再加入"],
        "ㄧㄐㄩˋ": ["一句"],
        "ㄔㄤˊㄐㄩˋ": ["長句"],
        "ㄩˋㄊㄧˊㄐㄧㄠ": ["與提交"],
        "ㄒㄧㄝˋ": ["謝"],
        "ㄉㄨㄟˋ": ["對"],
        "ㄎㄜˇㄧˇ": ["可以"],
        "ㄧㄠˋ": ["要"],
        "ㄒㄧㄤˇ": ["想"],
        "ㄔ": ["吃"],
        "ㄏㄜ": ["喝"],
        "ㄕㄨㄟˇ": ["水"],
        "ㄈㄢˋ": ["飯"],
        "ㄒㄩㄝˊ": ["學"],
        "ㄒㄩㄝˊㄒㄧˊ": ["學習"],
        "ㄍㄨㄥ": ["工"],
        "ㄍㄨㄥㄗㄨㄛˋ": ["工作"],
        "ㄏㄨㄟˋ": ["會"],
        "ㄎㄞ": ["開"],
        "ㄍㄨㄢ": ["關"],
        "ㄎㄞㄇㄣˊ": ["開門"],
        "ㄍㄨㄢㄇㄣˊ": ["關門"],
        "ㄔㄜ": ["車"],
        "ㄐㄧㄚ": ["家"],
        "ㄏㄨㄟˊㄐㄧㄚ": ["回家"],
        "ㄕㄤㄅㄢ": ["上班"],
        "ㄒㄧㄚˋㄅㄢ": ["下班"],
        "ㄌㄠˇㄕ": ["老師"],
        "ㄒㄩㄝˊㄕㄥ": ["學生"],
        "ㄆㄥˊㄧㄡˇ": ["朋友"],
        "ㄉㄧㄢˋㄋㄠˇ": ["電腦"],
        "ㄕㄡˇㄐㄧ": ["手機"],
        "ㄌㄢˊ": ["藍", "籃"],
        "ㄨㄤˇㄌㄨˋ": ["網路"],
        "ㄔㄥˊㄍㄨㄥ": ["成功"],
        "ㄕㄧㄅㄞˋ": ["失敗"],
        "ㄏㄨㄢㄧㄥˊ": ["歡迎"],
        "ㄘㄜˋㄕˋ": ["測試"]
        ,
        "ㄐㄧㄡˋ": ["就"],
        "ㄐㄧㄡˋㄓˊㄐㄧㄝ": ["就直接"],
        "ㄏㄨㄚˋㄇㄧㄢˋ": ["畫面", "畫麵"],
        "ㄕˊ": ["時"],
        "ㄌㄧㄢˊㄒㄩˋ": ["連續"],
        "ㄕㄨㄖㄨˋ": ["輸入"],
        "ㄕㄨㄖㄨˋㄕˊ": ["輸入時"],
        "ㄧㄠˋㄒㄧㄢ": ["要先"]
    ]
    static let protectedNumericReadings: Set<String> = [
        "ㄧ", "ㄧ˙", "ㄦˋ", "ㄙㄢ", "ㄙㄢ˙", "ㄙˋ", "ㄨˇ", "ㄌㄧㄡˋ", "ㄑㄧ", "ㄅㄚ", "ㄐㄧㄡˇ", "ㄌㄧㄥˊ"
    ]
    static let candidateRanker = CoreMLCandidateRanker()
    static let traditionalChineseProvider = TraditionalChineseProvider(
        overrideCharacterMap: overrideCharacterMap,
        ranker: candidateRanker
    )
    private static let toneMarks = CharacterSet(charactersIn: "ˇˋˊ˙")
    private static let initials = CharacterSet(charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ")
    private static let syllableStarters = CharacterSet(charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ")
    private static let medialSet = Set(["ㄧ", "ㄨ", "ㄩ"])
    private static let finalSet = Set(["ㄚ", "ㄛ", "ㄜ", "ㄝ", "ㄞ", "ㄟ", "ㄠ", "ㄡ", "ㄢ", "ㄣ", "ㄤ", "ㄥ", "ㄦ"])
    private static let syllabicInitialSet = Set(["ㄓ", "ㄔ", "ㄕ", "ㄖ", "ㄗ", "ㄘ", "ㄙ"])
    static let rawCommitPrintableSet = CharacterSet(charactersIn: "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-*/=.,?!:;()[]{}<>\"'\\`~@#$%^&_")
    private static let numericPadAllowedSet = CharacterSet(charactersIn: "0123456789+-*/=.")
    private static let allowedFinalsAfterMedial: [String: Set<String>] = [
        "ㄧ": Set(["ㄚ", "ㄛ", "ㄝ", "ㄠ", "ㄡ", "ㄢ", "ㄣ", "ㄤ", "ㄥ"]),
        "ㄨ": Set(["ㄚ", "ㄛ", "ㄞ", "ㄟ", "ㄢ", "ㄣ", "ㄤ", "ㄥ"]),
        "ㄩ": Set(["ㄝ", "ㄢ", "ㄣ", "ㄥ"])
    ]
    private static let allowedCandidatePunctuation = CharacterSet(charactersIn: "，。、！？：；（）「」『』《》〈〉—…．·")

    private static func isToneMarkSymbol(_ symbol: String) -> Bool {
        guard symbol.unicodeScalars.count == 1, let scalar = symbol.unicodeScalars.first else { return false }
        return toneMarks.contains(scalar)
    }

    static func prewarmLexicon() {
        traditionalChineseProvider.prewarm()
    }

    static func prewarmRuntime() {
        prewarmLexicon()
        _ = candidateRanker.isModelLoaded
        _ = traditionalChineseProvider.resolveCandidates(for: "ㄧ˙")
        _ = traditionalChineseProvider.resolveComposition(
            tokens: [InputToken(languageID: traditionalChineseProvider.languageID, rawValue: "ㄧ˙")]
        )
        _ = EnglishIMEEngine.exactSurfaceCandidates(for: "up")
        _ = EnglishIMEEngine.canExtendToken("u")
        _ = EnglishIMEEngine.isExactWord("up")
        _ = UnifiedCompositionEngine.mergeSpanCoverages(for: "jup")
    }

    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func activateServer(_ client: Any!) {
        traceState("activateServer.before")
        appendRuntimeTrace("activateServer client=\(String(describing: client))")
        resetSelectionSentenceTracking()
        readings = []
        currentReading = ""
        compositionCursorIndex = nil
        selectedCandidateIndex = 0
        selectedCandidateTextHint = nil
        lastInputDebug = "（尚未輸入）"
        candidateMode = false
        basicCandidateWindowRequested = false
        segmentOverrides = [:]
        explicitLockedKeys = []
        rawReadingSymbols = []
        previewSegmentOverrides = [:]
        mergedCompositionActive = false
        detectedEnglishCandidates = []
        clearCompositionUndoStack()
        CompositionPanelController.shared.hide()
        publishIMEState("")
        IMEUIController.shared.activate(client: client, selectionHandler: self)
        traceState("activateServer.after")
    }

    override func deactivateServer(_ client: Any!) {
        appendRuntimeTrace("deactivateServer client=\(String(describing: client))")
        lastCommitReason = "deactivateServer"
        commitCurrentComposition(client, reason: "deactivateServer")
        CompositionPanelController.shared.hide()
        publishIMEState("")
        IMEUIController.shared.deactivate()
    }

    override func commitComposition(_ client: Any!) {
        traceState("commitComposition.entry")
        guard hasComposition else { return }
        flushPendingRawReplay()
        lastRouteDebug = "commitComposition"
        publishDetailedProbeIfNeeded(route: lastRouteDebug, input: lastInputDebug, composing: composingBuffer, candidateEntries: Array(activeCandidateEntries.prefix(visibleCandidateLimit)), selectedIndex: selectedCandidateIndex)
        if Date() < suppressCommitUntil {
            updateMarkedText(client)
            return
        }
        if candidateMode {
            updateMarkedText(client)
            return
        }
        finalizePendingReadingForCommit()
        lastCommitReason = "commitComposition"
        commitCurrentComposition(client, reason: "commitComposition")
    }

    @objc(didCommandBySelector:client:)
    override func didCommand(by selector: Selector!, client: Any!) -> Bool {
        appendRuntimeTrace("didCommand selector=\(NSStringFromSelector(selector)) hasComposition=\(hasComposition)")
        if selector == #selector(NSResponder.deleteForward(_:)) {
            appendFocusedTrace("delete.didCommand hasComposition=\(hasComposition) selector=\(NSStringFromSelector(selector))")
        }
        lastRouteDebug = "didCommand(\(NSStringFromSelector(selector)))"
        publishDetailedProbeIfNeeded(route: lastRouteDebug, input: lastInputDebug, composing: composingBuffer, candidateEntries: Array(activeCandidateEntries.prefix(visibleCandidateLimit)), selectedIndex: selectedCandidateIndex)
        guard hasComposition else { return false }

        switch selector {
        case #selector(NSResponder.moveUp(_:)):
            flushPendingRawReplay()
            guard !activeCandidates.isEmpty else { return true }
            pushCompositionUndoSnapshot()
            suppressCommitUntil = Date().addingTimeInterval(0.5)
            let wasCandidateMode = candidateMode
            candidateMode = true
            let wasWindowRequested = basicCandidateWindowRequested
            basicCandidateWindowRequested = true
            if wasWindowRequested && wasCandidateMode {
                setSelectedCandidateIndexDirectly(selectedCandidateIndex > 0 ? (selectedCandidateIndex - 1) : (activeCandidates.count - 1))
            } else {
                setSelectedCandidateIndexDirectly(0)
            }
            updateMarkedText(client)
            return true
        case #selector(NSResponder.moveDown(_:)):
            flushPendingRawReplay()
            guard !activeCandidates.isEmpty else { return true }
            pushCompositionUndoSnapshot()
            suppressCommitUntil = Date().addingTimeInterval(0.5)
            let wasCandidateMode = candidateMode
            candidateMode = true
            let wasWindowRequested = basicCandidateWindowRequested
            basicCandidateWindowRequested = true
            if wasWindowRequested && wasCandidateMode {
                setSelectedCandidateIndexDirectly((selectedCandidateIndex + 1) % activeCandidates.count)
            } else {
                setSelectedCandidateIndexDirectly(0)
            }
            updateMarkedText(client)
            return true
        case #selector(NSResponder.moveLeft(_:)):
            return false
        case #selector(NSResponder.moveRight(_:)):
            return false
        case #selector(NSResponder.insertNewline(_:)):
            flushPendingRawReplay()
            basicCandidateWindowRequested = false
            finalizePendingReadingForCommit()
            lastCommitReason = "didCommand(insertNewline:)"
            commitCurrentComposition(client, reason: "didCommand(insertNewline:)")
            return true
        case #selector(NSResponder.deleteForward(_:)):
            pushCompositionUndoSnapshot()
            flushPendingRawReplay()
            basicCandidateWindowRequested = false
            handleDeleteForward()
            updateMarkedText(client)
            return true
        default:
            return false
        }
    }

    override func handle(_ event: NSEvent!, client: Any!) -> Bool {
        let startedAt = isRuntimeProfilingEnabled ? DispatchTime.now().uptimeNanoseconds : 0
        var processedCharacterCount = 0
        defer {
            if isRuntimeProfilingEnabled, startedAt > 0, processedCharacterCount > 0 {
                let elapsedNs = DispatchTime.now().uptimeNanoseconds - startedAt
                recordRuntimePerCharacterProcessing(elapsedNs: elapsedNs, characterCount: processedCharacterCount)
            }
        }
        appendRuntimeTrace("handle entry type=\(event.type.rawValue) keyCode=\(event.keyCode) chars=\(event.characters ?? "∅") raw=\(event.charactersIgnoringModifiers ?? "∅")")
        if Int(event.keyCode) == 117 || event.characters == "\u{F728}" || event.charactersIgnoringModifiers == "\u{F728}" || event.characters == "\u{7F}" || event.charactersIgnoringModifiers == "\u{7F}" {
            appendFocusedTrace("delete.handle keyCode=\(event.keyCode) chars=\(event.characters ?? "∅") raw=\(event.charactersIgnoringModifiers ?? "∅") hasComposition=\(hasComposition)")
        }
        traceState("handle.pre keyCode=\(event.keyCode)")
        guard event.type == .keyDown else { return false }

        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command, .capsLock, .numericPad, .function])
        let hasComposition = hasComposition
        let inputChars = event.characters ?? ""
        let rawChars = event.charactersIgnoringModifiers ?? ""
        let firstInputScalar = inputChars.unicodeScalars.first
        let isControlLetterHotKey = modifiers.contains(.control) && firstInputScalar?.properties.isAlphabetic == true
        let functionArrowScalars = CharacterSet(charactersIn: String(UnicodeScalar(NSUpArrowFunctionKey)!) + String(UnicodeScalar(NSDownArrowFunctionKey)!) + String(UnicodeScalar(NSLeftArrowFunctionKey)!) + String(UnicodeScalar(NSRightArrowFunctionKey)!))
        let deleteFunctionScalars = CharacterSet(charactersIn: String(UnicodeScalar(NSDeleteFunctionKey)!))

        rememberEvent(event, chars: inputChars, rawChars: rawChars, modifiers: modifiers)
        lastInputDebug = "key=\(event.keyCode) chars=\(inputChars.isEmpty ? "∅" : inputChars) raw=\(rawChars.isEmpty ? "∅" : rawChars) mods=\(modifiers.rawValue)"
        lastRouteDebug = "handle(keyCode=\(event.keyCode))"
        publishDetailedProbeIfNeeded(route: lastRouteDebug, input: lastInputDebug, composing: composingBuffer, candidateEntries: Array(activeCandidateEntries.prefix(visibleCandidateLimit)), selectedIndex: selectedCandidateIndex)
        if !hasComposition && (modifiers.contains(.command) || modifiers.contains(.option) || modifiers.contains(.numericPad) || isControlLetterHotKey) {
            return false
        }

        if modifiers.contains(.capsLock),
           let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) {
            clearComposition(client)
            if modifiers.contains(.shift) {
                return false
            }
            pendingRawCommitReason = "capsLock"
            commitRawText(chars.lowercased(), client: client)
            return true
        }

        if Int(event.keyCode) == 117 || inputChars == "\u{F728}" || rawChars == "\u{F728}" || inputChars == "\u{7F}" || rawChars == "\u{7F}" {
            guard hasComposition else { return false }
            pushCompositionUndoSnapshot()
            flushPendingRawReplay()
            basicCandidateWindowRequested = false
            handleDeleteForward()
            updateMarkedText(client)
            return true
        }

        if handleNumericPadInput(event, client: client) {
            return true
        }

        if hasComposition,
           let raw = event.charactersIgnoringModifiers,
           raw.unicodeScalars.contains(where: { deleteFunctionScalars.contains($0) }) {
            pushCompositionUndoSnapshot()
            flushPendingRawReplay()
            basicCandidateWindowRequested = false
            handleDeleteForward()
            updateMarkedText(client)
            return true
        }

        switch Int(event.keyCode) {
        case 53:
            traceState("escape.before")
            guard hasComposition else { return false }
            _ = restorePreviousCompositionStep(client: client)
            traceState("escape.after")
            return true
        case 123, 124:
            if hasComposition {
                let shouldConfirmPreview = basicCandidateWindowRequested && !activeCandidates.isEmpty
                var state = unifiedState()
                let movedWithoutConfirm = UnifiedCompositionEngine.moveCursor(delta: Int(event.keyCode) == 123 ? -1 : 1, state: &state)
                guard shouldConfirmPreview || movedWithoutConfirm else { return true }
                pushCompositionUndoSnapshot()
                flushPendingRawReplay()
                if shouldConfirmPreview {
                    _ = applyCandidateSelection(index: selectedCandidateIndex, advance: false)
                    state = unifiedState()
                    _ = UnifiedCompositionEngine.moveCursor(delta: Int(event.keyCode) == 123 ? -1 : 1, state: &state)
                }
                basicCandidateWindowRequested = false
                applyUnifiedState(state)
                rebaseRawReplayOnCurrentState()
                candidateMode = false
                updateMarkedText(client)
                return true
            }
            return false
        case 126:
            guard hasComposition else { return false }
            flushPendingRawReplay()
            flushPendingMerge()
            guard !activeCandidates.isEmpty else { return true }
            pushCompositionUndoSnapshot()
            suppressCommitUntil = Date().addingTimeInterval(0.5)
            let wasCandidateMode = candidateMode
            candidateMode = true
            let wasWindowRequested = basicCandidateWindowRequested
            basicCandidateWindowRequested = true
            if wasWindowRequested && wasCandidateMode {
                setSelectedCandidateIndexDirectly(selectedCandidateIndex > 0 ? (selectedCandidateIndex - 1) : (activeCandidates.count - 1))
            } else {
                setSelectedCandidateIndexDirectly(0)
            }
            updateMarkedText(client)
            return true
        case 125:
            guard hasComposition else { return false }
            flushPendingRawReplay()
            flushPendingMerge()
            guard !activeCandidates.isEmpty else { return true }
            pushCompositionUndoSnapshot()
            suppressCommitUntil = Date().addingTimeInterval(0.5)
            let wasCandidateMode = candidateMode
            candidateMode = true
            let wasWindowRequested = basicCandidateWindowRequested
            basicCandidateWindowRequested = true
            if wasWindowRequested && wasCandidateMode {
                setSelectedCandidateIndexDirectly((selectedCandidateIndex + 1) % activeCandidates.count)
            } else {
                setSelectedCandidateIndexDirectly(0)
            }
            updateMarkedText(client)
            return true
        case 49:
            guard hasComposition else { return false }
            pushCompositionUndoSnapshot()
            basicCandidateWindowRequested = false
            if !currentReading.isEmpty {
                // Space is an explicit boundary. Replay immediately so
                // correction doesn't wait for a later cursor move/flush.
                if allReadings.joined().contains("ㄈㄚ") || currentReading.contains("ㄈ") {
                    appendFocusedTrace("space before readings=\(readings.joined(separator: "/")) current=\(currentReading) composing=\(composingBuffer)")
                }
                rawInputTokens.append("<space>")
                cachedRawInputBuffer = nil
                pendingRawReplayWorkItem?.cancel()
                pendingRawReplayWorkItem = nil
                rebuildTargetsFromRawInputBuffer()
                updateMarkedText(client)
                if allReadings.joined().contains("ㄈㄚ") || currentReading.contains("ㄈ") {
                    appendFocusedTrace("space after readings=\(readings.joined(separator: "/")) current=\(currentReading) composing=\(composingBuffer)")
                }
            } else {
                // No pending reading → confirm current segment's top candidate and advance.
                flushPendingRawReplay()
                flushPendingMerge()
                let confirmIndex = selectedCandidateIndex
                let result = applyCandidateSelection(index: confirmIndex, advance: true)
                if result == .confirmedAndReachedEnd {
                    lastCommitReason = "handle(space-reachedEnd)"
                    commitCurrentComposition(client, reason: lastCommitReason)
                } else if result == .confirmed {
                    candidateMode = true
                    updateMarkedText(client)
                } else {
                    // .failed — no candidates or no focus; treat as no-op for now.
                    updateMarkedText(client)
                }
            }
            return true
        case 36, 76:
            guard hasComposition else { return false }
            flushPendingRawReplay()
            if basicCandidateWindowRequested && !activeCandidates.isEmpty {
                pushCompositionUndoSnapshot()
                let result = applyCandidateSelection(index: selectedCandidateIndex, advance: false)
                guard result != .failed else {
                    updateMarkedText(client)
                    return true
                }
                candidateMode = false
                basicCandidateWindowRequested = false
                updateMarkedText(client)
                return true
            }
            basicCandidateWindowRequested = false
            finalizePendingReadingForCommit()
            lastCommitReason = "handle(enter)"
            commitCurrentComposition(client, reason: "handle(enter)")
            return true
        case 51:
            guard hasComposition else { return false }
            pushCompositionUndoSnapshot()
            flushPendingRawReplay()
            basicCandidateWindowRequested = false
            traceState("backspace.before")
            let willClearComposition = !currentReading.isEmpty ? readings.isEmpty : readings.count == 1
            appendRuntimeTrace("backspace decision willClear=\(willClearComposition)")
            if willClearComposition {
                var state = unifiedState()
                UnifiedCompositionEngine.reset(state: &state)
                applyUnifiedState(state)
                targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
                rawInputTokens = []
                cachedRawInputBuffer = nil
                clearMarkedText(client)
                CompositionPanelController.shared.hide()
                IMEUIController.shared.clear()
                traceState("backspace.afterDirectClear")
                return true
            }
            handleBackspace()
            traceState("backspace.afterHandle")
            updateMarkedText(client)
            traceState("backspace.afterUpdate")
            return true
        case 117:
            guard hasComposition else { return false }
            pushCompositionUndoSnapshot()
            flushPendingRawReplay()
            basicCandidateWindowRequested = false
            handleDeleteForward()
            updateMarkedText(client)
            return true
        default:
            break
        }

        if hasComposition,
           let raw = event.charactersIgnoringModifiers,
           raw.unicodeScalars.contains(where: { functionArrowScalars.contains($0) }) {
            return true
        }

        if handleShiftedPunctuation(event, client: client) {
            return true
        }
        if handleShiftedPassthrough(event, client: client) {
            return true
        }

        guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return false }
        processedCharacterCount = chars.count
        if let mapped = Self.mapKeySequence(chars) {
            pushCompositionUndoSnapshot()
            basicCandidateWindowRequested = false
            if focusedTraceRawTokens.contains(chars) {
                appendFocusedTrace("mapped chars=\(chars) mapped=\(mapped) before readings=\(readings.joined(separator: "/")) current=\(currentReading) composing=\(composingBuffer)")
            }
            rawInputTokens.append(chars)
            cachedRawInputBuffer = nil
            if mergedCompositionActive {
                // Rebuild from scratch so we don't feed into a merged state.
                rebuildTargetsFromRawInputBuffer()
            } else {
                feedUnified(token: chars)
                rawReplayStateCache[rawReplayCacheKey(for: rawInputTokens)] = targetState
                // Run merge synchronously when buffer contains English chars
                let buf = rawInputBuffer
                if buf.unicodeScalars.contains(where: { englishMergeTriggerSet.contains($0) }),
                   buf.count <= maxMixedRawBufferLength {
                    pendingMergeWorkItem?.cancel()
                    pendingMergeWorkItem = nil
                    recomputeRawSpanMerge()
                } else {
                    scheduleMergeCheck()
                }
            }
            updateMarkedText(client)
            if focusedTraceRawTokens.contains(chars) {
                appendFocusedTrace("mapped chars=\(chars) after readings=\(readings.joined(separator: "/")) current=\(currentReading) composing=\(composingBuffer) selected=\(selectedCandidateIndex) candidateMode=\(candidateMode)")
            }
            return true
        }

        if handleDirectPunctuation(event, client: client) {
            return true
        }

        if hasComposition {
            lastCommitReason = "handle(fallback)"
            commitCurrentComposition(client, reason: "handle(fallback)")
        }
        return false
    }

    private func updateMarkedText(_ client: Any!) {
        guard let input = client as? IMKTextInput else { return }
        let snap = snapshot()
        let candidateEntries = snap.candidateEntries
        let candidates = candidateEntries.map(\.text)
        let displayed = snap.displayedSegments
        let visibleText = snap.markedText
        let computedBaseCursorLocation = snap.presentation.cursorLocation
        let shouldLockDisplayCursor = basicCandidateWindowRequested && !candidates.isEmpty
        if shouldLockDisplayCursor {
            if let lockedDisplayCursorLocation {
                _ = lockedDisplayCursorLocation
            } else {
                lockedDisplayCursorLocation = computedBaseCursorLocation
            }
        } else {
            lockedDisplayCursorLocation = nil
        }
        let cursorLocation = snap.cursorLocation
        let debugComposing = (text: snap.debugText, focus: snap.focusInfo)
        let marked = visibleMarkedText(text: visibleText)
        let cursor = NSRange(location: cursorLocation, length: 0)
        let replace = NSRange(location: NSNotFound, length: NSNotFound)
        appendRuntimeTrace("setMarkedText selection=\(NSStringFromRange(cursor)) textLength=\(marked.length) markedText=\(marked.string) primaryMarked=\(snap.markedText)")
        input.setMarkedText(marked, selectionRange: cursor, replacementRange: replace)
        let anchor = candidateAnchor(for: input, cursorIndex: cursorLocation) ?? lastKnownCandidateAnchor
        if let anchor {
            lastKnownCandidateAnchor = anchor
        }
        let primaryDisplayText = displayed.map(\.value).joined()
        if !candidates.isEmpty {
            let selectedValue = candidates.indices.contains(selectedCandidateIndex) ? candidates[selectedCandidateIndex] : "nil"
            let focusTrace: String
            if let focus = snap.focusedSegment {
                focusTrace = "focusStart=\(focus.start) focusLength=\(focus.length) focusReading=\(focus.reading) focusValue=\(focus.value)"
            } else {
                focusTrace = "focus=nil"
            }
            appendFocusedTrace("preview.sync selectedIndex=\(selectedCandidateIndex) selectedValue=\(selectedValue) candidateMode=\(candidateMode) primaryDisplay=\(primaryDisplayText) markedText=\(snap.markedText) \(focusTrace) candidates=\(candidates.joined(separator: "|"))")
        }
        appendRuntimeTrace("updateMarkedText composing=\(snap.markedText) primaryDisplay=\(primaryDisplayText) count=\(candidates.count) cursor=\(cursorLocation) lockedCursor=\(String(describing: lockedDisplayCursorLocation)) anchor=\(String(describing: anchor)) candidates=\(candidates.joined(separator: "|")) rawBuffer=\(rawInputBuffer)")
        if visibleText.isEmpty && displayed.isEmpty {
            imeDebugLog("updateMarkedText empty")
            if let textClient = client as? NSTextInputClient {
                textClient.unmarkText()
            }
            CompositionPanelController.shared.hide()
            BasicCandidatePanelController.shared.hide()
            CandidateCaretOverlayController.shared.hide()
            publishIMEState("", anchor: nil)
            IMEUIController.shared.clear()
        } else {
            NSLog("Marked %@ candidates=%@", displayed.map(\.value).joined(), candidates.joined(separator: "|"))
            imeDebugLog("updateMarkedText marked=\(displayed.map(\.value).joined()) candidates=\(candidates.count) values=\(candidates.joined(separator: "|"))")
            let safeIndex = min(selectedCandidateIndex, max(candidates.count - 1, 0))
            switch currentCandidateWindowMode {
            case .basic:
                CompositionPanelController.shared.hide()
                CandidateCaretOverlayController.shared.hide()
                let shouldShowBasicCandidates = basicCandidateWindowRequested && !candidates.isEmpty
                appendFocusedTrace("panel.sync mode=basic selectedIndex=\(selectedCandidateIndex) safeIndex=\(safeIndex) shouldShow=\(shouldShowBasicCandidates) basicRequested=\(basicCandidateWindowRequested) primaryDisplay=\(primaryDisplayText) markedText=\(snap.markedText) candidates=\(candidates.joined(separator: "|"))")
                publishBasicCandidateView(composing: debugComposing.text, candidateEntries: candidateEntries, selectedIndex: safeIndex, anchor: anchor, isVisible: shouldShowBasicCandidates)
                if !shouldShowBasicCandidates {
                    BasicCandidatePanelController.shared.hide()
                } else {
                    BasicCandidatePanelController.shared.show(anchor: anchor, candidateEntries: candidateEntries, selectedIndex: safeIndex)
                }
                IMEUIController.shared.clear()
            case .detailed:
                CandidateCaretOverlayController.shared.hide()
                BasicCandidatePanelController.shared.hide()
                IMEUIController.shared.clear()
                publishIMEProbe(route: lastRouteDebug, input: lastInputDebug, composing: debugComposing.text, candidateEntries: candidateEntries, selectedIndex: safeIndex, focusInfo: debugComposing.focus, anchor: anchor)
                CompositionPanelController.shared.show(
                    text: "組字：\n\(debugComposing.text)",
                    candidateEntries: candidateEntries,
                    selectedIndex: safeIndex,
                    client: input
                )
            }
        }
    }

    private func visibleMarkedText(text: String) -> NSAttributedString {
        let rendered = NSMutableAttributedString(
            string: text,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize),
                .foregroundColor: NSColor.labelColor
            ]
        )
        return rendered
    }

    private func displayCursorLocation(forInsertionIndex insertionIndex: Int, segments: [ComposedSegment]) -> Int {
        CompositionPresentationBuilder.displayCursorLocation(forInsertionIndex: insertionIndex, segments: segments)
    }

    private func currentCompositionCursorIndex() -> Int {
        let total = readings.count
        return max(0, min(total, compositionCursorIndex ?? total))
    }

    private func candidateAnchor(for client: IMKTextInput, cursorIndex: Int) -> CGPoint? {
        if let textClient = client as? NSTextInputClient {
            var actual = NSRange(location: NSNotFound, length: 0)
            let targetRange = NSRange(location: max(cursorIndex, 0), length: 0)
            let rect = textClient.firstRect(forCharacterRange: targetRange, actualRange: &actual)
            appendRuntimeTrace("anchor firstRect cursor=\(cursorIndex) target=\(NSStringFromRange(targetRange)) actual=\(NSStringFromRange(actual)) rect=\(NSStringFromRect(rect))")
            if rect.origin != .zero || rect.size != .zero {
                return CGPoint(x: rect.maxX, y: rect.minY)
            }
        }

        var cursorRect = NSRect(x: 0, y: 0, width: 16, height: 16)
        client.attributes(forCharacterIndex: cursorIndex, lineHeightRectangle: &cursorRect)
        appendRuntimeTrace("anchor attrRect cursor=\(cursorIndex) rect=\(NSStringFromRect(cursorRect))")
        if cursorRect.origin != .zero || cursorRect.size != .zero {
            return CGPoint(x: cursorRect.maxX, y: cursorRect.minY)
        }

        var lineHeightRect = NSRect(x: 0, y: 0, width: 16, height: 16)
        var queryIndex = cursorIndex > 0 ? cursorIndex - 1 : 0
        let originalQueryIndex = queryIndex
        while lineHeightRect.origin.x == 0 && lineHeightRect.origin.y == 0 && queryIndex >= 0 {
            client.attributes(forCharacterIndex: queryIndex, lineHeightRectangle: &lineHeightRect)
            queryIndex -= 1
        }
        appendRuntimeTrace("anchor fallbackRect cursor=\(cursorIndex) queryIndex=\(queryIndex) rect=\(NSStringFromRect(lineHeightRect))")
        guard lineHeightRect.origin != .zero || lineHeightRect.size != .zero else { return nil }
        let resolvedIndex = queryIndex + 1
        let skippedCount = max(0, originalQueryIndex - resolvedIndex + 1)
        let inferredX = lineHeightRect.maxX + CGFloat(skippedCount) * fallbackCandidateAdvanceX
        appendRuntimeTrace("anchor fallbackAdvance cursor=\(cursorIndex) resolvedIndex=\(resolvedIndex) skipped=\(skippedCount) inferredX=\(inferredX)")
        return CGPoint(x: inferredX, y: lineHeightRect.minY)
    }

    private func currentMarkedRange(for client: Any!) -> NSRange {
        guard let textClient = client as? NSTextInputClient else {
            return NSRange(location: NSNotFound, length: NSNotFound)
        }
        let marked = textClient.markedRange()
        return marked.location == NSNotFound
            ? NSRange(location: NSNotFound, length: NSNotFound)
            : marked
    }

    private func clearMarkedText(_ client: Any!) {
        traceState("clearMarkedText.before")
        basicCandidateWindowRequested = false
        guard let input = client as? IMKTextInput else { return }
        let empty = NSRange(location: 0, length: 0)
        let replace = currentMarkedRange(for: client)
        input.setMarkedText("", selectionRange: empty, replacementRange: replace)
        if let textClient = client as? NSTextInputClient {
            textClient.unmarkText()
        }
        CompositionPanelController.shared.hide()
        BasicCandidatePanelController.shared.hide()
        CandidateCaretOverlayController.shared.hide()
        publishIMEState("", anchor: nil)
        IMEUIController.shared.clear()
        traceState("clearMarkedText.after")
    }

    private func clearComposition(_ client: Any!) {
        traceState("clearComposition.before")
        resetSelectionSentenceTracking()
        resetRawReplayState()
        readings = []
        trailingReadings = []
        currentReading = ""
        compositionCursorIndex = nil
        rawReadingSymbols = []
        selectedCandidateIndex = 0
        selectedCandidateTextHint = nil
        candidateMode = false
        basicCandidateWindowRequested = false
        segmentOverrides = [:]
        explicitLockedKeys = []
        clearPreviewSegmentOverrides()
        mergedCompositionActive = false
        detectedEnglishCandidates = []
        pendingMergeWorkItem?.cancel()
        pendingMergeWorkItem = nil
        targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
        clearCompositionUndoStack()
        clearMarkedText(client)
        traceState("clearComposition.after")
    }

    private func commitRawText(_ text: String, client: Any!) {
        guard let input = client as? IMKTextInput, !text.isEmpty else { return }
        guard shouldAllowRawCommit(text, reason: pendingRawCommitReason) else { return }
        let printableScalars = text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard !printableScalars.isEmpty else { return }
        if hasComposition {
            commitCurrentComposition(client, reason: pendingRawCommitReason)
        }
        input.insertText(text, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
    }

    private func handleNumericPadInput(_ event: NSEvent, client: Any!) -> Bool {
        guard !shouldTreatAsArrowLike(event) else { return false }
        if event.modifierFlags.contains(.numericPad),
           let chars = event.characters, !chars.isEmpty {
            pendingRawCommitReason = "numericPad"
            commitRawText(chars, client: client)
            return true
        }
        return false
    }

    private func handleShiftedPunctuation(_ event: NSEvent, client: Any!) -> Bool {
        guard event.modifierFlags.contains(.shift),
              let chars = event.characters, chars.count == 1 else { return false }
        if let mapped = Self.directPunctuationMap[chars] {
            pendingRawCommitReason = "shiftedPunctuation"
            commitRawText(mapped, client: client)
            return true
        }
        return false
    }

    private func handleShiftedPassthrough(_ event: NSEvent, client: Any!) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        guard modifiers == [.shift] else { return false }
        guard !shouldTreatAsArrowLike(event) else { return false }
        let committed: String?
        if let mapped = qwertyLetterByKeyCode[event.keyCode],
           mapped.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) {
            committed = mapped.uppercased()
        } else if let rawChars = event.charactersIgnoringModifiers?.lowercased(),
                  rawChars.count == 1,
                  rawChars.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.letters.contains($0) && !CharacterSet.controlCharacters.contains($0) }) {
            committed = rawChars.uppercased()
        } else {
            committed = nil
        }
        guard let committed else { return false }
        pendingRawCommitReason = "shiftedPassthrough"
        commitRawText(committed, client: client)
        return true
    }

    private func handleDirectPunctuation(_ event: NSEvent, client: Any!) -> Bool {
        guard let chars = event.characters, chars.count == 1 else { return false }
        guard !shouldTreatAsArrowLike(event) else { return false }
        if let mapped = Self.directPunctuationMap[chars] {
            pendingRawCommitReason = "directPunctuation"
            commitRawText(mapped, client: client)
            return true
        }
        return false
    }

    private func rememberEvent(_ event: NSEvent, chars: String, rawChars: String, modifiers: NSEvent.ModifierFlags) {
        recentEvents.append(InputEventSnapshot(
            keyCode: event.keyCode,
            chars: chars,
            raw: rawChars,
            modifiers: modifiers,
            timestamp: Date().timeIntervalSince1970
        ))
        if recentEvents.count > 8 {
            recentEvents.removeFirst(recentEvents.count - 8)
        }
    }

    private func shouldTreatAsArrowLike(_ event: NSEvent) -> Bool {
        if (123...126).contains(Int(event.keyCode)) { return true }
        let arrowSet = CharacterSet(charactersIn: String(UnicodeScalar(NSUpArrowFunctionKey)!) + String(UnicodeScalar(NSDownArrowFunctionKey)!) + String(UnicodeScalar(NSLeftArrowFunctionKey)!) + String(UnicodeScalar(NSRightArrowFunctionKey)!))
        if let raw = event.charactersIgnoringModifiers,
           raw.unicodeScalars.contains(where: { arrowSet.contains($0) }) {
            return true
        }
        return false
    }

    private func shouldSuppressRawCommitFromRecentQueue() -> Bool {
        let now = Date().timeIntervalSince1970
        return recentEvents.suffix(3).contains { snapshot in
            now - snapshot.timestamp < 0.6 &&
            ((123...126).contains(Int(snapshot.keyCode)) ||
             snapshot.raw.unicodeScalars.contains(where: {
                 let arrowSet = CharacterSet(charactersIn: String(UnicodeScalar(NSUpArrowFunctionKey)!) + String(UnicodeScalar(NSDownArrowFunctionKey)!) + String(UnicodeScalar(NSLeftArrowFunctionKey)!) + String(UnicodeScalar(NSRightArrowFunctionKey)!))
                 return arrowSet.contains($0)
             }))
        }
    }

    private func shouldAllowRawCommit(_ text: String, reason: String) -> Bool {
        if shouldSuppressRawCommitFromRecentQueue() {
            appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) queue=arrowLike")
            return false
        }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) controlCharacter")
            return false
        }
        let allowsMappedNonASCII = (reason == "directPunctuation" || reason == "shiftedPunctuation")
        if !allowsMappedNonASCII && text.unicodeScalars.contains(where: { !$0.isASCII }) {
            let arrowSet = CharacterSet(charactersIn: String(UnicodeScalar(NSUpArrowFunctionKey)!) + String(UnicodeScalar(NSDownArrowFunctionKey)!) + String(UnicodeScalar(NSLeftArrowFunctionKey)!) + String(UnicodeScalar(NSRightArrowFunctionKey)!))
            if text.unicodeScalars.contains(where: { arrowSet.contains($0) }) {
                appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) functionArrowScalar")
                return false
            }
        }
        if reason == "numericPad" {
            let allowed = text.unicodeScalars.allSatisfy { Self.numericPadAllowedSet.contains($0) }
            if !allowed {
                appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) numericPadDisallowed")
                return false
            }
        } else if allowsMappedNonASCII {
            let allowed = text.unicodeScalars.allSatisfy {
                Self.allowedCandidatePunctuation.contains($0) || Self.rawCommitPrintableSet.contains($0)
            }
            if !allowed {
                appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) punctuationDisallowed")
                return false
            }
        } else {
            let allowed = text.unicodeScalars.allSatisfy { Self.rawCommitPrintableSet.contains($0) }
            if !allowed {
                appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) nonPrintableRaw")
                return false
            }
        }
        if candidateMode && hasComposition && reason == "numericPad" {
            appendRuntimeTrace("rawCommit blocked reason=\(reason) text=\(text) candidateModeActive")
            return false
        }
        return true
    }

    private var hasComposition: Bool {
        !readings.isEmpty || !currentReading.isEmpty || !rawInputTokens.isEmpty
    }

    private var allReadings: [String] {
        readings + trailingReadings
    }

    private var joinedReading: String {
        allReadings.joined()
    }

    private var activeCandidates: [String] {
        let final = snapshot().candidateEntries.map(\.text)
        appendRuntimeTrace("activeCandidates readings=\(allReadings.joined(separator: "/")) current=\(currentReading) final=\(final.joined(separator: "|"))")
        return final
    }

    private var activeCandidateEntries: [CandidateEntry] {
        let final = snapshot().candidateEntries
        appendRuntimeTrace("activeCandidates readings=\(allReadings.joined(separator: "/")) current=\(currentReading) final=\(final.map(\.text).joined(separator: "|"))")
        return final
    }

    static func actualCandidateCursorIndex(cursor: Int, totalReadings: Int) -> Int {
        guard totalReadings > 0 else { return 0 }
        if cursor >= totalReadings {
            return totalReadings - 1
        }
        if cursor > 0 {
            return cursor - 1
        }
        return 0
    }

    static func candidatesAtReadingLocation(in readings: [String], readingIndex: Int) -> [String] {
        guard !readings.isEmpty else { return [] }
        let target = max(0, min(readings.count - 1, readingIndex))
        var spans: [(start: Int, end: Int, combined: String)] = []
        for start in stride(from: target, through: 0, by: -1) {
            var combined = ""
            for end in start..<readings.count {
                combined += readings[end]
                if start <= target && target < (end + 1) {
                    spans.append((start, end + 1, combined))
                }
            }
        }
        spans.sort {
            let lhsLength = $0.end - $0.start
            let rhsLength = $1.end - $1.start
            if lhsLength != rhsLength { return lhsLength > rhsLength }
            return $0.start > $1.start
        }
        var merged: [String] = []
        for span in spans {
            let candidates = resolveCandidates(for: span.combined)
            guard candidates != [span.combined] else { continue }
            for value in candidates where !merged.contains(value) {
                merged.append(value)
            }
        }
        return merged
    }

    static func candidatesCoveringFocus(in readings: [String], focus: ComposedSegment) -> [String] {
        guard !readings.isEmpty else { return [] }
        let focusStart = focus.start
        let focusEnd = focus.start + focus.length
        var merged: [String] = []

        // Match refCode behavior more closely: exact candidates for the focused
        // segment should come first, before any overlapping shorter/longer spans.
        let exactFocusCandidates = resolveCandidates(for: focus.reading)
        if exactFocusCandidates != [focus.reading] {
            for value in exactFocusCandidates where !merged.contains(value) {
                merged.append(value)
            }
        }

        // Match vChewing / 小麥注音 span behavior more closely:
        // when the focused span is a single syllable, only expose that
        // syllable's own candidates. Do not let longer overlapping phrases
        // compete with a single-syllable selection.
        if focus.length == 1 {
            return merged
        }

        for start in stride(from: focusStart, through: 0, by: -1) {
            var combined = ""
            for end in start..<readings.count {
                combined += readings[end]
                let segmentEnd = end + 1
                let coversFocus = start < focusEnd && segmentEnd > focusStart
                guard coversFocus else { continue }
                let candidates = resolveCandidates(for: combined)
                guard candidates != [combined] else { continue }
                for value in candidates where !merged.contains(value) {
                    merged.append(value)
                }
            }
        }

        return merged
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
        profileRuntime("session.rankCandidates", details: "candidates=\(candidates.count) span=\(spanLength)") {
            let tokens = allReadings.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
            let context = CandidateSelectionContext(
                languageID: traditionalChineseProvider.languageID,
                allTokens: tokens,
                combinedToken: combinedReading,
                spanLength: spanLength,
                precedingValues: precedingValues,
                followingTokens: followingReadings.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) },
                focusedToken: focusedReading
            )
            let langID = traditionalChineseProvider.languageID
            let units = candidates.enumerated().map { offset, value in
                CandidateUnit(
                    languageID: langID,
                    surface: value,
                    readingOrToken: combinedReading,
                    spanStart: 0,
                    spanLength: spanLength,
                    providerScore: Double(-offset),
                    baseRank: offset
                )
            }
            let modelScores = candidateRanker.scores(units: units, context: context)
            let ranked = zip(units, modelScores)
                .map { unit, modelScore in
                    let value = unit.surface
                    let userFreq = UserFrequencyStore.frequency(languageID: langID, reading: combinedReading, surface: value)
                    let userBoost = userFreq > 0 ? min(Double(userFreq) * 600.0, 10000.0) : 0.0
                    return RankedCandidate(unit: unit, score: modelScore + userBoost)
                }
                .sorted {
                    if $0.score == $1.score {
                        return $0.unit.baseRank < $1.unit.baseRank
                    }
                    return $0.score > $1.score
                }
                .map(\.unit.surface)
            return ranked
        }
    }

    private var composingBuffer: String {
        snapshot().markedText
    }

    private func finalizePendingReadingForCommit() {
        var state = unifiedState()
        UnifiedCompositionEngine.finalizePendingReadingForCommit(state: &state)
        applyUnifiedState(state)
        rebaseRawReplayOnCurrentState()
    }

    private func handleBackspace() {
        traceState("handleBackspace.entry")
        var state = unifiedState()
        UnifiedCompositionEngine.pressBackspace(state: &state)
        applyUnifiedState(state)
        rebaseRawReplayOnCurrentState()
        traceState("handleBackspace.exit")
    }

    private func handleDeleteForward() {
        traceState("handleDeleteForward.entry")
        appendFocusedTrace("handleDeleteForward.before cursor=\(currentCompositionCursorIndex()) readings=\(readings.joined(separator: "/")) current=\(currentReading) composing=\(composingBuffer)")
        let deleteIndex = max(0, min(readings.count, currentCompositionCursorIndex()))
        appendFocusedTrace("handleDeleteForward.deleteIndex=\(deleteIndex) readingsCount=\(readings.count)")
        var state = unifiedState()
        UnifiedCompositionEngine.pressDeleteForward(state: &state)
        applyUnifiedState(state)
        rebaseRawReplayOnCurrentState()
        appendFocusedTrace("handleDeleteForward.after cursor=\(currentCompositionCursorIndex()) readings=\(readings.joined(separator: "/")) current=\(currentReading) composing=\(composingBuffer)")
        traceState("handleDeleteForward.exit")
    }

    private func commitCurrentComposition(_ client: Any!, reason: String) {
        traceState("commitCurrentComposition.before reason=\(reason)")
        guard hasComposition else { return }
        lastCommitReason = reason
        guard let input = client as? IMKTextInput else { return }
        let snap = snapshot()
        let output = snap.markedText
        let replaceRange = currentMarkedRange(for: client)
        let candidates = snap.candidateEntries.map(\.text)
        let selectedValue = candidates.indices.contains(selectedCandidateIndex) ? candidates[selectedCandidateIndex] : "nil"
        let focusTrace: String
        if let focus = snap.focusedSegment {
            focusTrace = "focusStart=\(focus.start) focusLength=\(focus.length) focusReading=\(focus.reading) focusValue=\(focus.value)"
        } else {
            focusTrace = "focus=nil"
        }
        appendFocusedTrace("commit.sync reason=\(reason) selectedIndex=\(selectedCandidateIndex) selectedValue=\(selectedValue) candidateMode=\(candidateMode) output=\(output) markedText=\(snap.markedText) \(focusTrace) candidates=\(candidates.joined(separator: "|"))")
        appendRuntimeTrace("commitCurrentComposition output=\(output) rawBuffer=\(rawInputBuffer)")
        NSLog("Committing readings %@ current=%@ -> %@", allReadings.joined(separator: " / "), currentReading, output)

        // Record auto-confirmed segments only. Explicitly locked selections
        // were already recorded at selection time.
        for seg in snap.displayedSegments {
            let key = CompositionSegmentKey(start: seg.start, length: seg.length, reading: seg.reading)
            guard !explicitLockedKeys.contains(key) else { continue }
            UserFrequencyStore.record(languageID: seg.languageID, reading: seg.reading, surface: seg.value)
        }

        resetRawReplayState()
        readings = []
        trailingReadings = []
        currentReading = ""
        compositionCursorIndex = nil
        rawReadingSymbols = []
        selectedCandidateIndex = 0
        selectedCandidateTextHint = nil
        candidateMode = false
        basicCandidateWindowRequested = false
        segmentOverrides = [:]
        explicitLockedKeys = []
        previewSegmentOverrides = [:]
        mergedCompositionActive = false
        pendingMergeWorkItem?.cancel()
        pendingMergeWorkItem = nil
        targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
        recentEvents.removeAll()
        clearCompositionUndoStack()
        clearMarkedText(client)
        publishIMEState("")

        input.insertText(output, replacementRange: replaceRange)
        resetSelectionSentenceTracking()
        traceState("commitCurrentComposition.after reason=\(reason)")
    }

    enum CandidateConfirmResult {
        case failed
        case confirmed
        case confirmedAndReachedEnd
    }

    /// Unified entry point: lock the chosen candidate, optionally advance cursor to next segment.
    /// Returns `.confirmedAndReachedEnd` when advance moves past the last segment (caller should auto-commit).
    @discardableResult
    private func applyCandidateSelection(index: Int, advance: Bool) -> CandidateConfirmResult {
        let snap = snapshot()
        let candidates = snap.candidateEntries.map(\.text)
        guard snap.candidateEntries.indices.contains(index),
              let focus = snap.focusedSegment else { return .failed }
        let selectionReadings = allReadings
        let selectionSegments = snap.displayedSegments
        let selectionText = snap.markedText
        let selectionEntries = snap.candidateEntries
        let entry = snap.candidateEntries[index]
        let chosen = entry.text
        let candidateTrace = candidates.joined(separator: "|")
        appendFocusedTrace("commitCandidate.before focusStart=\(focus.start) focusLength=\(focus.length) focusReading=\(focus.reading) focusValue=\(focus.value) chosen=\(chosen) advance=\(advance) candidates=\(candidateTrace)")
        var state = unifiedState()
        let focusRange = focus.start..<(focus.start + focus.length)
        let previewSegments = snap.displayedSegments.filter { segment in
            let segmentRange = segment.start..<(segment.start + segment.length)
            return segmentRange.lowerBound < focusRange.upperBound && focusRange.lowerBound < segmentRange.upperBound
        }
        if previewSegments.isEmpty {
            state.segmentOverrides[entry.replacementKey] = chosen
            state.explicitLockedKeys.insert(entry.replacementKey)
        } else {
            applyLockedPreviewSegments(previewSegments, replacingRange: focusRange, to: &state)
        }
        state.selectedCandidateIndex = 0

        var reachedEnd = false
        if advance {
            // Re-predict after commit to get updated segments, then advance.
            let updatedPrediction = UnifiedCompositionEngine.predict(state)
            reachedEnd = UnifiedCompositionEngine.advanceCursorToNextSegment(
                segments: updatedPrediction.presentation.displayedSegments,
                state: &state
            )
        }

        applyUnifiedState(state)
        previewSegmentOverrides = Dictionary(uniqueKeysWithValues: previewSegments.map {
            (CompositionSegmentKey(start: $0.start, length: $0.length, reading: $0.reading), $0.value)
        })
        invalidateSnapshot()
        rebaseRawReplayOnCurrentState()
        let updatedSnap = snapshot()
        let overrideTrace = state.segmentOverrides.map { "\($0.key.start):\($0.key.length):\($0.key.reading)=\($0.value)" }.sorted().joined(separator: "|")
        let segmentTrace = updatedSnap.displayedSegments.map { "\($0.start):\($0.length):\($0.reading)=\($0.value)" }.joined(separator: " || ")
        appendFocusedTrace("commitCandidate.after advance=\(advance) reachedEnd=\(reachedEnd) overrides=\(overrideTrace) segments=\(segmentTrace)")
        logUserSelection(
            allReadings: selectionReadings,
            focus: focus,
            candidates: candidates,
            candidateEntries: selectionEntries,
            displayedSegments: selectionSegments,
            compositionText: selectionText,
            chosenIndex: index,
            chosen: chosen
        )
        UserFrequencyStore.record(languageID: focus.languageID, reading: focus.reading, surface: chosen)
        selectedCandidateIndex = 0
        candidateMode = false
        return reachedEnd ? .confirmedAndReachedEnd : .confirmed
    }

    func didChooseCandidate(index: Int) {
        let snap = snapshot()
        let focusTrace: String
        if let focus = snap.focusedSegment {
            focusTrace = "focusStart=\(focus.start) focusLength=\(focus.length) focusReading=\(focus.reading) focusValue=\(focus.value)"
        } else {
            focusTrace = "focus=nil"
        }
        appendFocusedTrace("didChooseCandidate uiIndex=\(index) selectedBefore=\(selectedCandidateIndex) candidateModeBefore=\(candidateMode) \(focusTrace)")
        appendFocusedTrace("didChooseCandidate applyIndex=\(index)")
        pushCompositionUndoSnapshot()
        let result = applyCandidateSelection(index: index, advance: false)
        guard result != .failed else { return }
        candidateMode = false
        basicCandidateWindowRequested = false
        if let client = self.client() {
            updateMarkedText(client)
        }
    }

    private func logUserSelection(
        allReadings: [String],
        focus: ComposedSegment,
        candidates: [String],
        candidateEntries: [CandidateEntry],
        displayedSegments: [ComposedSegment],
        compositionText: String,
        chosenIndex: Int,
        chosen: String
    ) {
        let top1 = candidates.first ?? ""
        let focusEnd = focus.start + focus.length
        let precedingValues = displayedSegments
            .filter { $0.start + $0.length <= focus.start }
            .map(\.value)
        let followingSegments = displayedSegments
            .filter { $0.start >= focusEnd }
        let followingValues = followingSegments.map(\.value)
        let followingReadings = Array(allReadings.dropFirst(min(focusEnd, allReadings.count)))
        let tokenLanguages = allReadings.indices.map { index in
            displayedSegments.first(where: {
                $0.start <= index && index < $0.start + $0.length
            })?.languageID ?? Self.traditionalChineseProvider.languageID
        }
        let segmentPayloads: [[String: Any]] = displayedSegments.map { segment in
            [
                "language_id": segment.languageID,
                "reading": segment.reading,
                "surface": segment.value,
                "start": segment.start,
                "length": segment.length,
            ]
        }
        let contextValues = allReadings + displayedSegments.map(\.value) + candidates
        let containsLatin = contextValues.contains { value in
            value.unicodeScalars.contains { scalar in
                (65...90).contains(Int(scalar.value)) || (97...122).contains(Int(scalar.value))
            }
        }
        selectionSequence += 1
        let payload: [String: Any] = [
            "schema_version": 2,
            "event_id": UUID().uuidString,
            "session_id": selectionSessionID,
            "sentence_id": selectionSentenceID,
            "selection_sequence": selectionSequence,
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "record_source": "runtime_user_selection",
            "language_id": focus.languageID,
            "reading": focus.reading,
            "surface": chosen,
            "chosen_index": chosenIndex,
            "top1": top1,
            "top1_changed": top1 != chosen,
            "candidates": Array(candidates.prefix(visibleCandidateLimit)),
            "candidate_languages": Array(candidateEntries.map(\.languageID).prefix(visibleCandidateLimit)),
            "span_start": focus.start,
            "span_length": focus.length,
            "all_readings": allReadings,
            "token_languages": tokenLanguages,
            "preceding_values": Array(precedingValues.suffix(3)),
            "following_readings": followingReadings,
            "following_values": Array(followingValues.prefix(3)),
            "composition_text": compositionText,
            "segments": segmentPayloads,
            "mixed_context": containsLatin,
        ]
        appendJSONL(payload, to: userSelectionLogURL)
        if top1 != chosen {
            appendJSONL(payload, to: regressionBacklogURL)
        }
    }

    static func mapKeySequence(_ chars: String) -> String? {
        let mapped = chars.compactMap { bopomofoMap[String($0)] }
        guard !mapped.isEmpty, mapped.count == chars.count else { return nil }
        return mapped.joined()
    }

    static func resolveCandidates(for buffer: String) -> [String] {
        traditionalChineseProvider.resolveCandidates(for: buffer)
    }

    static func isDisplayableCandidate(_ candidate: String) -> Bool {
        LexiconStore.isDisplayableCandidate(candidate)
    }

    private static func shouldAutoCommit(current: String, incoming: String) -> Bool {
        false
    }

    static func shouldFinalizeCurrentReading(current: String, incoming: String) -> Bool {
        guard !current.isEmpty else { return false }
        guard incoming.unicodeScalars.count == 1, let scalar = incoming.unicodeScalars.first else { return false }
        if toneMarks.contains(scalar) {
            let currentState = analyzeSyllablePrefix(current)
            let continuedState = analyzeSyllablePrefix(current + incoming)
            if continuedState.possible {
                return false
            }
            return currentState.complete
        }
        guard syllableStarters.contains(scalar) else { return false }
        let currentState = analyzeSyllablePrefix(current)
        guard currentState.complete else { return false }
        let continuedState = analyzeSyllablePrefix(current + incoming)
        return !continuedState.possible
    }

    private struct SyllablePrefixState {
        let possible: Bool
        let complete: Bool
    }

    private static func analyzeSyllablePrefix(_ reading: String) -> SyllablePrefixState {
        guard !reading.isEmpty else { return .init(possible: false, complete: false) }
        let chars = reading.map(String.init)
        let toneCount = chars.filter { toneMarks.contains($0.unicodeScalars.first!) }.count
        if toneCount > 1 { return .init(possible: false, complete: false) }
        if toneCount == 1 {
            guard let last = chars.last,
                  toneMarks.contains(last.unicodeScalars.first!),
                  chars.count > 1 else {
                return .init(possible: false, complete: false)
            }
            let base = chars.dropLast().joined()
            let baseState = analyzeSyllablePrefix(base)
            return .init(possible: baseState.complete, complete: baseState.complete)
        }

        var index = 0
        let onset: String?
        if let first = chars.first, initials.contains(first.unicodeScalars.first!) {
            onset = first
            index = 1
        } else {
            onset = nil
        }

        let remain = Array(chars[index...])
        if remain.isEmpty {
            if let onset {
                return .init(possible: true, complete: syllabicInitialSet.contains(onset))
            }
            return .init(possible: false, complete: false)
        }

        if let first = remain.first, medialSet.contains(first) {
            if remain.count == 1 {
                return .init(possible: true, complete: true)
            }
            guard remain.count == 2, let allowed = allowedFinalsAfterMedial[first], allowed.contains(remain[1]) else {
                return .init(possible: false, complete: false)
            }
            return .init(possible: true, complete: true)
        }

        if remain.count == 1, finalSet.contains(remain[0]) {
            return .init(possible: true, complete: true)
        }

        return .init(possible: false, complete: false)
    }

    static func resolveCommittedText(allReadings: [String]) -> String {
        if let protected = protectedSegments(for: allReadings) {
            return protected.map(\.value).joined()
        }
        let full = allReadings.joined()
        if let override = overrideCharacterMap[full]?.first {
            return override
        }
        let exact = resolveCandidates(for: full)
        if exact != [full], let first = exact.first {
            return first
        }
        return resolveWalk(allReadings).map(\.value).joined()
    }

    static func resolveWalk(_ readings: [String]) -> [ComposedSegment] {
        traditionalChineseProvider.resolveComposition(
            tokens: readings.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
        )
    }

    private var hasIncompleteCurrentReading: Bool {
        !currentReading.isEmpty && !Self.analyzeSyllablePrefix(currentReading).complete
    }

    private func protectedSegmentsRespectingOverrides(for allReadings: [String]) -> [ComposedSegment]? {
        guard !allReadings.isEmpty else { return nil }
        guard allReadings.allSatisfy({ Self.numericProtectedValue(for: $0) != nil }) else { return nil }
        let values = allReadings.enumerated().compactMap { index, reading -> ComposedSegment? in
            let key = CompositionSegmentKey(start: index, length: 1, reading: reading)
            let lockedValue: String?
            if explicitLockedKeys.contains(key) {
                lockedValue = segmentOverrides[key]
            } else {
                lockedValue = nil
            }
            guard let value = lockedValue ?? Self.numericProtectedValue(for: reading) else { return nil }
            return ComposedSegment(
                languageID: Self.traditionalChineseProvider.languageID,
                reading: reading,
                value: value,
                start: index,
                length: 1
            )
        }
        return values.count == allReadings.count ? values : nil
    }

    private static func protectedSegments(for allReadings: [String]) -> [ComposedSegment]? {
        guard !allReadings.isEmpty else { return nil }
        guard allReadings.allSatisfy({ numericProtectedValue(for: $0) != nil }) else { return nil }
        let values = allReadings.enumerated().compactMap { index, reading -> ComposedSegment? in
            guard let value = numericProtectedValue(for: reading) else { return nil }
            return ComposedSegment(
                languageID: traditionalChineseProvider.languageID,
                reading: reading,
                value: value,
                start: index,
                length: 1
            )
        }
        return values.count == allReadings.count ? values : nil
    }

    private static func numericProtectedValue(for reading: String) -> String? {
        switch reading {
        case "ㄧ", "ㄧ˙", "ㄧˋ", "ㄧˊ", "ㄧˇ": return "一"
        case "ㄦˋ": return "二"
        case "ㄙㄢ", "ㄙㄢ˙": return "三"
        case "ㄙˋ": return "四"
        case "ㄨˇ": return "五"
        case "ㄌㄧㄡˋ": return "六"
        case "ㄑㄧ": return "七"
        case "ㄅㄚ": return "八"
        case "ㄐㄧㄡˇ": return "九"
        case "ㄌㄧㄥˊ": return "零"
        default: return nil
        }
    }

    private static func manualSegments(for readings: [String], targetText: String) -> [ComposedSegment]? {
        func consumePrefix(_ text: String, count: Int) -> String {
            String(text.dropFirst(count))
        }

        func resolve(readings: ArraySlice<String>, target: String, start: Int) -> [ComposedSegment]? {
            if readings.isEmpty { return target.isEmpty ? [] : nil }
            guard !target.isEmpty else { return nil }

            let readingArray = Array(readings)
            for spanLength in stride(from: readingArray.count, through: 1, by: -1) {
                let chunk = Array(readingArray.prefix(spanLength))
                let combinedReading = chunk.joined()
                var candidates = resolveCandidates(for: combinedReading)
                let fallback = resolveWalk(chunk).map(\.value).joined()
                if !fallback.isEmpty, !candidates.contains(fallback) {
                    candidates.append(fallback)
                }
                for candidate in candidates where target.hasPrefix(candidate) {
                    let remainder = consumePrefix(target, count: candidate.count)
                    if let tail = resolve(
                        readings: readings.dropFirst(spanLength),
                        target: remainder,
                        start: start + spanLength
                    ) {
                        let segment = ComposedSegment(
                            languageID: traditionalChineseProvider.languageID,
                            reading: combinedReading,
                            value: candidate,
                            start: start,
                            length: spanLength
                        )
                        return [segment] + tail
                    }
                }
            }
            return nil
        }

        return resolve(readings: ArraySlice(readings), target: targetText, start: 0)
    }

    @discardableResult
    private func moveFocus(delta: Int) -> Bool {
        guard currentReading.isEmpty else { return false }
        guard !allReadings.isEmpty else { return false }
        let currentIndex = currentCompositionCursorIndex()
        let next = max(0, min(allReadings.count, currentIndex + delta))
        compositionCursorIndex = next
        selectedCandidateIndex = 0
        candidateMode = false
        return next != currentIndex
    }
}
