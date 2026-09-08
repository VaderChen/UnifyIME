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

/// 各引擎先依自身分數排序，再以名次合併，避免混用不同尺度的分數。
enum CandidateListPolicy {
    static func merge(_ lists: [[CandidateEntry]], current: CandidateEntry?, limit: Int) -> [CandidateEntry] {
        guard limit > 0 else { return [] }
        var seen = Set<CandidateIdentity>()
        var result: [CandidateEntry] = []
        if let current { result.append(current); seen.insert(current.identity) }
        // 先在每個來源去重，重複項目不佔用名次。
        let normalized = lists.map { list in
            var localSeen = Set<CandidateIdentity>()
            return list.filter { $0.identity != current?.identity && localSeen.insert($0.identity).inserted }
        }
        for rank in 0..<(normalized.map(\.count).max() ?? 0) {
            let ranked = normalized.enumerated().compactMap { source, entries -> (Int, CandidateEntry)? in
                entries.indices.contains(rank) ? (source, entries[rank]) : nil
            }
            let anchorOrder = ranked.reduce(into: [Int: Int]()) { order, item in
                if order[item.1.replacementKey.start] == nil { order[item.1.replacementKey.start] = item.0 }
            }
            let peers = ranked.sorted { lhs, rhs in
                let leftAnchor = anchorOrder[lhs.1.replacementKey.start] ?? lhs.0
                let rightAnchor = anchorOrder[rhs.1.replacementKey.start] ?? rhs.0
                if leftAnchor != rightAnchor { return leftAnchor < rightAnchor }
                // 同名次、同起點優先完整範圍；以來源順序打破平手。
                if lhs.1.replacementKey.start == rhs.1.replacementKey.start,
                   lhs.1.replacementKey.length != rhs.1.replacementKey.length {
                    return lhs.1.replacementKey.length > rhs.1.replacementKey.length
                }
                return lhs.0 < rhs.0
            }
            for (_, entry) in peers where seen.insert(entry.identity).inserted {
                if result.count == limit { return result }
                result.append(entry)
            }
        }
        return Array(result.prefix(limit))
    }
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
        if let containing = segments.first(where: {
            $0.start <= key.start && key.start + key.length <= $0.start + $0.length
        }) { return containing }
        guard entry.replacementReadings != nil else { return nil }
        let covered = segments.filter { $0.start >= key.start && $0.start + $0.length <= key.start + key.length }
        guard covered.first?.start == key.start,
              covered.last.map({ $0.start + $0.length }) == key.start + key.length else { return nil }
        return ComposedSegment(languageID: entry.languageID, reading: key.reading,
            value: covered.map(\.value).joined(), start: key.start, length: key.length,
            rawLength: covered.reduce(0) { $0 + $1.rawLength })
    }

    static func displayCursorLocation(forInsertionIndex insertionIndex: Int, segments: [ComposedSegment]) -> Int {
        guard insertionIndex > 0 else { return 0 }
        var tokenOffset = 0
        var charOffset = 0
        for segment in segments {
            let nextTokenOffset = tokenOffset + segment.length
            if insertionIndex <= nextTokenOffset {
                let localTokenCount = max(0, insertionIndex - tokenOffset)
                // 詞段尾端必須走到完整文字末尾；內部只落在完整字元邊界。
                let localCharAdvance = localTokenCount >= segment.length
                    ? segment.value.count : min(segment.value.count, localTokenCount)
                return charOffset + segment.value.prefix(localCharAdvance).utf16.count
            }
            tokenOffset = nextTokenOffset
            charOffset += segment.value.utf16.count
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
        let current = primaryFocus.map { focus in
            CandidateEntry(text: focus.value, languageID: focus.languageID,
                replacementKey: CompositionSegmentKey(start: focus.start, length: focus.length, reading: focus.reading))
        }
        let candidateEntries = CandidateListPolicy.merge(lists, current: current, limit: visibleCandidateLimit)
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
