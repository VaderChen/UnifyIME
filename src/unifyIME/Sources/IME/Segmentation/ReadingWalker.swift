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
    func scoredEdges(_ tokens: [InputToken], start: Int, maxSpanLength: Int = 8) -> [ScoredEdge] {
        guard tokens.indices.contains(start), maxSpanLength > 0 else { return [] }
        var edges: [ScoredEdge] = []
        var combined = ""
        for end in start..<min(tokens.count, start + min(maxSpanLength, 8)) {
            combined += tokens[end].rawValue
            let length = end - start + 1
            let recalled = lexicon.resolveCandidates(for: combined)
            let candidates = lexicon.compositionCandidates(reading: combined, syllableCount: length)
            if candidates.isEmpty {
                if length == 1 {
                    let segment = ComposedSegment(languageID: languageID, reading: combined,
                        value: recalled.first ?? combined, start: start, length: 1, rawLength: rawLength(for: combined))
                    edges.append(ScoredEdge(segment: segment, score: -4000.0))
                }
                continue
            }
            guard let input = CandidateScoringInput.make(candidates: candidates, tokens: tokens,
                start: start, length: length, precedingValues: []) else { continue }
            let units = input.units
            let scores = pathRanker.scores(units: units, context: input.context)
            let rawCount = rawLength(for: combined)
            for (unit, score) in zip(units, scores) where score.isFinite {
                let segment = ComposedSegment(languageID: languageID, reading: combined,
                    value: unit.surface, start: start, length: length, rawLength: rawCount)
                edges.append(ScoredEdge(segment: segment, score: score))
            }
        }
        return edges
    }

    private func rawLength(for reading: String) -> Int {
        languageID == "zh-Hant"
            ? max(1, SessionCtl.keySequence(for: [reading]).replacingOccurrences(of: " ", with: "").count)
            : max(1, reading.count)
    }

    func resolveWalk(_ tokens: [InputToken]) -> [ComposedSegment] {
        guard !tokens.isEmpty else { return [] }
        var bestScores = Array(repeating: -Double.infinity, count: tokens.count + 1)
        var bestCounts = Array(repeating: Int.max, count: tokens.count + 1)
        bestCounts[tokens.count] = 0
        var bestEdges: [ScoredEdge?] = Array(repeating: nil, count: tokens.count)
        bestScores[tokens.count] = 0
        for start in stride(from: tokens.count - 1, through: 0, by: -1) {
            for edge in scoredEdges(tokens, start: start) {
                let next = start + edge.segment.length
                let score = edge.score + bestScores[next]
                guard bestScores[next].isFinite else { continue }
                let segmentCount = bestCounts[next] + 1
                if score > bestScores[start] || (score == bestScores[start] && segmentCount < bestCounts[start]) {
                    bestScores[start] = score
                    bestCounts[start] = segmentCount
                    bestEdges[start] = edge
                }
                if isRuntimeTraceEnabled {
                    appendRuntimeTrace("lattice.edge range=\(start)..<\(next) reading=\(edge.segment.reading) value=\(edge.segment.value) local=\(edge.score) suffix=\(bestScores[next]) total=\(score)")
                }
            }
        }
        var result: [ComposedSegment] = []
        var cursor = 0
        while cursor < tokens.count, let edge = bestEdges[cursor] {
            result.append(edge.segment)
            cursor += edge.segment.length
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
            prefix = Array((prefix + [value]).suffix(3))
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
        let reading = tokens[start..<(start + length)].map(\.rawValue).joined()
        let candidates = lexicon.compositionCandidates(reading: reading, syllableCount: length)
        return CandidateScoringInput.make(candidates: candidates, tokens: tokens,
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
            prefix = Array((prefix + [segment.value]).suffix(3))
            cursor += segment.length
        }
        return cursor == tokens.count && total.isFinite ? total : nil
    }
}
