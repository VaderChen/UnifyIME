import AppKit

struct IMEProbeSegmentKey: Hashable {
    let start: Int
    let length: Int
    let reading: String
}

final class IMEProbeEngine {
    static let buildMarker = "ime-probe-20260325-1"
    private let primaryTargetID = CompositionLanguageRegistry.targets[0].id

    private struct UndoSnapshot {
        let compositionAnchorCursor: Int?
        let compositionCursorIndex: Int?
        let readings: [String]
        let trailingReadings: [String]
        let currentReading: String
        let rawReadingSymbols: [String]
        let selectedCandidateIndex: Int
        let candidateMode: Bool
        let segmentOverrides: [IMEProbeSegmentKey: String]
        let explicitLockedKeys: Set<IMEProbeSegmentKey>
        let targetState: MultiTargetCompositionState
        let rawTargetState: MultiTargetCompositionState
        let rawInputBuffer: String
        let replayedRawInputBuffer: String
    }

    private var committedBuffer = ""
    private var committedCursor = 0
    private var lastCommittedReadingsDisplay = ""
    private var compositionAnchorCursor: Int?
    private var compositionCursorIndex: Int?
    private var readings: [String] = []
    private var trailingReadings: [String] = []
    private var currentReading = ""
    private var rawReadingSymbols: [String] = []
    private var selectedCandidateIndex = 0
    private var candidateMode = false
    private var segmentOverrides: [IMEProbeSegmentKey: String] = [:]
    private var explicitLockedKeys = Set<IMEProbeSegmentKey>()
    private var lastRawInput = ""
    private var recentInputs: [String] = []
    private var targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
    private var rawTargetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
    private var rawInputBuffer = ""
    private var replayedRawInputBuffer = ""
    private var undoStack: [UndoSnapshot] = []

    private func makeUndoSnapshot() -> UndoSnapshot {
        UndoSnapshot(
            compositionAnchorCursor: compositionAnchorCursor,
            compositionCursorIndex: compositionCursorIndex,
            readings: readings,
            trailingReadings: trailingReadings,
            currentReading: currentReading,
            rawReadingSymbols: rawReadingSymbols,
            selectedCandidateIndex: selectedCandidateIndex,
            candidateMode: candidateMode,
            segmentOverrides: segmentOverrides,
            explicitLockedKeys: explicitLockedKeys,
            targetState: targetState,
            rawTargetState: rawTargetState,
            rawInputBuffer: rawInputBuffer,
            replayedRawInputBuffer: replayedRawInputBuffer
        )
    }

    private func pushUndoSnapshot() {
        undoStack.append(makeUndoSnapshot())
        if undoStack.count > 128 {
            undoStack.removeFirst(undoStack.count - 128)
        }
    }

    private func clearUndoStack() {
        undoStack = []
    }

    @discardableResult
    private func popUndoSnapshot() -> Bool {
        guard let snapshot = undoStack.popLast() else { return false }
        compositionAnchorCursor = snapshot.compositionAnchorCursor
        compositionCursorIndex = snapshot.compositionCursorIndex
        readings = snapshot.readings
        trailingReadings = snapshot.trailingReadings
        currentReading = snapshot.currentReading
        rawReadingSymbols = snapshot.rawReadingSymbols
        selectedCandidateIndex = snapshot.selectedCandidateIndex
        candidateMode = snapshot.candidateMode
        segmentOverrides = snapshot.segmentOverrides
        explicitLockedKeys = snapshot.explicitLockedKeys
        targetState = snapshot.targetState
        rawTargetState = snapshot.rawTargetState
        rawInputBuffer = snapshot.rawInputBuffer
        replayedRawInputBuffer = snapshot.replayedRawInputBuffer
        return true
    }

    private func unifiedState() -> UnifiedCompositionState {
        targetState[primaryTargetID] ?? UnifiedCompositionState(
            readings: readings,
            trailingReadings: trailingReadings,
            currentReading: currentReading,
            compositionCursorIndex: compositionCursorIndex,
            rawReadingSymbols: rawReadingSymbols,
            selectedCandidateIndex: selectedCandidateIndex,
            segmentOverrides: Dictionary(uniqueKeysWithValues: segmentOverrides.map { (CompositionSegmentKey(start: $0.key.start, length: $0.key.length, reading: $0.key.reading), $0.value) }),
            explicitLockedKeys: Set(explicitLockedKeys.map { CompositionSegmentKey(start: $0.start, length: $0.length, reading: $0.reading) })
        )
    }

