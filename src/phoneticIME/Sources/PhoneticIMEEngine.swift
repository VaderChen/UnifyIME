import Foundation

final class PhoneticIME {
    func token(for rawChars: String, chars: String? = nil, keyCode: Int? = nil) -> String {
        PhoneticIMECore.token(for: rawChars, chars: chars, keyCode: keyCode)
    }

    func feed(token: String, state: inout UnifiedCompositionState) {
        PhoneticIMECore.feed(token: token, state: &state)
    }

    func feed(rawChars: String, chars: String? = nil, keyCode: Int? = nil, state: inout UnifiedCompositionState) {
        PhoneticIMECore.feed(rawChars: rawChars, chars: chars, keyCode: keyCode, state: &state)
    }

    func predict(_ state: UnifiedCompositionState) -> UnifiedCompositionPrediction {
        PhoneticIMECore.predict(state)
    }

    func commitCandidate(index: Int, state: inout UnifiedCompositionState) -> Bool {
        PhoneticIMECore.commitCandidate(index: index, state: &state)
    }

    func reset(state: inout UnifiedCompositionState) {
        PhoneticIMECore.reset(state: &state)
    }

    func moveCursor(delta: Int, state: inout UnifiedCompositionState) -> Bool {
        PhoneticIMECore.moveCursor(delta: delta, state: &state)
    }

    func pressSpace(state: inout UnifiedCompositionState) {
        PhoneticIMECore.pressSpace(state: &state)
    }

    func pressBackspace(state: inout UnifiedCompositionState) {
        PhoneticIMECore.pressBackspace(state: &state)
    }

    func pressDeleteForward(state: inout UnifiedCompositionState) {
        PhoneticIMECore.pressDeleteForward(state: &state)
    }

    func finalizePendingReadingForCommit(state: inout UnifiedCompositionState) {
        PhoneticIMECore.finalizePendingReadingForCommit(state: &state)
    }

    func resolveCommittedText(allReadings: [String]) -> String {
        PhoneticIMECore.resolveCommittedText(allReadings: allReadings)
    }

    func resolveWalk(_ readings: [String]) -> [ComposedSegment] {
        PhoneticIMECore.resolveWalk(readings)
    }
}

enum PhoneticIMECore {
    private static func rawLength(for reading: String) -> Int {
        let sequence = SessionCtl.keySequence(for: [reading]).replacingOccurrences(of: " ", with: "")
        return max(1, sequence.count)
    }

    static func token(for rawChars: String, chars: String? = nil, keyCode: Int? = nil) -> String {
        switch keyCode {
        case 53: return "<esc>"
        case 51: return "<backspace>"
        case 117: return "<delete>"
        case 123: return "<left>"
        case 124: return "<right>"
        case 126: return "<up>"
        case 125: return "<down>"
        case 36, 76: return "<enter>"
        case 49: return "<space>"
        default:
            return chars ?? rawChars
        }
    }

