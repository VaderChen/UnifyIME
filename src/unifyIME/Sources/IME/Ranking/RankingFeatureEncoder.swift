import Foundation

enum CandidateFeatureContract: String {
    case legacySegmentsV1 = "legacy_segments_v1"
    case boundedSegmentsV2 = "bounded_segments_v2"
}

struct RankingFeatureEncoder {
    private static let phraseStats = LexiconStore.loadPhraseContextStats()

    func encode(unit: CandidateUnit, context suppliedContext: CandidateSelectionContext,
                contract: CandidateFeatureContract = .boundedSegmentsV2) -> RankingFeatureVector {
        let coordinates = contract == .legacySegmentsV1 ? suppliedContext.legacyModelCoordinates : nil
        let context = CandidateSelectionContext(languageID: suppliedContext.languageID,
            allTokens: suppliedContext.allTokens, combinedToken: suppliedContext.combinedToken,
            spanLength: suppliedContext.spanLength, precedingValues: suppliedContext.precedingValues,
            followingTokens: coordinates?.followingTokens ?? suppliedContext.followingTokens,
            focusedToken: suppliedContext.focusedToken)
        let candidateLength = Double(unit.surface.count)
        let tokenLength = Double(unit.readingOrToken.count)
        let precedingCount = Double(context.precedingValues.count)
        let followingCount = Double(context.followingTokens.count)
        let exactTokenMatch = unit.surface == context.combinedToken ? 1.0 : 0.0
        let sameLanguage = unit.languageID == context.languageID ? 1.0 : 0.0
        let isPhrase = candidateLength > 1 ? 1.0 : 0.0
        let hasToneMarks = context.combinedToken.contains(where: Self.isToneMark(_:)) ? 1.0 : 0.0
        let normalizedMatch = Self.normalizeToken(unit.readingOrToken) == Self.normalizeToken(context.combinedToken) ? 1.0 : 0.0
        let script = Self.scriptClass(for: unit.surface)

        var features: [Double] = [
            // HeuristicCandidateRanker already owns provider/base ordering.
            // Keep NN as a residual signal so it cannot learn the shortcut of
            // blindly copying the original candidate rank.
            0.0,
            0.0,
            Double(unit.spanLength),
            candidateLength,
            tokenLength,
            precedingCount,
            followingCount,
            exactTokenMatch,
            sameLanguage,
            isPhrase,
            hasToneMarks,
            normalizedMatch,
            Double(coordinates?.spanStart ?? unit.spanStart),
            Double(context.focusedToken.count),
            Double(coordinates?.tokenCount ?? context.allTokens.count)
        ]

        features.reserveCapacity(RankingFeatureVector.expectedDimension)
        appendOneHot(index: script.rawValue, count: 5, into: &features)
        appendOneHot(index: languageBucket(for: unit.languageID), count: 4, into: &features)
        features.append(contentsOf: aggregateContextFeatures(context.precedingValues))
        features.append(contentsOf: aggregateFollowingFeatures(context.followingTokens))
        features.append(contentsOf: localContextFeatures(unit: unit, context: context))
        features.append(contentsOf: phraseContextFeatures(unit: unit, context: context))
        appendCandidateIdentityFeatures(unit: unit, context: context, into: &features)

        if features.count < RankingFeatureVector.expectedDimension {
            features.append(contentsOf: Array(repeating: 0.0, count: RankingFeatureVector.expectedDimension - features.count))
        } else if features.count > RankingFeatureVector.expectedDimension {
            features = Array(features.prefix(RankingFeatureVector.expectedDimension))
        }

        return RankingFeatureVector(values: features)
    }

    private func aggregateContextFeatures(_ values: [String]) -> [Double] {
        let recent = values.suffix(3)
        var totalChars = 0, hanCount = 0, mixedCount = 0
        for value in recent {
            totalChars += value.count
            for scalar in value.unicodeScalars where Self.isHan(scalar) { hanCount += 1 }
            if Self.scriptClass(for: value) == .mixed { mixedCount += 1 }
        }
        return [Double(recent.count), Double(totalChars), Double(hanCount), Double(mixedCount)]
    }

