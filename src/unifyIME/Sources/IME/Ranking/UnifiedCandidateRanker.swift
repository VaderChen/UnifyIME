import Foundation

protocol UnifiedCandidateRanker {
    var isListwiseRerankingAvailable: Bool { get }
    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double
    func scores(units: [CandidateUnit], context: CandidateSelectionContext) -> [Double]
    func ranked(units: [CandidateUnit], context: CandidateSelectionContext, limit: Int) -> [RankedCandidate]
}

extension UnifiedCandidateRanker {
    var isListwiseRerankingAvailable: Bool { false }

    func scores(units: [CandidateUnit], context: CandidateSelectionContext) -> [Double] {
        units.map { score(unit: $0, context: context) }
    }

    func ranked(units: [CandidateUnit], context: CandidateSelectionContext, limit: Int) -> [RankedCandidate] {
        guard limit > 0 else { return [] }
        return Array(zip(units, scores(units: units, context: context)).compactMap { unit, score in
            score.isFinite ? RankedCandidate(unit: unit, score: score) : nil
        }.sorted(by: candidateRanksBefore).prefix(limit))
    }
}

func candidateRanksBefore(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
    lhs.score == rhs.score ? lhs.unit.baseRank < rhs.unit.baseRank : lhs.score > rhs.score
}