    static func feed(token: String, state: inout UnifiedCompositionState) {
        let before = isRuntimeTraceEnabled ? baseDisplayedSegments(for: state) : []
        defer {
            if isRuntimeTraceEnabled {
                let after = baseDisplayedSegments(for: state)
                let describe: ([ComposedSegment]) -> String = { $0.map { "\($0.start):\($0.length)=\($0.value)" }.joined(separator: "|") }
                appendRuntimeTrace("segmentTransition token=\(token) before=\(describe(before)) after=\(describe(after)) locked=\(state.explicitLockedKeys.count)")
            }
        }
        switch token {
        case "<esc>":
            reset(state: &state)
            return
        case "<backspace>":
            pressBackspace(state: &state)
            return
        case "<delete>":
            pressDeleteForward(state: &state)
            return
        case "<left>":
            _ = moveCursor(delta: -1, state: &state)
            return
        case "<right>":
            _ = moveCursor(delta: 1, state: &state)
            return
        case "<up>":
            let prediction = predict(state)
            guard !prediction.presentation.candidateEntries.isEmpty else { return }
            state.selectedCandidateIndex = max(0, state.selectedCandidateIndex - 1)
            return
        case "<down>":
            let prediction = predict(state)
            guard !prediction.presentation.candidateEntries.isEmpty else { return }
            state.selectedCandidateIndex = (state.selectedCandidateIndex + 1) % prediction.presentation.candidateEntries.count
            return
        case "<enter>":
            finalizePendingReadingForCommit(state: &state)
            return
        case "<space>":
            pressSpace(state: &state)
            return
        default:
            break
        }

        if let mapped = SessionCtl.mapKeySequence(token.lowercased()) {
            state.invalidateAutomaticDecisions()
            stabilizePrefixBeforeAppend(state: &state)
            if state.pendingRawInput.isEmpty, !state.currentReading.isEmpty {
                state.pendingRawInput = UnifiedCompositionState.sourceInput(for: state.currentReading)
            }
            for (rawKey, symbol) in zip(token.lowercased().map(String.init), mapped.map(String.init)) {
                let reordered = BopomofoOrderCorrection.appending(symbol, to: state.currentReading)
                // 聲調先到但音節不合法時，允許後續按鍵逐步補齊並重排；
                // 無法修復就保留原音節，避免污染下一個音節。
                let pendingTone = state.currentReading.contains { "ˇˋˊ˙".contains($0) }
                if reordered == nil && (pendingTone || SessionCtl.shouldFinalizeCurrentReading(current: state.currentReading, incoming: symbol)) {
                    finalizeCurrentReading(state: &state)
                }
                if state.currentReading.isEmpty,
                   symbol.unicodeScalars.count == 1,
                   let scalar = symbol.unicodeScalars.first,
                   CharacterSet(charactersIn: "ˇˋˊ˙").contains(scalar) {
                    continue
                }
                if state.currentReading.isEmpty {
                    if !state.hasComposition {
                        state.compositionCursorIndex = 0
                    }
                    prepareFocusedSegmentReplacementIfNeeded(state: &state)
                }
                state.currentReading = reordered ?? (state.currentReading + symbol)
                state.pendingRawInput.append(rawKey)
                state.selectedCandidateIndex = 0
                state.rawReadingSymbols = state.readings.joined().map { String($0) }
                if state.currentReading.contains(where: { "ˇˋˊ˙".contains($0) }),
                   BopomofoOrderCorrection.normalize(state.currentReading) != nil {
                    finalizeCurrentReading(state: &state)
                }
            }
        }
    }

    static func feed(rawChars: String, chars: String? = nil, keyCode: Int? = nil, state: inout UnifiedCompositionState) {
        feed(token: token(for: rawChars, chars: chars, keyCode: keyCode), state: &state)
    }

