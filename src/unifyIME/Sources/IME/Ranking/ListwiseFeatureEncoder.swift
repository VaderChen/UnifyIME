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
        var tokenIDs = Array(repeating: TokenID.pad,
            count: ListwiseEncodedInput.maxCandidates * ListwiseEncodedInput.sequenceLength)
        var tokenTypes = Array(repeating: TokenType.pad, count: tokenIDs.count)
        var numericFeatures = Array(repeating: Float(0),
            count: ListwiseEncodedInput.maxCandidates * ListwiseEncodedInput.numericDimension)
        var candidateMask = Array(repeating: Float(0), count: ListwiseEncodedInput.maxCandidates)
        guard !units.isEmpty else {
            return ListwiseEncodedInput(tokenIDs: tokenIDs, tokenTypes: tokenTypes,
                numericFeatures: numericFeatures, candidateMask: candidateMask)
        }

        // 同組候選共用上下文；每個字元只雜湊一次，直接填入最終張量。
        let leftText = context.precedingValues.joined()
        let left = leftText.unicodeScalars.suffix(14).map(characterID)
        let reading = context.combinedToken.unicodeScalars.prefix(12).map(characterID)
        let right = context.followingTokens.lazy.map(\.rawValue).joined(separator: "")
            .unicodeScalars.prefix(8).map(characterID)
        let precedingLength = Float(min(leftText.unicodeScalars.count, 24)) / 24
        let followingLength = Float(min(context.followingTokens.count, 12)) / 12

        for (candidateIndex, unit) in units.prefix(ListwiseEncodedInput.maxCandidates).enumerated() {
            var offset = candidateIndex * ListwiseEncodedInput.sequenceLength
            func append(_ id: Int32, type: Int32 = TokenType.special) {
                tokenIDs[offset] = id
                tokenTypes[offset] = type
                offset += 1
            }
            append(TokenID.beginning)
            append(TokenID.left)
            for id in left { append(id, type: TokenType.left) }
            append(TokenID.candidate)
            var scalarCount = 0
            var hanCount = 0
            var latinCount = 0
            for scalar in unit.surface.unicodeScalars {
                if scalarCount < 8 { append(characterID(for: scalar), type: TokenType.candidate) }
                scalarCount += 1
                if Self.isHan(scalar) { hanCount += 1 }
                if scalar.value < 128 && scalar.properties.isAlphabetic { latinCount += 1 }
            }
            append(TokenID.reading)
            for id in reading { append(id, type: TokenType.reading) }
            append(TokenID.right)
            for id in right { append(id, type: TokenType.right) }
            append(TokenID.end)
            // 6 個特殊符號 + 14 / 8 / 12 / 8 字元，最多恰好 48 格。
            let numericOffset = candidateIndex * ListwiseEncodedInput.numericDimension
            numericFeatures[numericOffset] = Float(min(max(unit.baseRank, 0), 19)) / 19
            numericFeatures[numericOffset + 1] = Float(min(max(unit.spanLength, 1), 8)) / 8
            numericFeatures[numericOffset + 2] = Float(min(scalarCount, 8)) / 8
            numericFeatures[numericOffset + 3] = precedingLength
            numericFeatures[numericOffset + 4] = followingLength
            numericFeatures[numericOffset + 5] = Float(hanCount) / Float(max(1, scalarCount))
            numericFeatures[numericOffset + 6] = Float(latinCount) / Float(max(1, scalarCount))
            numericFeatures[numericOffset + 7] = unit.languageID == "zh-Hant" ? 1 : 0
            candidateMask[candidateIndex] = 1
        }
        return ListwiseEncodedInput(tokenIDs: tokenIDs, tokenTypes: tokenTypes,
            numericFeatures: numericFeatures, candidateMask: candidateMask)
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
