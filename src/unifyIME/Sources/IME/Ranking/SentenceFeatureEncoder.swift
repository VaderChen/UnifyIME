import Foundation

struct SentenceFeatureEncoder {
    static let expectedDimension = 24

    private static let phraseStats = LexiconStore.loadPhraseContextStats()

    func encode(path: SentenceCandidatePath, context: SentenceRerankerContext) -> [Double] {
        let segmentCount = Double(path.segments.count)
        let textLength = Double(path.text.count)
        let readingCount = Double(path.readings.count)
        let lengths = path.segments.map(\.value.count)
        let avgSegmentLength = lengths.isEmpty ? 0.0 : Double(lengths.reduce(0, +)) / Double(lengths.count)
        let maxSegmentLength = Double(lengths.max() ?? 0)
        let singleCount = Double(lengths.filter { $0 == 1 }.count)
        let multiCount = Double(lengths.filter { $0 > 1 }.count)
        let phraseCount = Double(path.segments.filter { $0.value.count > 1 }.count)
        let fallbackCount = Double(path.segments.filter { $0.value == $0.reading }.count)
        let leftText = context.committedLeftContext.suffix(3).joined(separator: "|")
        let rightText = context.committedRightContext.prefix(3).joined(separator: "|")

        let phraseWeights = path.segments.map { Self.phraseLogWeight(for: $0.value) }
        let avgPhraseWeight = phraseWeights.isEmpty ? 0.0 : phraseWeights.reduce(0, +) / Double(phraseWeights.count)
        let minPhraseWeight = phraseWeights.min() ?? 0.0
        let maxPhraseWeight = phraseWeights.max() ?? 0.0

        let adjacency = zip(path.segments, path.segments.dropFirst()).map { lhs, rhs in
            Self.bigramWeight(lhs.value, rhs.value)
        }
        let adjacencySum = adjacency.reduce(0, +)
        let adjacencyMin = adjacency.min() ?? 0.0
        let adjacencyAvg = adjacency.isEmpty ? 0.0 : adjacencySum / Double(adjacency.count)

        let features: [Double] = [
            path.localScore,
            segmentCount,
            textLength,
            readingCount,
            avgSegmentLength,
            maxSegmentLength,
            singleCount,
            multiCount,
            phraseCount,
            fallbackCount,
            avgPhraseWeight,
            minPhraseWeight,
            maxPhraseWeight,
            adjacencySum,
            adjacencyMin,
            adjacencyAvg,
            Double(context.committedLeftContext.count),
            Double(context.committedRightContext.count),
            Self.stableHash(leftText),
            Self.stableHash(rightText),
            Self.stableHash(path.text),
            Self.stableHash(path.segments.map(\.value).joined(separator: "|")),
            Self.hanRatio(path.text),
            Self.boundaryMatchScore(path: path, context: context)
        ]
        return features.count == Self.expectedDimension ? features : Array(features.prefix(Self.expectedDimension))
    }

    private static func phraseLogWeight(for surface: String) -> Double {
        guard let weight = phraseStats.surfaceWeights[surface], weight > 0 else { return 0.0 }
        return log1p(weight) / 10.0
    }

    private static func bigramWeight(_ lhs: String, _ rhs: String) -> Double {
        phraseLogWeight(for: lhs + rhs)
    }

    private static func stableHash(_ text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }
        var hash = UInt64(1469598103934665603)
        for scalar in text.unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash &*= 1099511628211
        }
        return Double(hash % 4096) / 4095.0
    }

    private static func hanRatio(_ text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let hanCount = text.unicodeScalars.filter {
            (0x3400...0x4DBF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value)
        }.count
        return Double(hanCount) / Double(max(text.count, 1))
    }

    private static func boundaryMatchScore(path: SentenceCandidatePath, context: SentenceRerankerContext) -> Double {
        let left = context.committedLeftContext.last ?? ""
        let right = context.committedRightContext.first ?? ""
        var score = 0.0
        if let last = left.last, let first = path.text.first, last == first {
            score += 0.5
        }
        if let last = path.text.last, let first = right.first, last == first {
            score += 0.5
        }
        return score
    }
}