    static func predict(_ state: UnifiedCompositionState) -> UnifiedCompositionPrediction {
        let baseSegments = baseDisplayedSegments(for: state)
        let presentation = CompositionPresentationBuilder.build(
            baseSegments: baseSegments,
            totalReadings: state.allReadings.count,
            insertionIndex: state.currentCompositionCursorIndex(),
            selectedCandidateIndex: state.selectedCandidateIndex,
            visibleCandidateLimit: visibleCandidateLimit
        ) { focus, localFocusReadingIndex in
            if let focus, focus.length == 1 {
                let symbols = SymbolCandidates.values(for: focus.reading)
                if !symbols.isEmpty {
                    let key = CompositionSegmentKey(start: focus.start, length: 1, reading: focus.reading)
                    return symbols.map { CandidateEntry(text: $0, languageID: focus.languageID, replacementKey: key) }
                }
            }
            guard let focus else { return [] }
            var entries = computeActiveCandidateEntries(
                candidateReadings: state.allReadings, walkedSegments: baseSegments,
                focus: focus, preferredReadingIndex: localFocusReadingIndex)
            let literal = CandidateEntry(text: focus.reading, languageID: focus.languageID,
                replacementKey: CompositionSegmentKey(start: focus.start, length: focus.length, reading: focus.reading))
            if literal.isBopomofoLiteral, !entries.contains(where: { $0.identity == literal.identity }) {
                entries.append(literal)
            }
            return entries
        } previewOverrideProvider: { focus, chosen in
            guard chosen.text.count == 1, focus.length > 1, focus.value.count > 1 else { return nil }
            let syllables = UnifiedCompositionEngine.splitReadingIntoSyllables(focus.reading)
            guard syllables.count == focus.length else { return nil }
            let originalChars = Array(focus.value)
            guard originalChars.count >= focus.length else { return nil }
            let readingIndex = chosen.replacementKey.start
            let localOffset = max(0, min(focus.length - 1, readingIndex - focus.start))
            var segments: [ComposedSegment] = []
            if localOffset > 0 {
                segments.append(
                    ComposedSegment(
                        languageID: focus.languageID,
                        reading: syllables.prefix(localOffset).joined(),
                        value: String(originalChars.prefix(localOffset)),
                        start: focus.start,
                        length: localOffset,
                        rawLength: rawLength(for: syllables.prefix(localOffset).joined())
                    )
                )
            }
            segments.append(
                ComposedSegment(
                    languageID: chosen.languageID,
                    reading: syllables[localOffset],
                    value: chosen.text,
                    start: focus.start + localOffset,
                    length: 1,
                    rawLength: rawLength(for: syllables[localOffset])
                )
            )
            let suffixLength = focus.length - localOffset - 1
            if suffixLength > 0 {
                segments.append(
                    ComposedSegment(
                        languageID: focus.languageID,
                        reading: syllables.suffix(suffixLength).joined(),
                        value: String(originalChars.suffix(suffixLength)),
                        start: focus.start + localOffset + 1,
                        length: suffixLength,
                        rawLength: rawLength(for: syllables.suffix(suffixLength).joined())
                    )
                )
            }
            return segments
        }
        return UnifiedCompositionPrediction(
            presentation: state.attachSources(to: presentation)
        )
    }

    static func commitCandidate(index: Int, state: inout UnifiedCompositionState) -> Bool {
        var previewState = state
        previewState.selectedCandidateIndex = index
        let prediction = predict(previewState)
        let candidateEntries = prediction.presentation.candidateEntries
        guard candidateEntries.indices.contains(index),
              prediction.presentation.focusedSegment != nil else {
            return false
        }
        let chosen = candidateEntries[index].text
        let key = candidateEntries[index].replacementKey
        state.segmentOverrides[key] = chosen
        state.explicitLockedKeys.insert(key)
        state.selectedCandidateIndex = 0
        return true
    }

    static func reset(state: inout UnifiedCompositionState) {
        state.readings = []
        state.trailingReadings = []
        state.currentReading = ""
        state.compositionCursorIndex = nil
        state.rawReadingSymbols = []
        state.selectedCandidateIndex = 0
        state.segmentOverrides = [:]
        state.explicitLockedKeys = []
        state.automaticLockedKeys = []
        state.readingRawInputs = []
        state.pendingRawInput = ""
    }

    static func moveCursor(delta: Int, state: inout UnifiedCompositionState) -> Bool {
        guard state.currentReading.isEmpty else { return false }
        guard !state.allReadings.isEmpty else { return false }
        let current = state.currentCompositionCursorIndex()
        let next = max(0, min(state.allReadings.count, current + delta))
        state.compositionCursorIndex = next
        state.selectedCandidateIndex = 0
        return next != current
    }

    static func pressSpace(state: inout UnifiedCompositionState) {
        if !state.currentReading.isEmpty {
            let shouldLockCurrentSegment = state.currentReading.contains(where: { "ˇˋˊ˙".contains($0) })
            let insertionIndex = state.currentCompositionCursorIndex()
            finalizeCurrentReading(state: &state)
            if shouldLockCurrentSegment {
                lockSegment(containingReadingIndex: insertionIndex, state: &state)
            }
        } else if state.hasComposition {
            state.selectedCandidateIndex = 0
        }
    }

