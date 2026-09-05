import Foundation

struct ListwiseEncodedInput {
    static let maxCandidates = 20
    static let sequenceLength = 48
    static let numericDimension = 8
    static let vocabularySize = 16_384

    let tokenIDs: [Int32]
    let tokenTypes: [Int32]
    let numericFeatures: [Float]
    let candidateMask: [Float]

    init(
        tokenIDs: [Int32],
        tokenTypes: [Int32],
        numericFeatures: [Float],
        candidateMask: [Float]
    ) {
        precondition(tokenIDs.count == Self.maxCandidates * Self.sequenceLength)
        precondition(tokenTypes.count == Self.maxCandidates * Self.sequenceLength)
        precondition(numericFeatures.count == Self.maxCandidates * Self.numericDimension)
        precondition(candidateMask.count == Self.maxCandidates)
        self.tokenIDs = tokenIDs
        self.tokenTypes = tokenTypes
        self.numericFeatures = numericFeatures
        self.candidateMask = candidateMask
    }
}

struct ListwiseFeatureEncoder {
    private enum TokenID {
        static let pad: Int32 = 0
        static let beginning: Int32 = 1
        static let left: Int32 = 2
        static let candidate: Int32 = 3
        static let reading: Int32 = 4
        static let right: Int32 = 5
        static let end: Int32 = 6
        static let hashOffset: UInt32 = 8
    }

    private enum TokenType {
        static let pad: Int32 = 0
        static let special: Int32 = 1
        static let left: Int32 = 2
        static let candidate: Int32 = 3
        static let reading: Int32 = 4
        static let right: Int32 = 5
    }

    func encode(
        units: [CandidateUnit],
        context: CandidateSelectionContext
    ) -> ListwiseEncodedInput {
        let limitedUnits = Array(units.prefix(ListwiseEncodedInput.maxCandidates))
        var tokenIDs = Array(
            repeating: TokenID.pad,
            count: ListwiseEncodedInput.maxCandidates * ListwiseEncodedInput.sequenceLength
        )
        var tokenTypes = Array(
            repeating: TokenType.pad,
            count: ListwiseEncodedInput.maxCandidates * ListwiseEncodedInput.sequenceLength
        )
        var numericFeatures = Array(
            repeating: Float(0),
            count: ListwiseEncodedInput.maxCandidates * ListwiseEncodedInput.numericDimension
        )
        var candidateMask = Array(
            repeating: Float(0),
            count: ListwiseEncodedInput.maxCandidates
        )

        for (candidateIndex, unit) in limitedUnits.enumerated() {
            let sequence = encodeSequence(unit: unit, context: context)
            let sequenceOffset = candidateIndex * ListwiseEncodedInput.sequenceLength
            tokenIDs.replaceSubrange(
                sequenceOffset..<(sequenceOffset + ListwiseEncodedInput.sequenceLength),
                with: sequence.ids
            )
            tokenTypes.replaceSubrange(
                sequenceOffset..<(sequenceOffset + ListwiseEncodedInput.sequenceLength),
                with: sequence.types
            )
            let features = encodeNumericFeatures(unit: unit, context: context)
            let numericOffset = candidateIndex * ListwiseEncodedInput.numericDimension
            numericFeatures.replaceSubrange(
                numericOffset..<(numericOffset + ListwiseEncodedInput.numericDimension),
                with: features
            )
            candidateMask[candidateIndex] = 1
        }

        return ListwiseEncodedInput(
            tokenIDs: tokenIDs,
            tokenTypes: tokenTypes,
            numericFeatures: numericFeatures,
            candidateMask: candidateMask
        )
    }

    private func encodeSequence(
        unit: CandidateUnit,
        context: CandidateSelectionContext
    ) -> (ids: [Int32], types: [Int32]) {
        let left = Array(context.precedingValues.joined().unicodeScalars.suffix(14))
        let candidate = Array(unit.surface.unicodeScalars.prefix(8))
        let reading = Array(context.combinedToken.unicodeScalars.prefix(12))
        let rightText = context.followingTokens.map(\.rawValue).joined()
        let right = Array(rightText.unicodeScalars.prefix(8))
        var ids: [Int32] = [TokenID.beginning, TokenID.left]
        var types: [Int32] = [TokenType.special, TokenType.special]

        func append(_ scalars: [UnicodeScalar], type: Int32) {
            for scalar in scalars {
                ids.append(characterID(for: scalar))
                types.append(type)
            }
        }

        append(left, type: TokenType.left)
        ids.append(TokenID.candidate)
        types.append(TokenType.special)
        append(candidate, type: TokenType.candidate)
        ids.append(TokenID.reading)
        types.append(TokenType.special)
        append(reading, type: TokenType.reading)
        ids.append(TokenID.right)
        types.append(TokenType.special)
        append(right, type: TokenType.right)
        ids.append(TokenID.end)
        types.append(TokenType.special)

        if ids.count > ListwiseEncodedInput.sequenceLength {
            ids = Array(ids.prefix(ListwiseEncodedInput.sequenceLength))
            types = Array(types.prefix(ListwiseEncodedInput.sequenceLength))
            ids[ids.count - 1] = TokenID.end
            types[types.count - 1] = TokenType.special
        }
        if ids.count < ListwiseEncodedInput.sequenceLength {
            let padding = ListwiseEncodedInput.sequenceLength - ids.count
            ids.append(contentsOf: repeatElement(TokenID.pad, count: padding))
            types.append(contentsOf: repeatElement(TokenType.pad, count: padding))
        }
        return (ids, types)
    }

    private func encodeNumericFeatures(
        unit: CandidateUnit,
        context: CandidateSelectionContext
    ) -> [Float] {
        let surfaceScalars = Array(unit.surface.unicodeScalars)
        let precedingLength = context.precedingValues.joined().unicodeScalars.count
        let scalarCount = max(1, surfaceScalars.count)
        let hanCount = surfaceScalars.filter(Self.isHan).count
        let latinCount = surfaceScalars.filter {
            $0.value < 128 && $0.properties.isAlphabetic
        }.count
        return [
            Float(min(max(unit.baseRank, 0), 19)) / 19,
            Float(min(max(unit.spanLength, 1), 8)) / 8,
            Float(min(surfaceScalars.count, 8)) / 8,
            Float(min(precedingLength, 24)) / 24,
            Float(min(context.followingTokens.count, 12)) / 12,
            Float(hanCount) / Float(scalarCount),
            Float(latinCount) / Float(scalarCount),
            unit.languageID == "zh-Hant" ? 1 : 0,
        ]
    }

    private func characterID(for scalar: UnicodeScalar) -> Int32 {
        var hash: UInt32 = 2_166_136_261
        hash ^= scalar.value
        hash = hash &* 16_777_619
        let bucketCount = UInt32(ListwiseEncodedInput.vocabularySize) - TokenID.hashOffset
        return Int32(TokenID.hashOffset + hash % bucketCount)
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        let value = scalar.value
        return (0x3400...0x4DBF).contains(value)
            || (0x4E00...0x9FFF).contains(value)
            || (0xF900...0xFAFF).contains(value)
            || (0x20000...0x2FA1F).contains(value)
    }
}