    private func multiTargetState() -> MultiTargetCompositionState {
        targetState
    }

    private func applyUnifiedState(_ state: UnifiedCompositionState) {
        targetState[primaryTargetID] = state
        readings = state.readings
        trailingReadings = state.trailingReadings
        currentReading = state.currentReading
        compositionCursorIndex = state.compositionCursorIndex
        rawReadingSymbols = state.rawReadingSymbols
        selectedCandidateIndex = state.selectedCandidateIndex
        segmentOverrides = Dictionary(uniqueKeysWithValues: state.segmentOverrides.map { (IMEProbeSegmentKey(start: $0.key.start, length: $0.key.length, reading: $0.key.reading), $0.value) })
        explicitLockedKeys = Set(state.explicitLockedKeys.map { IMEProbeSegmentKey(start: $0.start, length: $0.length, reading: $0.reading) })
    }

    private func applyMultiTargetState(_ state: MultiTargetCompositionState) {
        targetState = state
        guard let primaryState = state[primaryTargetID] else { return }
        applyUnifiedState(primaryState)
    }

    private func recomputeRawSpanMerge() {
        guard !rawInputBuffer.isEmpty else { return }
        guard rawInputBuffer.unicodeScalars.contains(where: { englishMergeTriggerSet.contains($0) }) else { return }
        guard rawInputBuffer.count <= maxMixedRawBufferLength else { return }
        let primaryState = unifiedState()
        let primaryPrediction = unifiedPrediction()
        let resolution = MixedCompositionResolver.resolve(
            rawBuffer: rawInputBuffer,
            primaryTargetID: primaryTargetID,
            primaryLanguageID: SessionCtl.traditionalChineseProvider.languageID,
            primaryBehavior: CompositionLanguageRegistry.primary,
            primaryState: primaryState,
            primarySegments: primaryPrediction.presentation.displayedSegments
        )
        guard let materializedState = resolution.materializedState else { return }
        applyUnifiedState(materializedState)
    }

    private func rebuildTargetsFromRawInputBuffer() {
        let buffer = rawInputBuffer
        guard !buffer.isEmpty else {
            rawTargetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
            replayedRawInputBuffer = ""
            targetState = rawTargetState
            applyMultiTargetState(targetState)
            recomputeRawSpanMerge()
            return
        }

        if buffer.hasPrefix(replayedRawInputBuffer) {
            let suffix = String(buffer.dropFirst(replayedRawInputBuffer.count))
            if !suffix.isEmpty {
                UnifiedCompositionEngine.feedAll(token: suffix, state: &rawTargetState)
            }
        } else {
            rawTargetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
            UnifiedCompositionEngine.feedAll(token: buffer, state: &rawTargetState)
        }
        replayedRawInputBuffer = buffer
        targetState = rawTargetState
        applyMultiTargetState(targetState)
        recomputeRawSpanMerge()
    }

    private func unifiedPrediction() -> UnifiedCompositionPrediction {
        UnifiedCompositionEngine.predict(unifiedState())
    }

    private func feedUnified(token: String) {
        UnifiedCompositionEngine.feedAll(token: token, state: &targetState)
        applyMultiTargetState(targetState)
    }

    private var allReadings: [String] {
        readings + trailingReadings
    }

    private var hasComposition: Bool {
        !readings.isEmpty || !currentReading.isEmpty || !rawInputBuffer.isEmpty
    }

    private func currentCompositionCursorIndex() -> Int {
        let total = readings.count
        return max(0, min(total, compositionCursorIndex ?? total))
    }