    static func pressBackspace(state: inout UnifiedCompositionState) {
        if !state.currentReading.isEmpty {
            if state.pendingRawInput.isEmpty { state.pendingRawInput = UnifiedCompositionState.sourceInput(for: state.currentReading) }
            state.pendingRawInput.removeLast()
            // 重排後仍依實際按鍵順序退格，不能刪除排序後的最後一個注音。
            let original = SessionCtl.mapKeySequence(state.pendingRawInput) ?? ""
            state.currentReading = BopomofoOrderCorrection.normalize(original) ?? original
            if state.currentReading.isEmpty, !state.trailingReadings.isEmpty {
                let restoreCursor = state.readings.count
                state.readings.append(contentsOf: state.trailingReadings)
                state.trailingReadings = []
                state.compositionCursorIndex = restoreCursor
            }
            state.selectedCandidateIndex = 0
            return
        }
        if !state.trailingReadings.isEmpty {
            state.readings.append(contentsOf: state.trailingReadings)
            state.trailingReadings = []
        }
        let deleteIndex = max(0, min(state.readings.count, state.currentCompositionCursorIndex()))
        guard deleteIndex > 0 else { return }
        state.rebaseOverrides(replacing: (deleteIndex - 1)..<deleteIndex, insertedCount: 0)
        state.readings.remove(at: deleteIndex - 1)
        state.currentReading = ""
        state.compositionCursorIndex = max(0, deleteIndex - 1)
        state.rawReadingSymbols = state.readings.joined().map { String($0) }
        state.selectedCandidateIndex = 0
        pruneOverrides(state: &state)
    }

    static func pressDeleteForward(state: inout UnifiedCompositionState) {
        if !state.currentReading.isEmpty {
            // 未完成音節保留；Delete 只刪除插入點右側的已完成音節。
            guard !state.trailingReadings.isEmpty else { return }
            let deleteIndex = state.readings.count
            state.rebaseOverrides(replacing: deleteIndex..<(deleteIndex + 1), insertedCount: 0)
            state.trailingReadings.removeFirst()
            state.rawReadingSymbols = (state.readings.joined() + state.currentReading + state.trailingReadings.joined()).map { String($0) }
            state.selectedCandidateIndex = 0
            pruneOverrides(state: &state)
            return
        }
        if !state.trailingReadings.isEmpty {
            state.readings.append(contentsOf: state.trailingReadings)
            state.trailingReadings = []
        }
        let deleteIndex = max(0, min(state.readings.count, state.currentCompositionCursorIndex()))
        guard deleteIndex < state.readings.count else { return }
        state.rebaseOverrides(replacing: deleteIndex..<(deleteIndex + 1), insertedCount: 0)
        state.readings.remove(at: deleteIndex)
        state.rawReadingSymbols = state.readings.joined().map { String($0) }
        state.selectedCandidateIndex = 0
        pruneOverrides(state: &state)
    }

    static func finalizePendingReadingForCommit(state: inout UnifiedCompositionState) {
        guard !state.currentReading.isEmpty else { return }
        finalizeCurrentReading(state: &state)
    }

    static func resolveCommittedText(allReadings: [String]) -> String {
        SessionCtl.resolveCommittedText(allReadings: allReadings)
    }

    static func resolveWalk(_ readings: [String]) -> [ComposedSegment] {
        SessionCtl.resolveWalk(readings)
    }

    private static func finalizeCurrentReading(state: inout UnifiedCompositionState) {
        guard !state.currentReading.isEmpty else { return }
        let insertionIndex = state.currentCompositionCursorIndex()
        let source = state.pendingRawInput.isEmpty
            ? UnifiedCompositionState.sourceInput(for: state.currentReading) : state.pendingRawInput
        state.rebaseOverrides(replacing: insertionIndex..<insertionIndex, insertedCount: 1, insertedRawInputs: [source])
        state.readings.insert(state.currentReading, at: insertionIndex)
        state.pendingRawInput = ""
        if !state.trailingReadings.isEmpty {
            state.readings.append(contentsOf: state.trailingReadings)
            state.trailingReadings = []
        }
        state.currentReading = ""
        state.compositionCursorIndex = insertionIndex + 1
        state.rawReadingSymbols = state.readings.joined().map { String($0) }
        state.selectedCandidateIndex = 0
    }

