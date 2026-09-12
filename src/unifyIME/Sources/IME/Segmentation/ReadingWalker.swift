import Foundation

struct ReadingWalker {
    let lexicon: LexiconStore
    let ranker: UnifiedCandidateRanker
    let languageID: String

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
            let phrases = Set((lexicon.phraseCandidateMap[combined] ?? [])
                + PersonalVocabularyStore.entries(reading: combined).map(\.surface))
            let candidates = recalled.filter {
                length == 1 ? $0.count == 1 : $0.count == length && phrases.contains($0)
            }
            let context = CandidateSelectionContext(languageID: languageID, allTokens: tokens,
                combinedToken: combined, spanLength: length, precedingValues: [],
                followingTokens: Array(tokens.dropFirst(end + 1)), focusedToken: combined)
            // 所有已召回候選先評分，離線搜尋只能在評分後截取。
            let units = candidates.enumerated().map { rank, value in
                CandidateUnit(languageID: languageID, surface: value, readingOrToken: combined,
                    spanStart: start, spanLength: length, providerScore: Double(-rank), baseRank: rank)
            }
            let scores = ranker.scores(units: units, context: context)
            for (unit, score) in zip(units, scores) where score.isFinite {
                // 每合併一個音節邊界加分，不依完整詞的個數重複給獎勵。
                let joinBonus = Double(length - 1) * 1800.0
                let segment = ComposedSegment(languageID: languageID, reading: combined,
                    value: unit.surface, start: start, length: length, rawLength: rawLength(for: combined))
                edges.append(ScoredEdge(segment: segment, score: score + joinBonus))
            }
            if length == 1 && units.isEmpty {
                let value = recalled.first ?? combined
                let segment = ComposedSegment(languageID: languageID, reading: combined,
                    value: value, start: start, length: 1, rawLength: rawLength(for: combined))
                edges.append(ScoredEdge(segment: segment, score: -4000.0))
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
        var bestEdges: [ScoredEdge?] = Array(repeating: nil, count: tokens.count)
        bestScores[tokens.count] = 0
        for start in stride(from: tokens.count - 1, through: 0, by: -1) {
            for edge in scoredEdges(tokens, start: start) {
                let next = start + edge.segment.length
                let score = edge.score + bestScores[next]
                if score > bestScores[start] {
                    bestScores[start] = score
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
        return result
    }
}