    private func protectedSegments(for allReadings: [String]) -> [ComposedSegment]? {
        guard !allReadings.isEmpty else { return nil }
        guard allReadings.allSatisfy({ SessionCtl.protectedNumericReadings.contains($0) }) else { return nil }
        let values = allReadings.enumerated().compactMap { index, reading -> ComposedSegment? in
            let key = IMEProbeSegmentKey(start: index, length: 1, reading: reading)
            let lockedValue: String?
            if explicitLockedKeys.contains(key) {
                lockedValue = segmentOverrides[key]
            } else {
                lockedValue = nil
            }
            guard let value = lockedValue ?? SessionCtl.overrideCharacterMap[reading]?.first else { return nil }
            return ComposedSegment(
                languageID: SessionCtl.traditionalChineseProvider.languageID,
                reading: reading,
                value: value,
                start: index,
                length: 1
            )
        }
        return values.count == allReadings.count ? values : nil
    }

    private func neutralizedReadingIfNeeded(_ reading: String) -> String {
        guard !reading.isEmpty else { return reading }
        let hasTone = reading.contains(where: { "ˇˋˊ˙".contains($0) })
        guard !hasTone else { return reading }
        return reading + "˙"
    }

    private func finalizePendingReadingForCommit() {
        var state = unifiedState()
        UnifiedCompositionEngine.finalizePendingReadingForCommit(state: &state)
        applyUnifiedState(state)
    }

    private func handleBackspace() {
        if !currentReading.isEmpty {
            currentReading.removeLast()
            if currentReading.isEmpty, !trailingReadings.isEmpty {
                readings.append(contentsOf: trailingReadings)
                trailingReadings = []
                compositionCursorIndex = readings.count
            }
            selectedCandidateIndex = 0
            candidateMode = false
            return
        }
        let deleteIndex = max(0, min(readings.count, currentCompositionCursorIndex()))
        guard deleteIndex > 0 else { return }
        var updated = readings
        updated.remove(at: deleteIndex - 1)
        readings = updated
        trailingReadings = []
        currentReading = ""
        compositionCursorIndex = max(0, deleteIndex - 1)
        rawReadingSymbols = updated.joined().map { String($0) }
        selectedCandidateIndex = 0
        candidateMode = false
    }

    private func commitCandidate(index: Int) {
        let prediction = unifiedPrediction()
        let candidateEntries = prediction.presentation.candidateEntries
        guard candidateEntries.indices.contains(index) else { return }
        pushUndoSnapshot()
        let entry = candidateEntries[index]
        var state = unifiedState()
        state.segmentOverrides[entry.replacementKey] = entry.text
        state.explicitLockedKeys.insert(entry.replacementKey)
        state.selectedCandidateIndex = 0
        applyUnifiedState(state)
    }

    private func commitComposition() {
        guard hasComposition else { return }
        if candidateMode, !activeCandidates.isEmpty {
            commitCandidate(index: selectedCandidateIndex)
        }
        finalizePendingReadingForCommit()
        lastCommittedReadingsDisplay = allReadings.map(Self.displayedReading).joined(separator: " / ")
        let output = unifiedPrediction().presentation.markedText
        if !output.isEmpty {
            let originalCursor = committedCursor
            committedCursor = compositionAnchorCursor ?? committedCursor
            insertCommittedText(output)
            if compositionAnchorCursor == nil { committedCursor = originalCursor }
        }
        readings = []
        trailingReadings = []
        currentReading = ""
        compositionCursorIndex = nil
        rawReadingSymbols = []
        rawInputBuffer = ""
        selectedCandidateIndex = 0
        candidateMode = false
        segmentOverrides = [:]
        explicitLockedKeys = []
        compositionAnchorCursor = nil
        targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
        rawTargetState = targetState
        replayedRawInputBuffer = ""
        clearUndoStack()
    }

    private func insertCommittedText(_ text: String) {
        let characters = Array(committedBuffer)
        let safeCursor = max(0, min(characters.count, committedCursor))
        let prefix = String(characters.prefix(safeCursor))
        let suffix = String(characters.dropFirst(safeCursor))
        committedBuffer = prefix + text + suffix
        committedCursor = safeCursor + text.count
    }

    private var activeCandidateEntries: [CandidateEntry] {
        unifiedPrediction().presentation.candidateEntries
    }

    private var activeCandidates: [String] {
        activeCandidateEntries.map(\.text)
    }

    func pressSpace() {
        if !hasComposition {
            insertCommittedText(" ")
            return
        }
        pushUndoSnapshot()
        feedUnified(token: "<space>")
    }