    private static func lockSegment(containingReadingIndex readingIndex: Int, state: inout UnifiedCompositionState) {
        let resolved = resolvedSegmentsRespectingOverrides(for: state)
        guard let segment = resolved.first(where: { $0.start <= readingIndex && readingIndex < $0.start + $0.length }) else { return }
        let key = CompositionSegmentKey(start: segment.start, length: segment.length, reading: segment.reading)
        state.segmentOverrides[key] = segment.value
        state.automaticLockedKeys.insert(key)
    }

    private static func prepareFocusedSegmentReplacementIfNeeded(state: inout UnifiedCompositionState) {
        guard state.currentReading.isEmpty else { return }
        guard state.trailingReadings.isEmpty else { return }
        let cursorIndex = state.currentCompositionCursorIndex()
        guard cursorIndex < state.readings.count else { return }
        state.trailingReadings = Array(state.readings.suffix(from: cursorIndex))
        state.readings = Array(state.readings.prefix(cursorIndex))
        state.compositionCursorIndex = state.readings.count
    }

    private static func pruneOverrides(state: inout UnifiedCompositionState) {
        let resolved = SessionCtl.resolveWalk(state.allReadings)
        let validKeys = Set(resolved.map { CompositionSegmentKey(start: $0.start, length: $0.length, reading: $0.reading) })
        state.segmentOverrides = state.segmentOverrides.filter { validKeys.contains($0.key) || state.protectedKeys.contains($0.key) }
        state.compositionCursorIndex = min(state.currentCompositionCursorIndex(), state.allReadings.count)
    }

    private static func focusedSegment(in segments: [ComposedSegment], state: UnifiedCompositionState) -> ComposedSegment? {
        let insertionIndex = state.currentCompositionCursorIndex()
        if state.currentReading.isEmpty, insertionIndex > 0, insertionIndex < state.allReadings.count {
            let targetIndex = insertionIndex - 1
            if let segment = segments.first(where: { $0.start <= targetIndex && targetIndex < $0.start + $0.length }) {
                return segment
            }
        }
        return CompositionPresentationBuilder.focusedSegment(
            forInsertionIndex: insertionIndex,
            totalReadings: state.allReadings.count,
            in: segments
        )
    }

    private static func resolvedSegmentsRespectingOverrides(for state: UnifiedCompositionState) -> [ComposedSegment] {
        let allReadings = state.allReadings
        guard !allReadings.isEmpty else { return [] }
        let lockedSingles = state.segmentOverrides.compactMap { key, value -> (Int, ComposedSegment)? in
            guard state.protectedKeys.contains(key) else { return nil }
            guard key.start >= 0, key.start + key.length <= allReadings.count else { return nil }
            guard allReadings[key.start..<(key.start + key.length)].joined() == key.reading else { return nil }
            return (key.start, ComposedSegment(languageID: SessionCtl.traditionalChineseProvider.languageID, reading: key.reading, value: value, start: key.start, length: key.length, rawLength: rawLength(for: key.reading)))
        }
        var lockedMap = SessionCtl.overridePhraseLockedMap(for: allReadings)
        for (start, segment) in lockedSingles {
            lockedMap[start] = segment
        }
        // 選字鎖定不能抹掉其餘詞的上下文。優先沿用整句解碼中未與鎖定
        // 範圍交錯的完整片段；只有必須重新切詞的缺口才做局部解碼。
        var contextualSegments: [ComposedSegment]?
        var segments: [ComposedSegment] = []
        var start = 0
        while start < allReadings.count {
            if let locked = lockedMap[start] {
                segments.append(locked)
                start += locked.length
                continue
            }
            var end = start
            while end < allReadings.count, lockedMap[end] == nil { end += 1 }
            if !lockedMap.isEmpty, contextualSegments == nil {
                contextualSegments = SessionCtl.resolveWalk(allReadings)
            }
            let contextualSlice = (contextualSegments ?? []).filter {
                $0.start >= start && $0.start + $0.length <= end
            }
            if contextualSlice.first?.start == start,
               contextualSlice.reduce(0, { $0 + $1.length }) == end - start {
                segments.append(contentsOf: contextualSlice)
                start = end
                continue
            }
            let slice = Array(allReadings[start..<end])
            let resolvedSlice = SessionCtl.resolveWalk(slice).map { segment in
                // 詞庫偏好已參與候選與 DP 排序，不等同使用者明確選字。
                // 真正的選字鎖定由上方 lockedMap 處理，此處保留演算法結果。
                return ComposedSegment(languageID: segment.languageID, reading: segment.reading, value: segment.value, start: segment.start + start, length: segment.length, rawLength: rawLength(for: segment.reading))
            }
            segments.append(contentsOf: resolvedSlice)
            start = end
        }
        return segments
    }

