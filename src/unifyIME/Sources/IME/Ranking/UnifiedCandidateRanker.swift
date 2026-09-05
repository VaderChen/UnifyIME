import Foundation

protocol UnifiedCandidateRanker {
    var isListwiseRerankingAvailable: Bool { get }
    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double
    func scores(units: [CandidateUnit], context: CandidateSelectionContext) -> [Double]
}

extension UnifiedCandidateRanker {
    var isListwiseRerankingAvailable: Bool { false }

    func scores(units: [CandidateUnit], context: CandidateSelectionContext) -> [Double] {
        units.map { score(unit: $0, context: context) }
    }
}