    func pressEnter() {
        commitComposition()
    }

    func chooseCandidate(index: Int) {
        guard index > 0 else { return }
        selectedCandidateIndex = index - 1
        candidateMode = true
        commitCandidate(index: selectedCandidateIndex)
        candidateMode = false
    }

    func moveLeft() {
        if hasComposition {
            pushUndoSnapshot()
            feedUnified(token: "<left>")
        } else {
            committedCursor = max(0, committedCursor - 1)
        }
    }

    func moveRight() {
        if hasComposition {
            pushUndoSnapshot()
            feedUnified(token: "<right>")
        } else {
            committedCursor = min(committedBuffer.count, committedCursor + 1)
        }
    }

    func pressBackspace() {
        if !rawInputBuffer.isEmpty {
            pushUndoSnapshot()
            _ = rawInputBuffer.popLast()
            rebuildTargetsFromRawInputBuffer()
        } else if hasComposition {
            pushUndoSnapshot()
            feedUnified(token: "<backspace>")
        } else if committedCursor > 0 {
            let characters = Array(committedBuffer)
            let deleteIndex = committedCursor - 1
            committedBuffer = String(characters[..<deleteIndex]) + String(characters[(deleteIndex + 1)...])
            committedCursor = deleteIndex
        }
    }

    func pressDeleteForward() {
        if !rawInputBuffer.isEmpty {
            pushUndoSnapshot()
            feedUnified(token: "<delete>")
        } else if hasComposition {
            pushUndoSnapshot()
            feedUnified(token: "<delete>")
        } else if committedCursor < committedBuffer.count {
            let characters = Array(committedBuffer)
            committedBuffer = String(characters[..<committedCursor]) + String(characters[(committedCursor + 1)...])
        }
    }

    func reset() {
        committedBuffer = ""
        committedCursor = 0
        lastCommittedReadingsDisplay = ""
        compositionAnchorCursor = nil
        compositionCursorIndex = nil
        readings = []
        trailingReadings = []
        currentReading = ""
        rawReadingSymbols = []
        rawInputBuffer = ""
        selectedCandidateIndex = 0
        candidateMode = false
        segmentOverrides = [:]
        explicitLockedKeys = []
        targetState = MultiTargetCompositionState(targets: CompositionLanguageRegistry.targets)
        rawTargetState = targetState
        replayedRawInputBuffer = ""
        clearUndoStack()
    }