    private static func protectedSegments(for state: UnifiedCompositionState) -> [ComposedSegment]? {
        let allReadings = state.allReadings
        guard !allReadings.isEmpty else { return nil }
        guard allReadings.allSatisfy({ numericProtectedValue(for: $0) != nil }) else { return nil }
        let values = allReadings.enumerated().compactMap { index, reading -> ComposedSegment? in
            let key = CompositionSegmentKey(start: index, length: 1, reading: reading)
            let lockedValue: String?
            if state.protectedKeys.contains(key) {
                lockedValue = state.segmentOverrides[key]
            } else {
                lockedValue = nil
            }
            guard let value = lockedValue ?? numericProtectedValue(for: reading) else { return nil }
            return ComposedSegment(languageID: SessionCtl.traditionalChineseProvider.languageID, reading: reading, value: value, start: index, length: 1, rawLength: rawLength(for: reading))
        }
        return values.count == allReadings.count ? values : nil
    }

    private static func numericProtectedValue(for reading: String) -> String? {
        switch reading {
        case "ㄧ", "ㄧ˙", "ㄧˋ", "ㄧˊ": return "一"
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

    private static func applyExplicitLocks(
        to segments: [ComposedSegment],
        state: UnifiedCompositionState
    ) -> [ComposedSegment] {
        let explicitLocks = state.protectedKeys.compactMap { key -> (CompositionSegmentKey, String)? in
            guard let value = state.segmentOverrides[key] else { return nil }
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
                .sorted { lhs, rhs in
                    if lhs.0.start != rhs.0.start { return lhs.0.start < rhs.0.start }
                    return lhs.0.length < rhs.0.length
                }
            guard !locks.isEmpty else { return [segment] }

            let syllables = UnifiedCompositionEngine.splitReadingIntoSyllables(segment.reading)
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
                            rawLength: rawLength(for: exact.0.reading)
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
                            rawLength: rawLength(for: prefixReading)
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
                        rawLength: rawLength(for: key.reading)
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
                        rawLength: rawLength(for: suffixReading)
                    )
                )
            }
            return pieces
        }
    }

    private static func baseDisplayedSegments(for state: UnifiedCompositionState) -> [ComposedSegment] {
        if let protected = protectedSegments(for: state) {
            return protected
        }
        let resolved = resolvedSegmentsRespectingOverrides(for: state)
        let overridden = resolved.map { segment -> ComposedSegment in
            let key = CompositionSegmentKey(start: segment.start, length: segment.length, reading: segment.reading)
            if let chosen = state.segmentOverrides[key] {
                return ComposedSegment(languageID: segment.languageID, reading: segment.reading, value: chosen, start: segment.start, length: segment.length, rawLength: rawLength(for: segment.reading))
            }
            return segment
        }
        let lockedBase = applyExplicitLocks(to: overridden, state: state)
        guard !state.currentReading.isEmpty else { return lockedBase }
        let insertionIndex = state.currentCompositionCursorIndex()
        let rawSegment = ComposedSegment(languageID: SessionCtl.traditionalChineseProvider.languageID, reading: state.currentReading, value: state.currentReading, start: insertionIndex, length: 1, rawLength: rawLength(for: state.currentReading))
        var inserted = false
        var merged: [ComposedSegment] = []
        for segment in lockedBase {
            if !inserted, insertionIndex <= segment.start {
                merged.append(rawSegment)
                inserted = true
            }
            merged.append(segment)
        }
        if !inserted {
            merged.append(rawSegment)
        }
        return merged
    }

    /// 候選排序使用的滑動窗口（以中文字音節計）。設定檔預設 6，
    /// 可用 UNIFYIME_CANDIDATE_WINDOW_LENGTH 覆寫，環境變數優先。
    private static var candidateWindowLength: Int {
        let environment = ProcessInfo.processInfo.environment["UNIFYIME_CANDIDATE_WINDOW_LENGTH"].flatMap(Int.init)
        let configured = environment ?? loadCandidateWindowLengthFromConfig()
        return min(max(configured, 2), 32)
    }

    private static func loadCandidateWindowLengthFromConfig() -> Int {
        let fm = FileManager.default
        var urls: [URL] = []
        if let resource = Bundle.main.url(forResource: "IMEConfig", withExtension: "json") {
            urls.append(resource)
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        urls.append(cwd.appendingPathComponent("src/unifyIME/Resources/IMEConfig.json"))
        urls.append(cwd.appendingPathComponent("Resources/IMEConfig.json"))
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let value = object["candidateWindowLength"] as? Int else { continue }
            return value
        }
        return 6
    }

    private static func stabilizePrefixBeforeAppend(state: inout UnifiedCompositionState) {
        let all = state.allReadings
        guard all.count > candidateWindowLength else { return }
        // 保留最多 2 個音節的邊界回溯，讓跨詞組仍有機會修正。
        let rollback = min(2, candidateWindowLength - 1)
        let cutoff = all.count - candidateWindowLength - rollback
        guard cutoff > 0 else { return }
        let segments = resolvedSegmentsRespectingOverrides(for: state)
        for segment in segments where segment.length > 1 && segment.start + segment.length <= cutoff {
            let key = CompositionSegmentKey(start: segment.start, length: segment.length, reading: segment.reading)
            state.segmentOverrides[key] = segment.value
            state.automaticLockedKeys.insert(key)
        }
    }

    private static func computeActiveCandidateEntries(
        candidateReadings: [String], walkedSegments: [ComposedSegment],
        focus: ComposedSegment, preferredReadingIndex: Int?
    ) -> [CandidateEntry] {
        let tokens = candidateReadings.map { InputToken(languageID: focus.languageID, rawValue: $0) }
        func entries(start: Int, length: Int) -> [CandidateEntry] {
            guard start >= 0, length > 0, start + length <= tokens.count else { return [] }
            let reading = tokens[start..<(start + length)].map(\.rawValue).joined()
            let candidates = SessionCtl.resolveCandidates(for: reading).filter {
                $0.count == length && LexiconStore.isDisplayableCandidate($0)
            }
            let key = CompositionSegmentKey(start: start, length: length, reading: reading)
            let prefix = CandidateScoringInput.precedingValues(segments: walkedSegments, before: start)
            return SessionCtl.rankCandidateSpan(candidates, tokens: tokens, start: start,
                length: length, precedingValues: prefix, limit: visibleCandidateLimit).map {
                CandidateEntry(text: $0, languageID: focus.languageID, replacementKey: key)
            }
        }
        var lists = [entries(start: focus.start, length: focus.length)]
        if focus.length > 1 {
            let localIndex = min(max(preferredReadingIndex ?? focus.start, focus.start),
                focus.start + focus.length - 1)
            lists.append(entries(start: localIndex, length: 1))
        }
        return CandidateListPolicy.merge(lists, current: nil, limit: visibleCandidateLimit)
    }

    private static func currentCandidateReadingIndex(for focus: ComposedSegment, state: UnifiedCompositionState) -> Int {
        guard !state.allReadings.isEmpty else { return focus.start }
        let cursor = state.currentCompositionCursorIndex()
        let candidateCursorIndex: Int
        if cursor >= state.allReadings.count {
            candidateCursorIndex = state.allReadings.count - 1
        } else if cursor > 0 {
            candidateCursorIndex = cursor - 1
        } else {
            candidateCursorIndex = 0
        }
        return min(max(candidateCursorIndex, focus.start), focus.start + focus.length - 1)
    }
}
