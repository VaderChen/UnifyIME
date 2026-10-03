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
        if limit >= units.count {
            return zip(units, scores(units: units, context: context)).compactMap { unit, score in
                score.isFinite ? RankedCandidate(unit: unit, score: score) : nil
            }.sorted(by: candidateRanksBefore)
        }
        var selection = CandidateTopK(limit: min(limit, units.count))
        for (unit, score) in zip(units, scores(units: units, context: context)) {
            selection.insert(RankedCandidate(unit: unit, score: score))
        }
        return selection.ranked()
    }
}

func candidateRanksBefore(_ lhs: RankedCandidate, _ rhs: RankedCandidate) -> Bool {
    lhs.score == rhs.score ? lhs.unit.baseRank < rhs.unit.baseRank : lhs.score > rhs.score
}

/// 根節點保存目前最差候選；只保留 K 筆，平手沿用輸入順序。
/// 完整掃描 O(N log K)，暫存 O(K)，最後只排序保留下來的候選。
struct CandidateTopK {
    private struct Item {
        let candidate: RankedCandidate
        let ordinal: Int
    }
    private let limit: Int
    private var heap: [Item] = []
    private var nextOrdinal = 0

    init(limit: Int) {
        self.limit = max(0, limit)
        heap.reserveCapacity(min(self.limit, 64))
    }

    var cutoffScore: Double? { heap.count == limit ? heap.first?.candidate.score : nil }

    private func precedes(_ lhs: Item, _ rhs: Item) -> Bool {
        if candidateRanksBefore(lhs.candidate, rhs.candidate) { return true }
        if candidateRanksBefore(rhs.candidate, lhs.candidate) { return false }
        return lhs.ordinal < rhs.ordinal
    }

    mutating func insert(_ candidate: RankedCandidate) {
        guard limit > 0, candidate.score.isFinite else { return }
        let item = Item(candidate: candidate, ordinal: nextOrdinal)
        nextOrdinal += 1
        if heap.count < limit {
            heap.append(item)
            var child = heap.count - 1
            while child > 0 {
                let parent = (child - 1) / 2
                guard precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(parent, child)
                child = parent
            }
        } else if precedes(item, heap[0]) {
            heap[0] = item
            var parent = 0
            while parent * 2 + 1 < heap.count {
                var child = parent * 2 + 1
                if child + 1 < heap.count, precedes(heap[child], heap[child + 1]) { child += 1 }
                guard precedes(heap[parent], heap[child]) else { break }
                heap.swapAt(parent, child)
                parent = child
            }
        }
    }

    func ranked() -> [RankedCandidate] { heap.sorted(by: precedes).map(\.candidate) }
}