    func handleStandaloneRawInput(rawChars: String, chars: String? = nil, keyCode: Int? = nil) {
        let chars = chars ?? rawChars
        lastRawInput = "raw=\(rawChars) chars=\(chars) keyCode=\(keyCode.map(String.init) ?? "nil")"
        recentInputs.append(lastRawInput)
        if recentInputs.count > 10 {
            recentInputs.removeFirst(recentInputs.count - 10)
        }
        let token = UnifiedCompositionEngine.token(for: rawChars, chars: chars, keyCode: keyCode)
        switch token {
        case "<esc>":
            _ = popUndoSnapshot()
            return
        case "<backspace>":
            pressBackspace()
            return
        case "<left>":
            moveLeft()
            return
        case "<right>":
            moveRight()
            return
        case "<up>":
            guard !activeCandidates.isEmpty else { return }
            pushUndoSnapshot()
            candidateMode = true
            selectedCandidateIndex = selectedCandidateIndex > 0 ? (selectedCandidateIndex - 1) : (activeCandidates.count - 1)
            return
        case "<down>":
            guard !activeCandidates.isEmpty else { return }
            pushUndoSnapshot()
            candidateMode = true
            selectedCandidateIndex = (selectedCandidateIndex + 1) % activeCandidates.count
            return
        case "<enter>":
            pressEnter()
            return
        case "<space>":
            pressSpace()
            return
        default:
            break
        }

        if !rawChars.isEmpty {
            pushUndoSnapshot()
            if !hasComposition {
                compositionAnchorCursor = committedCursor
            }
            rawInputBuffer.append(rawChars.lowercased())
            rebuildTargetsFromRawInputBuffer()
            let prediction = UnifiedCompositionEngine.predictAll(targetState)
            let materialized = targetState.perTargetStates.values.contains(where: \.hasComposition)
                || !prediction.mergedCandidates.isEmpty
                || !(prediction.topPrediction?.prediction.presentation.markedText ?? "").isEmpty
                || !(prediction.topPrediction?.prediction.presentation.displayedSegments ?? []).isEmpty
            if materialized {
                return
            }
            _ = rawInputBuffer.popLast()
            rebuildTargetsFromRawInputBuffer()
        }
        if let mapped = SessionCtl.directPunctuationMap[chars] {
            if hasComposition {
                pressEnter()
            }
            insertCommittedText(mapped)
            return
        }
        if !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ SessionCtl.rawCommitPrintableSet.contains($0) }) {
            if hasComposition {
                pressEnter()
            }
            insertCommittedText(chars)
        }
    }

    private func displayCursorLocation(forInsertionIndex insertionIndex: Int, segments: [ComposedSegment]) -> Int {
        CompositionPresentationBuilder.displayCursorLocation(forInsertionIndex: insertionIndex, segments: segments)
    }

    private static func displayedReading(_ reading: String) -> String {
        if reading.hasSuffix("˙") { return String(reading.dropLast()) + "-" }
        return reading
    }

    func renderText() -> String {
        let prediction = unifiedPrediction()
        let segments = prediction.presentation.displayedSegments
        let composing = prediction.presentation.markedText
        let visibleCursorLocation = prediction.presentation.cursorLocation
        let committedChars = Array(committedBuffer)
        let anchor = max(0, min(committedChars.count, compositionAnchorCursor ?? committedCursor))
        let prefix = String(committedChars.prefix(anchor))
        let suffix = String(committedChars.dropFirst(anchor))
        let fullText: String
        if hasComposition {
            fullText = prefix + insertCursor(into: composing, at: visibleCursorLocation, marker: "❚") + suffix
        } else {
            let safeCommittedCursor = max(0, min(committedChars.count, committedCursor))
            let committedPrefix = String(committedChars.prefix(safeCommittedCursor))
            let committedSuffix = String(committedChars.dropFirst(safeCommittedCursor))
            fullText = committedPrefix + "❚" + committedSuffix
        }
        let candidateLines = activeCandidateEntries.enumerated().map { index, entry in
            let marker = index == selectedCandidateIndex ? "•" : " "
            return "\(marker)\(index + 1). \(entry.text)"
        }
        let readingLine = (allReadings + (currentReading.isEmpty ? [] : [currentReading])).map(Self.displayedReading).joined(separator: " / ")
        let joined = (allReadings + (currentReading.isEmpty ? [] : [currentReading])).joined()
        let wholeTop = joined.isEmpty ? "（空）" : (SessionCtl.resolveCandidates(for: joined).first ?? "（無）")
        let segmentDebug = segments.map { "\($0.reading)=>\($0.value)" }.joined(separator: " || ")
        return [
            "版本：\(Self.buildMarker)",
            "最後輸入：\(lastRawInput.isEmpty ? "（空）" : lastRawInput)",
            "整段候選：\(wholeTop)",
            "override數：\(segmentOverrides.count)",
            "明確鎖定數：\(explicitLockedKeys.count)",
            "segments：\(segmentDebug.isEmpty ? "（空）" : segmentDebug)",
            "最近按鍵：\(recentInputs.isEmpty ? "（空）" : recentInputs.joined(separator: " || "))",
            "",
            "文字：",
            fullText.isEmpty ? "|" : fullText,
            "",
            "讀音佇列：",
            readingLine.isEmpty ? "（空）" : readingLine,
            "",
            "候選：",
            candidateLines.isEmpty ? "（目前沒有候選）" : candidateLines.joined(separator: "\n"),
        ].joined(separator: "\n")
    }

    private func insertCursor(into text: String, at location: Int, marker: String) -> String {
        let scalars = Array(text)
        let safe = max(0, min(scalars.count, location))
        var result = String(scalars.prefix(safe))
        result.append(marker)
        result.append(contentsOf: scalars.dropFirst(safe))
        return result
    }
}

