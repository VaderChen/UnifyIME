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
        let safeReadingIndex = max(0, min(totalReadings, insertionIndex))
        let targetIndex: Int
        switch currentCandidateCursorAlignment {
        case .left:
            targetIndex = max(0, min(totalReadings - 1, safeReadingIndex == 0 ? 0 : safeReadingIndex - 1))
        case .right:
            targetIndex = max(0, min(totalReadings - 1, safeReadingIndex))
        }
        for segment in segments {
            let end = segment.start + segment.length
            if segment.start <= targetIndex && targetIndex < end {
                return segment
            }
        }
        return segments.last
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
        candidateProvider: (ComposedSegment?) -> [CandidateEntry],
        previewOverrideProvider: ((ComposedSegment, CandidateEntry) -> [ComposedSegment]?)? = nil
    ) -> CompositionPresentationState {
        let focus = focusedSegment(forInsertionIndex: insertionIndex, totalReadings: totalReadings, in: baseSegments)
        var candidateEntries = candidateProvider(focus)
        let displayedSegments: [ComposedSegment]
        if let focus,
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
        let renderedFocus = focusedSegment(forInsertionIndex: insertionIndex, totalReadings: totalReadings, in: displayedSegments)
        if let focus {
            let focusKey = CompositionSegmentKey(start: focus.start, length: focus.length, reading: focus.reading)
            candidateEntries.removeAll { $0.text == focus.value }
            candidateEntries.insert(
                CandidateEntry(text: focus.value, languageID: focus.languageID, replacementKey: focusKey),
                at: 0
            )
        }
        candidateEntries = Array(candidateEntries.prefix(visibleCandidateLimit))
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
