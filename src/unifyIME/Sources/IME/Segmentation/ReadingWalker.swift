import Foundation

struct ReadingWalker {
    let lexicon: LexiconStore
    let ranker: UnifiedCandidateRanker
    let languageID: String
    let pathRanker: UnifiedCandidateRanker

    // 兩階段的評分角色明確分開，可分別注入；ranker 負責上下文選詞。
    init(lexicon: LexiconStore, ranker: UnifiedCandidateRanker, languageID: String,
         pathRanker: UnifiedCandidateRanker = HeuristicCandidateRanker()) {
        self.lexicon = lexicon
        self.ranker = ranker
        self.languageID = languageID
        self.pathRanker = pathRanker
    }

    struct ScoredEdge {
        let segment: ComposedSegment
        let score: Double
    }

    // 實際組字與離線評估共用候選資格及分詞邊分數。
    func scoredEdges(_ tokens: [InputToken], start: Int, maxSpanLength: Int = 8,
                     allowToneCompletion: Bool = true) -> [ScoredEdge] {
        var edges: [ScoredEdge] = []
        forEachScoredEdge(tokens, start: start, maxSpanLength: maxSpanLength,
                         allowToneCompletion: allowToneCompletion) { edges.append($0) }
        return edges
    }

    // 即時分詞直接消費邊，不建立只遍歷一次的完整候選邊陣列。
    private func forEachScoredEdge(_ tokens: [InputToken], start: Int, maxSpanLength: Int,
                                  allowToneCompletion: Bool, visit: (ScoredEdge) -> Void) {
        guard tokens.indices.contains(start), maxSpanLength > 0 else { return }
        var combined = ""
        var readings: [String] = []
        readings.reserveCapacity(min(maxSpanLength, 8))
        for end in start..<min(tokens.count, start + min(maxSpanLength, 8)) {
            combined += tokens[end].rawValue
            let length = end - start + 1
            readings.append(tokens[end].rawValue)
            let matches = lexicon.compositionMatches(readings: readings,
                                                     allowToneCompletion: allowToneCompletion)
            if matches.isEmpty {
                if length == 1 {
                    let recalled = lexicon.resolveCandidates(for: combined)
                    let segment = ComposedSegment(languageID: languageID, reading: combined,
                        value: recalled.first ?? combined, start: start, length: 1, rawLength: rawLength(for: combined))
                    visit(ScoredEdge(segment: segment, score: -4000.0))
                }
                continue
            }
            guard let input = CandidateScoringInput.make(matches: matches, tokens: tokens,
                start: start, length: length, precedingValues: []) else { continue }
            let units = input.units
            let scores = pathRanker.scores(units: units, context: input.context)
            let rawCount = rawLength(for: combined)
            for (unit, score) in zip(units, scores) where score.isFinite {
                let segment = ComposedSegment(languageID: languageID, reading: combined,
                    value: unit.surface, start: start, length: length, rawLength: rawCount)
                visit(ScoredEdge(segment: segment, score: score))
            }
        }
    }

    private func rawLength(for reading: String) -> Int {
        languageID == "zh-Hant"
            ? max(1, SessionCtl.keySequence(for: [reading]).replacingOccurrences(of: " ", with: "").count)
            : max(1, reading.count)
    }