enum ProbeAction {
    case raw(String)
    case punct(String)
    case shift(String)
    case choose(Int)
    case space
    case enter
    case esc
    case left(Int)
    case right(Int)
    case backspace(Int)
    case delete(Int)
    case up(Int)
    case down(Int)
    case reset
}

extension IMEProbeEngine {
    func commitStandaloneText(_ text: String) {
        if hasComposition {
            pressEnter()
        }
        insertCommittedText(text)
    }

    private func renderedAssertionText() -> String {
        let prediction = unifiedPrediction()
        let composing = prediction.presentation.markedText
        let committedChars = Array(committedBuffer)
        let anchor = max(0, min(committedChars.count, compositionAnchorCursor ?? committedCursor))
        let prefix = String(committedChars.prefix(anchor))
        let suffix = String(committedChars.dropFirst(anchor))
        if hasComposition {
            return prefix + composing + suffix
        }
        return committedBuffer
    }

    var assertionText: String {
        renderedAssertionText()
    }

    var assertionReadings: String {
        let live = (allReadings + (currentReading.isEmpty ? [] : [currentReading])).map(Self.displayedReading).joined(separator: " / ")
        return live.isEmpty ? lastCommittedReadingsDisplay : live
    }

    var assertionHasComposition: Bool {
        hasComposition
    }
}

private func performIMEProbeAction(_ action: ProbeAction, on engine: IMEProbeEngine) {
    switch action {
    case let .raw(raw):
        engine.handleStandaloneRawInput(rawChars: raw.lowercased(), chars: raw, keyCode: nil)
    case let .punct(text):
        engine.commitStandaloneText(text)
    case let .shift(key):
        let shifted = key.uppercased()
        engine.commitStandaloneText(shifted)
    case let .choose(index):
        engine.chooseCandidate(index: index)
    case .space:
        engine.pressSpace()
    case .enter:
        engine.pressEnter()
    case .esc:
        engine.reset()
    case let .left(count):
        for _ in 0..<count { engine.moveLeft() }
    case let .right(count):
        for _ in 0..<count { engine.moveRight() }
    case let .backspace(count):
        for _ in 0..<count { engine.pressBackspace() }
    case let .delete(count):
        for _ in 0..<count { engine.pressDeleteForward() }
    case let .up(count):
        for _ in 0..<count { engine.handleStandaloneRawInput(rawChars: "", chars: "", keyCode: 126) }
    case let .down(count):
        for _ in 0..<count { engine.handleStandaloneRawInput(rawChars: "", chars: "", keyCode: 125) }
    case .reset:
        engine.reset()
    }
}

func imeActionScriptProbe(_ tokens: [String]) -> Int32 {
    guard !tokens.isEmpty else {
        print("usage: ime-action-replay <raw:w|punct:，|shift:a|choose:n|left[:n]|right[:n]|up[:n]|down[:n]|space|enter|backspace[:n]|delete[:n]|esc|reset> ...")
        return 2
    }
    let engine = IMEProbeEngine()
    for (index, token) in tokens.enumerated() {
        guard let action = parseIMEProbeAction(token) else {
            print("invalid action token: \(token)")
            return 2
        }
        performIMEProbeAction(action, on: engine)
        print("=== IME ACTION STEP \(index + 1): \(token) ===")
        print(engine.renderText())
        print("=== END IME ACTION STEP \(index + 1) ===")
    }
    return 0
}

func imeRawFinalProbe(_ rawKeys: [String]) -> Int32 {
    guard !rawKeys.isEmpty else {
        print("usage: ime-raw-final-replay <rawKey1> [rawKey2 ...]")
        return 2
    }
    let engine = IMEProbeEngine()
    for raw in rawKeys {
        engine.handleStandaloneRawInput(rawChars: raw.lowercased(), chars: raw, keyCode: nil)
    }
    let payload: [String: Any] = [
        "text": engine.assertionText,
        "readings": engine.assertionReadings,
        "has_composition": engine.assertionHasComposition,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]),
          let json = String(data: data, encoding: .utf8) else {
        print("{\"text\":\"\",\"readings\":\"\",\"has_composition\":false}")
        return 2
    }
    print(json)
    return 0
}

