import Foundation

/// 共用局部座標：候選前後各三個音節，左文最多三個已解出的片段。
struct CandidateScoringInput {
    let units: [CandidateUnit]
    let context: CandidateSelectionContext

    static func make(matches: [LexiconStore.CompositionMatch], tokens: [InputToken], start: Int,
                     length: Int, precedingValues: [String]) -> CandidateScoringInput? {
        guard let context = makeContext(tokens: tokens, start: start, length: length,
            precedingValues: precedingValues) else { return nil }
        let units = matches.enumerated().map { rank, match in
            CandidateUnit(languageID: context.languageID, surface: match.surface,
                readingOrToken: context.combinedToken, spanStart: min(start, 3), spanLength: length,
                providerScore: Double(-rank), baseRank: rank,
                lexiconReading: match.inferredToneCount > 0 ? match.reading : nil,
                inferredToneCount: max(0, match.inferredToneCount))
        }
        return CandidateScoringInput(units: units, context: context)
    }

    static func make(candidates: [String], tokens: [InputToken], start: Int,
                     length: Int, precedingValues: [String]) -> CandidateScoringInput? {
        guard let context = makeContext(tokens: tokens, start: start, length: length,
            precedingValues: precedingValues) else { return nil }
        let units = candidates.enumerated().map { rank, value in
            CandidateUnit(languageID: context.languageID, surface: value, readingOrToken: context.combinedToken,
                spanStart: min(start, 3), spanLength: length, providerScore: Double(-rank), baseRank: rank)
        }
        return CandidateScoringInput(units: units, context: context)
    }

    private static func makeContext(tokens: [InputToken], start: Int, length: Int,
                                    precedingValues: [String]) -> CandidateSelectionContext? {
        guard length > 0, start >= 0, start <= tokens.count,
              length <= tokens.count - start else { return nil }
        let end = start + length
        let lower = max(0, start - 3)
        let upper = min(tokens.count, end + 3)
        let reading = tokens[start..<end].lazy.map(\.rawValue).joined(separator: "")
        let language = tokens[start].languageID
        let prefix = Array(precedingValues.reversed().lazy.filter { !$0.isEmpty }.prefix(3).reversed())
        var context = CandidateSelectionContext(languageID: language,
            allTokens: Array(tokens[lower..<upper]), combinedToken: reading, spanLength: length,
            precedingValues: prefix,
            followingTokens: Array(tokens[end..<upper]), focusedToken: reading)
        context.legacyModelCoordinates = LegacyModelCoordinates(tokenCount: tokens.count, spanStart: start,
            followingTokens: Array(tokens[end..<min(tokens.count, end + 6)]))
        return context
    }

    static func precedingValues(segments: [ComposedSegment], before index: Int) -> [String] {
        var recent: [String] = []
        for segment in segments.reversed() where segment.start < index {
            let covered = min(segment.length, index - segment.start)
            // 一個組字單位可能是一整個英文詞或多字候選，完整左文不能
            // 依音節數截成第一個字元；只有游標位於詞段內才取前綴。
            let value = covered == segment.length
                ? segment.value : String(segment.value.prefix(covered))
            if !value.isEmpty { recent.append(value) }
            if recent.count == 3 { break }
        }
        return recent.reversed()
    }
}