    func resolveWalk(_ tokens: [InputToken]) -> [ComposedSegment] {
        guard !tokens.isEmpty else { return [] }
        func path(in range: Range<Int>, allowToneCompletion: Bool) -> [ComposedSegment] {
            var bestScores = Array(repeating: -Double.infinity, count: range.count + 1)
            var bestCounts = Array(repeating: Int.max, count: range.count + 1)
            var bestSegments: [ComposedSegment?] = Array(repeating: nil, count: range.count)
            bestCounts[range.count] = 0
            bestScores[range.count] = 0
            for start in range.reversed() {
                let local = start - range.lowerBound
                forEachScoredEdge(tokens, start: start, maxSpanLength: range.upperBound - start,
                                 allowToneCompletion: allowToneCompletion) { edge in
                    let next = local + edge.segment.length
                    let score = edge.score + bestScores[next]
                    guard bestScores[next].isFinite else { return }
                    let segmentCount = bestCounts[next] + 1
                    if score > bestScores[local] || (score == bestScores[local] && segmentCount < bestCounts[local]) {
                        bestScores[local] = score
                        bestCounts[local] = segmentCount
                        bestSegments[local] = edge.segment
                    }
                    if isRuntimeTraceEnabled {
                        appendRuntimeTrace("lattice.edge range=\(start)..<\(next + range.lowerBound) reading=\(edge.segment.reading) value=\(edge.segment.value) local=\(edge.score) suffix=\(bestScores[next]) total=\(score)")
                    }
                }
            }
            var result: [ComposedSegment] = []
            var cursor = 0
            while cursor < range.count, let segment = bestSegments[cursor] {
                result.append(segment)
                cursor += segment.length
            }
            return result
        }
        // 先保留精確分詞中的完整詞，補調僅限仍由單字組成的連續缺口。
        // 避免補救候選跨過合法詞界，例如把既有三字詞的末字拆給下一詞。
        let exact = path(in: 0..<tokens.count, allowToneCompletion: false)
        var result: [ComposedSegment] = []
        var index = 0
        while index < exact.count {
            guard exact[index].length == 1 else {
                result.append(exact[index]); index += 1; continue
            }
            let start = index
            while index < exact.count && exact[index].length == 1 { index += 1 }
            if index - start > 1 {
                let range = exact[start].start..<(exact[index - 1].start + 1)
                result.append(contentsOf: path(in: range, allowToneCompletion: true))
            } else {
                result.append(exact[start])
            }
        }
        // 分詞完成後固定跨度；只在同讀音詞內以已選左文做有界 AI 排序。
        var contextual: [ComposedSegment] = []
        var prefix: [String] = []
        for segment in result {
            let ranked = rankedCandidates(tokens, start: segment.start, length: segment.length,
                precedingValues: prefix, limit: 1)
            let value = ranked.first?.unit.surface ?? segment.value
            contextual.append(ComposedSegment(languageID: segment.languageID, reading: segment.reading,
                value: value, start: segment.start, length: segment.length, rawLength: segment.rawLength))
            prefix.append(value)
            if prefix.count > 3 { prefix.removeFirst() }
        }
        // 用各自實際左文重算完整路徑，局部改善不代表整句改善。
        if contextual == result { return result }
        guard let originalScore = scorePath(result, tokens: tokens),
              let proposedScore = scorePath(contextual, tokens: tokens),
              proposedScore > originalScore else { return result }
        return contextual
    }

    func rankedCandidates(_ tokens: [InputToken], start: Int, length: Int,
                          precedingValues: [String], limit: Int) -> [RankedCandidate] {
        guard let input = inputForSpan(tokens, start: start, length: length, precedingValues: precedingValues) else { return [] }
        return ranker.ranked(units: input.units, context: input.context, limit: limit)
    }

    func inputForSpan(_ tokens: [InputToken], start: Int, length: Int,
                      precedingValues: [String]) -> CandidateScoringInput? {
        guard start >= 0, length > 0, length <= 8, start <= tokens.count,
              length <= tokens.count - start else { return nil }
        let matches = lexicon.compositionMatches(readings: tokens[start..<(start + length)].map(\.rawValue))
        return CandidateScoringInput.make(matches: matches, tokens: tokens,
            start: start, length: length, precedingValues: precedingValues)
    }

    // 固定分詞路徑的上下文分數；離線比較亦使用相同局部座標及已選左文。
    func scorePath(_ segments: [ComposedSegment], tokens: [InputToken]) -> Double? {
        var cursor = 0
        var prefix: [String] = []
        var total = 0.0
        for segment in segments {
            guard segment.start == cursor, segment.length > 0,
                  segment.length <= tokens.count - cursor else { return nil }
            guard let input = inputForSpan(tokens, start: cursor,
                length: segment.length, precedingValues: prefix),
                  segment.reading == input.context.combinedToken,
                  segment.languageID == input.context.languageID else { return nil }
            let score: Double
            if let unit = input.units.first(where: { $0.surface == segment.value }) {
                score = ranker.score(unit: unit, context: input.context)
            } else if segment.length == 1, input.units.isEmpty,
                      segment.value == lexicon.resolveCandidates(for: segment.reading).first {
                score = -4000.0
            } else { return nil }
            guard score.isFinite else { return nil }
            total += score
            prefix.append(segment.value)
            if prefix.count > 3 { prefix.removeFirst() }
            cursor += segment.length
        }
        return cursor == tokens.count && total.isFinite ? total : nil
    }
}