private func imeProbePayload(for engine: IMEProbeEngine) -> [String: Any] {
    [
        "text": engine.assertionText,
        "readings": engine.assertionReadings,
        "has_composition": engine.assertionHasComposition,
    ]
}

func imeActionBatchProbe(_ rows: [[String: Any]]) -> Int32 {
    for row in rows {
        let rowID = row["row_id"] as? String ?? UUID().uuidString
        let tokens = row["row_keys"] as? [String] ?? []
        let engine = IMEProbeEngine()
        var invalidToken: String?
        for token in tokens {
            guard let action = parseIMEProbeAction(token) else {
                invalidToken = token
                break
            }
            performIMEProbeAction(action, on: engine)
        }
        var payload = imeProbePayload(for: engine)
        payload["row_id"] = rowID
        if let invalidToken {
            payload["error"] = "invalid action token: \(invalidToken)"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            print("{\"row_id\":\"\(rowID)\",\"text\":\"\",\"readings\":\"\",\"has_composition\":false,\"error\":\"serialization failed\"}")
            continue
        }
        print(json)
    }
    if ProcessInfo.processInfo.environment["UNIFYIME_PROFILE_SUMMARY"] == "1" {
        for metric in runtimeProfileSnapshots() {
            let line = String(
                format: "PROFILE %@ samples=%d average_ms=%.3f last_ms=%.3f\n",
                metric.label,
                metric.sampleCount,
                metric.averageMs,
                metric.lastMs
            )
            if let data = line.data(using: .utf8) {
                try? FileHandle.standardError.write(contentsOf: data)
            }
        }
    }
    return 0
}

private func parseIMEProbeAction(_ token: String) -> ProbeAction? {
    if let value = token.split(separator: ":", maxSplits: 1).dropFirst().first {
        let prefix = token.split(separator: ":", maxSplits: 1).first.map(String.init) ?? token
        switch prefix.lowercased() {
        case "raw":
            return .raw(String(value))
        case "punct":
            return .punct(String(value))
        case "shift":
            return .shift(String(value))
        case "choose":
            return .choose(max(1, Int(value) ?? 1))
        case "left":
            return .left(max(1, Int(value) ?? 1))
        case "right":
            return .right(max(1, Int(value) ?? 1))
        case "backspace":
            return .backspace(max(1, Int(value) ?? 1))
        case "delete":
            return .delete(max(1, Int(value) ?? 1))
        case "up":
            return .up(max(1, Int(value) ?? 1))
        case "down":
            return .down(max(1, Int(value) ?? 1))
        default:
            break
        }
    }

    switch token.lowercased() {
    case "space":
        return .space
    case "enter":
        return .enter
    case "esc":
        return .esc
    case "reset":
        return .reset
    case "left":
        return .left(1)
    case "right":
        return .right(1)
    case "backspace":
        return .backspace(1)
    case "delete":
        return .delete(1)
    case "up":
        return .up(1)
    case "down":
        return .down(1)
    case "choose":
        return .choose(1)
    default:
        return nil
    }
}

private final class EnglishActionProbeEngine {
    private var state = UnifiedCompositionState()
    private var committedBuffer = ""
    private let behavior: CompositionLanguageBehavior

    init?(targetID: String = "english-ime") {
        guard let behavior = CompositionLanguageRegistry.targets.first(where: { $0.id == targetID })?.behavior else {
            return nil
        }
        self.behavior = behavior
    }

    private var prediction: UnifiedCompositionPrediction {
        behavior.predict(state)
    }

    var assertionText: String {
        committedBuffer + prediction.presentation.markedText
    }

    var assertionReadings: String {
        let parts = state.readings + (state.currentReading.isEmpty ? [] : [state.currentReading]) + state.trailingReadings
        return parts.joined(separator: " / ")
    }

    var assertionHasComposition: Bool {
        state.hasComposition
    }