    private func aggregateFollowingFeatures(_ tokens: [InputToken]) -> [Double] {
        let recent = tokens.prefix(3)
        var totalChars = 0, zhCount = 0, latinCount = 0
        for token in recent {
            totalChars += token.rawValue.count
            if token.languageID == "zh-Hant" { zhCount += 1 }
            if Self.scriptClass(for: token.rawValue) == .latin { latinCount += 1 }
        }
        return [Double(recent.count), Double(totalChars), Double(zhCount), Double(latinCount)]
    }

    private func localContextFeatures(unit: CandidateUnit, context: CandidateSelectionContext) -> [Double] {
        let prev1 = context.precedingValues.last ?? ""
        let prev2 = context.precedingValues.dropLast().last ?? ""
        let next1 = context.followingTokens.first?.rawValue ?? ""
        let next2 = context.followingTokens.dropFirst().first?.rawValue ?? ""
        let precedingJoined = context.precedingValues.suffix(3).joined(separator: "|")
        let followingJoined = context.followingTokens.prefix(3).lazy.map(\.rawValue).joined(separator: "|")

        return [
            Double(prev1.count),
            hanRatio(for: prev1),
            stableHashFeature(for: prev1),
            stableHashFeature(for: prev2),
            Double(next1.count),
            hanRatio(for: next1),
            stableHashFeature(for: next1),
            stableHashFeature(for: next2),
            charOverlapRatio(lhs: prev1, rhs: unit.surface),
            charOverlapRatio(lhs: unit.surface, rhs: next1),
            stableHashFeature(for: prev1 + "|" + context.focusedToken),
            stableHashFeature(for: context.focusedToken + "|" + next1),
            stableHashFeature(for: precedingJoined),
            stableHashFeature(for: followingJoined),
            Double(context.precedingValues.count - context.followingTokens.count),
            boundaryMatchScore(prev: prev1, candidate: unit.surface, next: next1),
        ]
    }

    private func phraseContextFeatures(unit: CandidateUnit, context: CandidateSelectionContext) -> [Double] {
        let prev1 = context.precedingValues.last ?? ""
        let prevTail = String(prev1.suffix(1))
        let next1Reading = context.followingTokens.first?.rawValue ?? ""
        let combinedPlusNextReading = context.combinedToken + next1Reading
        let precedingSurface = prev1 + unit.surface

        return [
            phraseLogWeight(forSurface: unit.surface),
            phraseLogWeight(forSurface: precedingSurface),
            phraseLogWeight(forSurface: prevTail + unit.surface),
            normalizedReadingCount(forReading: context.combinedToken),
            normalizedBestPhraseLength(forReading: context.combinedToken),
            normalizedReadingCount(forReading: combinedPlusNextReading),
            normalizedBestPhraseLength(forReading: combinedPlusNextReading),
            phraseExists(forSurface: precedingSurface) ? 1.0 : 0.0,
        ]
    }

    private func appendCandidateIdentityFeatures(unit: CandidateUnit, context: CandidateSelectionContext,
                                                 into features: inout [Double]) {
        let prev1 = context.precedingValues.last ?? ""
        let next1 = context.followingTokens.first?.rawValue ?? ""
        func append(_ signature: String) {
            appendOneHot(index: stableHashBucket(for: signature, count: 8), count: 8, into: &features)
        }
        append(unit.surface)
        append(prev1 + "|" + unit.surface)
        append(unit.surface + "|" + next1)
        append(prev1 + "|" + unit.surface + "|" + next1)
    }

    private func languageBucket(for languageID: String) -> Int {
        switch languageID {
        case "zh-Hant": return 0
        case "en": return 1
        case "ja": return 2
        default: return 3
        }
    }

