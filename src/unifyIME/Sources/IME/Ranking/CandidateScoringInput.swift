import Foundation

/// 共用局部座標：候選前後各三個音節，左文最多三個已解出的片段。
struct CandidateScoringInput {
    let units: [CandidateUnit]
    let context: CandidateSelectionContext

    static func make(candidates: [String], tokens: [InputToken], start: Int,
                     length: Int, precedingValues: [String]) -> CandidateScoringInput? {
        guard length > 0, start >= 0, start <= tokens.count,
              length <= tokens.count - start else { return nil }
        let end = start + length
        let lower = max(0, start - 3)
        let upper = min(tokens.count, end + 3)
        let reading = tokens[start..<end].map(\.rawValue).joined()
        let language = tokens[start].languageID
        let prefix = Array(precedingValues.filter { !$0.isEmpty }.suffix(3))
        var context = CandidateSelectionContext(languageID: language,
            allTokens: Array(tokens[lower..<upper]), combinedToken: reading, spanLength: length,
            precedingValues: prefix,
            followingTokens: Array(tokens[end..<upper]), focusedToken: reading)
        context.legacyModelCoordinates = LegacyModelCoordinates(tokenCount: tokens.count, spanStart: start,
            followingTokens: Array(tokens[end..<min(tokens.count, end + 6)]))
        let units = candidates.enumerated().map { rank, value in
            CandidateUnit(languageID: language, surface: value, readingOrToken: reading,
                spanStart: start - lower, spanLength: length,
                providerScore: Double(-rank), baseRank: rank)
        }
        return CandidateScoringInput(units: units, context: context)
    }

    static func precedingValues(segments: [ComposedSegment], before index: Int) -> [String] {
        var recent: [String] = []
        for segment in segments.reversed() where segment.start < index {
            let covered = min(segment.length, index - segment.start)
            let value = String(segment.value.prefix(covered))
            if !value.isEmpty { recent.append(value) }
            if recent.count == 3 { break }
        }
        return recent.reversed()
    }
}