    func renderText() -> String {
        let prediction = prediction
        let text = assertionText.isEmpty ? "❚" : assertionText + (assertionHasComposition ? "❚" : "")
        let candidateEntries = prediction.presentation.candidateEntries
        var lines: [String] = []
        lines.append("文字：")
        lines.append(text)
        lines.append("")
        lines.append("讀音佇列：")
        lines.append(assertionReadings.isEmpty ? "（空）" : assertionReadings)
        lines.append("")
        lines.append("候選：")
        if candidateEntries.isEmpty {
            lines.append("（目前沒有候選）")
        } else {
            for (idx, candidate) in candidateEntries.enumerated() {
                let marker = idx == state.selectedCandidateIndex ? "•" : " "
                lines.append("\(marker)\(idx + 1). \(candidate.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func commitComposition() {
        guard state.hasComposition else { return }
        behavior.feed(token: "<enter>", state: &state)
        let output = behavior.predict(state).presentation.markedText
        if !output.isEmpty {
            committedBuffer += output
        }
        state = UnifiedCompositionState()
    }

    private func commitStandaloneText(_ text: String) {
        if state.hasComposition {
            commitComposition()
        }
        committedBuffer += text
    }

    func perform(_ action: ProbeAction) {
        switch action {
        case let .raw(raw):
            behavior.feed(token: raw, state: &state)
        case let .punct(text):
            commitStandaloneText(text)
        case let .shift(key):
            commitStandaloneText(key.uppercased())
        case let .choose(index):
            let candidateEntries = prediction.presentation.candidateEntries
            guard candidateEntries.indices.contains(max(0, index - 1)) else { return }
            state.selectedCandidateIndex = max(0, index - 1)
        case .space:
            if state.hasComposition {
                behavior.feed(token: "<space>", state: &state)
            } else {
                commitStandaloneText(" ")
            }
        case .enter:
            commitComposition()
        case .esc, .reset:
            state = UnifiedCompositionState()
        case let .left(count):
            for _ in 0..<count { behavior.feed(token: "<left>", state: &state) }
        case let .right(count):
            for _ in 0..<count { behavior.feed(token: "<right>", state: &state) }
        case let .backspace(count):
            for _ in 0..<count { behavior.feed(token: "<backspace>", state: &state) }
        case let .delete(count):
            for _ in 0..<count { behavior.feed(token: "<delete>", state: &state) }
        case let .up(count):
            for _ in 0..<count { behavior.feed(token: "<up>", state: &state) }
        case let .down(count):
            for _ in 0..<count { behavior.feed(token: "<down>", state: &state) }
        }
    }
}

func englishActionScriptProbe(_ tokens: [String]) -> Int32 {
    guard !tokens.isEmpty else {
        print("usage: en-ime-action-replay <raw:hello|space|enter|left[:n]|right[:n]|backspace[:n]|delete[:n]|up[:n]|down[:n]|esc|reset> ...")
        return 2
    }
    guard let engine = EnglishActionProbeEngine() else {
        print("english target missing")
        return 2
    }
    for (index, token) in tokens.enumerated() {
        guard let action = parseIMEProbeAction(token) else {
            print("invalid action token: \(token)")
            return 2
        }
        engine.perform(action)
        print("=== EN ACTION STEP \(index + 1): \(token) ===")
        print(engine.renderText())
        print("=== END EN ACTION STEP \(index + 1) ===")
    }
    return 0
}

func englishActionBatchProbe(_ rows: [[String: Any]]) -> Int32 {
    for row in rows {
        let rowID = row["row_id"] as? String ?? UUID().uuidString
        let tokens = row["row_keys"] as? [String] ?? []
        guard let engine = EnglishActionProbeEngine() else {
            print("{\"row_id\":\"\(rowID)\",\"text\":\"\",\"readings\":\"\",\"has_composition\":false,\"error\":\"english target missing\"}")
            continue
        }
        var invalidToken: String?
        for token in tokens {
            guard let action = parseIMEProbeAction(token) else {
                invalidToken = token
                break
            }
            engine.perform(action)
        }
        var payload: [String: Any] = [
            "row_id": rowID,
            "text": engine.assertionText,
            "readings": engine.assertionReadings,
            "has_composition": engine.assertionHasComposition,
        ]
        if let invalidToken {
            payload["error"] = "invalid action token: \(invalidToken)"
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let json = String(data: data, encoding: .utf8) else {
            print("{\"row_id\":\"\(rowID)\",\"text\":\"\",\"readings\":\"\",\"has_composition\":false,\"error\":\"serialization failed\"}")
            continue
        }
        print(json)
    }
    return 0
}