    private func appendOneHot(index: Int, count: Int, into features: inout [Double]) {
        for position in 0..<count { features.append(position == index ? 1.0 : 0.0) }
    }

    private static let toneMarks = CharacterSet(charactersIn: "ˇˋˊ˙")
    private static func normalizeToken(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        result.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars where !toneMarks.contains(scalar) { result.append(scalar) }
        return String(result)
    }

    private static func isToneMark(_ char: Character) -> Bool {
        "ˇˋˊ˙".contains(char)
    }

    private static func scriptClass(for text: String) -> CandidateScriptClass {
        guard !text.isEmpty else { return .other }
        var hasHan = false
        var hasLatin = false
        var hasKana = false
        var hasOther = false

        for scalar in text.unicodeScalars {
            if isHan(scalar) {
                hasHan = true
            } else if CharacterSet.letters.contains(scalar), scalar.properties.isAlphabetic, scalar.isASCII {
                hasLatin = true
            } else if (0x3040...0x309F).contains(scalar.value) || (0x30A0...0x30FF).contains(scalar.value) {
                hasKana = true
            } else {
                hasOther = true
            }
        }

        let activeCount = (hasHan ? 1 : 0) + (hasLatin ? 1 : 0) + (hasKana ? 1 : 0) + (hasOther ? 1 : 0)
        if activeCount > 1 { return .mixed }
        if hasHan { return .han }
        if hasLatin { return .latin }
        if hasKana { return .kana }
        return .other
    }

    private static func isHan(_ scalar: UnicodeScalar) -> Bool {
        (0x3400...0x4DBF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
    }

    private func hanRatio(for text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }
        let hanCount = text.unicodeScalars.reduce(0) { $0 + (Self.isHan($1) ? 1 : 0) }
        return Double(hanCount) / Double(max(text.count, 1))
    }

    private func stableHashFeature(for text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }
        var hash = UInt64(5381)
        for scalar in text.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        return Double(hash % 4096) / 4095.0
    }

    private func stableHashBucket(for text: String, count: Int) -> Int {
        guard !text.isEmpty, count > 0 else { return -1 }
        var hash = UInt64(5381)
        for scalar in text.unicodeScalars {
            hash = ((hash << 5) &+ hash) &+ UInt64(scalar.value)
        }
        return Int(hash % UInt64(count))
    }

    private func charOverlapRatio(lhs: String, rhs: String) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0.0 }
        let leftSet = Set(lhs)
        let rightSet = Set(rhs)
        let overlap = rightSet.reduce(0) { $0 + (leftSet.contains($1) ? 1 : 0) }
        return Double(overlap) / Double(max(min(leftSet.count, rightSet.count), 1))
    }

    private func boundaryMatchScore(prev: String, candidate: String, next: String) -> Double {
        var score = 0.0
        if let prevLast = prev.last, let candidateFirst = candidate.first, prevLast == candidateFirst {
            score += 0.5
        }
        if let candidateLast = candidate.last, let nextFirst = next.first, candidateLast == nextFirst {
            score += 0.5
        }
        return score
    }

    private func phraseLogWeight(forSurface surface: String) -> Double {
        guard let weight = Self.phraseStats.surfaceWeights[surface], weight > 0 else { return 0.0 }
        return log1p(weight) / 10.0
    }

    private func normalizedReadingCount(forReading reading: String) -> Double {
        guard !reading.isEmpty else { return 0.0 }
        let count = Self.phraseStats.readingCandidateCounts[reading] ?? 0
        return min(log1p(Double(count)) / 6.0, 1.0)
    }

    private func normalizedBestPhraseLength(forReading reading: String) -> Double {
        guard !reading.isEmpty else { return 0.0 }
        let length = Self.phraseStats.readingBestLengths[reading] ?? 0
        return min(Double(length) / 8.0, 1.0)
    }

    private func phraseExists(forSurface surface: String) -> Bool {
        Self.phraseStats.surfaceWeights[surface] != nil
    }
}
