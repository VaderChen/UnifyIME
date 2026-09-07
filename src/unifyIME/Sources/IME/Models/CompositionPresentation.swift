import Foundation

struct CompositionPresentationState {
    let baseSegments: [ComposedSegment]
    let displayedSegments: [ComposedSegment]
    let focusedSegment: ComposedSegment?
    let candidateEntries: [CandidateEntry]
    let cursorLocation: Int
    let markedText: String
    let debugText: String
    let focusInfo: String?

    var candidates: [String] { candidateEntries.map(\.text) }
}

enum CompositionPresentationBuilder {
    static func focusedSegment(
        forInsertionIndex insertionIndex: Int,
        totalReadings: Int,
        in segments: [ComposedSegment]
    ) -> ComposedSegment? {
        guard !segments.isEmpty else { return nil }
        guard let targetIndex = currentCandidateCursorAlignment.readingIndices(
            insertionIndex: insertionIndex, totalReadings: totalReadings
        ).first else { return nil }
        for segment in segments {
            let end = segment.start + segment.length
            if segment.start <= targetIndex && targetIndex < end {
                return segment
            }
        }
        return segments.last
    }

    static func segment(for entry: CandidateEntry, in segments: [ComposedSegment]) -> ComposedSegment? {
        let key = entry.replacementKey
        return segments.first {
            $0.start <= key.start && key.start + key.length <= $0.start + $0.length
        }
    }

    static func displayCursorLocation(forInsertionIndex insertionIndex: Int, segments: [ComposedSegment]) -> Int {
        guard insertionIndex > 0 else { return 0 }
        var tokenOffset = 0
        var charOffset = 0
        for segment in segments {
            let nextTokenOffset = tokenOffset + segment.length
            if insertionIndex <= nextTokenOffset {
                let localTokenCount = max(0, insertionIndex - tokenOffset)
                let localCharAdvance = min(segment.value.count, localTokenCount)
                return charOffset + localCharAdvance
            }
            tokenOffset = nextTokenOffset
            charOffset += segment.value.count
        }
        return charOffset
    }

    static func debugComposingText(
        segments: [ComposedSegment],
        focus: ComposedSegment?
    ) -> (text: String, focus: String?) {
        guard !segments.isEmpty else { return ("", nil) }
        let parts = segments.map { segment -> String in
            guard let focus else { return segment.value }
            if segment.start == focus.start && segment.length == focus.length {
                return "〔\(segment.value)〕"
            }
            return segment.value
        }
        let focusInfo = focus.map {
            "第\($0.start + 1)字起／長度\($0.length)／RAW-KEY\($0.rawLength)／讀音\($0.reading)"
        }
        return (parts.joined(separator: " "), focusInfo)
    }

    static func build(
        baseSegments: [ComposedSegment],
        totalReadings: Int,
        insertionIndex: Int,
        selectedCandidateIndex: Int,
        visibleCandidateLimit: Int,
        candidateProvider: (ComposedSegment?, Int) -> [CandidateEntry],
        previewOverrideProvider: ((ComposedSegment, CandidateEntry) -> [ComposedSegment]?)? = nil
    ) -> CompositionPresentationState {
        let primaryFocus = focusedSegment(forInsertionIndex: insertionIndex, totalReadings: totalReadings, in: baseSegments)
        let indices = currentCandidateCursorAlignment.readingIndices(insertionIndex: insertionIndex, totalReadings: totalReadings)
        let lists = indices.map { index -> [CandidateEntry] in
            let focus = baseSegments.first { $0.start <= index && index < $0.start + $0.length }
            return candidateProvider(focus, index)
        }
        // 左右交錯保留各側排序，以文字、語言及替換範圍共同去重。
        var candidateEntries: [CandidateEntry] = []
        if let focus = primaryFocus {
            candidateEntries.append(CandidateEntry(text: focus.value, languageID: focus.languageID,
                replacementKey: CompositionSegmentKey(start: focus.start, length: focus.length, reading: focus.reading)))
        }
        for rank in 0..<(lists.map(\.count).max() ?? 0) {
            for list in lists where list.indices.contains(rank) {
                let entry = list[rank]
                if currentCandidateCursorAlignment != .both, entry.text == primaryFocus?.value { continue }
                if !candidateEntries.contains(entry) { candidateEntries.append(entry) }
            }
        }
        candidateEntries = Array(candidateEntries.prefix(visibleCandidateLimit))
        let focus: ComposedSegment?
        if selectedCandidateIndex > 0, candidateEntries.indices.contains(selectedCandidateIndex) {
            focus = segment(for: candidateEntries[selectedCandidateIndex], in: baseSegments) ?? primaryFocus
        } else {
            focus = primaryFocus
        }
        let displayedSegments: [ComposedSegment]
        if let focus,
           selectedCandidateIndex > 0,
           candidateEntries.indices.contains(selectedCandidateIndex) {
            let chosen = candidateEntries[selectedCandidateIndex]
            displayedSegments = baseSegments.flatMap { segment in
                guard segment.start == focus.start && segment.length == focus.length else { return [segment] }
                if let previewSegments = previewOverrideProvider?(focus, chosen), !previewSegments.isEmpty {
                    return previewSegments
                }
                return [ComposedSegment(
                    languageID: chosen.languageID,
                    reading: segment.reading,
                    value: chosen.text,
                    start: segment.start,
                    length: segment.length
                )]
            }
        } else {
            displayedSegments = baseSegments
        }
        let renderedFocus: ComposedSegment?
        if selectedCandidateIndex > 0, candidateEntries.indices.contains(selectedCandidateIndex) {
            renderedFocus = segment(for: candidateEntries[selectedCandidateIndex], in: displayedSegments)
        } else {
            renderedFocus = focusedSegment(forInsertionIndex: insertionIndex, totalReadings: totalReadings, in: displayedSegments)
        }
        let debug = debugComposingText(segments: displayedSegments, focus: renderedFocus)
        let markedText = displayedSegments.map(\.value).joined()
        return CompositionPresentationState(
            baseSegments: baseSegments,
            displayedSegments: displayedSegments,
            focusedSegment: focus,
            candidateEntries: candidateEntries,
            cursorLocation: displayCursorLocation(forInsertionIndex: insertionIndex, segments: displayedSegments),
            markedText: markedText,
            debugText: debug.text,
            focusInfo: debug.focus
        )
    }
}
