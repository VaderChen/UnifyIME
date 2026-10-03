import Foundation

struct SentenceFeatureEncoder {
    static let expectedDimension = 24

    private static let phraseStats = LexiconStore.loadPhraseContextStats()

    func encode(path: SentenceCandidatePath, context: SentenceRerankerContext) -> [Double] {
        let segmentCount = Double(path.segments.count)
        let textLength = Double(path.text.count)
        let readingCount = Double(path.readings.count)
        var totalLength = 0
        var maxLength = 0
        var singles = 0
        var multiples = 0
        var fallbacks = 0
        var phraseSum = 0.0
        var minPhraseWeight = Double.infinity
        var maxPhraseWeight = 0.0
        var adjacencySum = 0.0
        var adjacencyMin = Double.infinity
        var previous: String?
        // 保留原先由左到右的浮點加總順序，避免改變模型輸入位元。
        for segment in path.segments {
            let length = segment.value.count
            totalLength += length
            maxLength = max(maxLength, length)
            if length == 1 { singles += 1 }
            if length > 1 { multiples += 1 }
            if segment.value == segment.reading { fallbacks += 1 }
            let weight = Self.phraseLogWeight(for: segment.value)
            phraseSum += weight
            minPhraseWeight = min(minPhraseWeight, weight)
            maxPhraseWeight = max(maxPhraseWeight, weight)
            if let previous {
                let adjacent = Self.bigramWeight(previous, segment.value)
                adjacencySum += adjacent
                adjacencyMin = min(adjacencyMin, adjacent)
            }
            previous = segment.value
        }
        let avgSegmentLength = path.segments.isEmpty ? 0.0 : Double(totalLength) / segmentCount
        let maxSegmentLength = Double(maxLength)
        let singleCount = Double(singles)
        let multiCount = Double(multiples)
        let phraseCount = multiCount
        let fallbackCount = Double(fallbacks)
        let leftText = context.committedLeftContext.suffix(3).joined(separator: "|")
        let rightText = context.committedRightContext.prefix(3).joined(separator: "|")
        let avgPhraseWeight = path.segments.isEmpty ? 0.0 : phraseSum / segmentCount
        if path.segments.isEmpty { minPhraseWeight = 0.0 }
        let adjacencyCount = max(0, path.segments.count - 1)
        if adjacencyCount == 0 { adjacencyMin = 0.0 }
        let adjacencyAvg = adjacencyCount == 0 ? 0.0 : adjacencySum / Double(adjacencyCount)

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
            Self.stableHash(path.segments.lazy.map(\.value).joined(separator: "|")),
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
        let hanCount = text.unicodeScalars.reduce(0) { count, scalar in
            count + (((0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)) ? 1 : 0)
        }
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
