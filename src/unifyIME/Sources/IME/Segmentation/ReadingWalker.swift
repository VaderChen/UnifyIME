import Foundation

struct ReadingWalker {
    private static let phraseStats = LexiconStore.loadPhraseContextStats()

    let lexicon: LexiconStore
    let ranker: UnifiedCandidateRanker
    let languageID: String

    private func rawLength(for reading: String) -> Int {
        if languageID == "zh-Hant" {
            let sequence = SessionCtl.keySequence(for: [reading]).replacingOccurrences(of: " ", with: "")
            return max(1, sequence.count)
        }
        return max(1, reading.count)
    }

    func resolveWalk(_ tokens: [InputToken]) -> [ComposedSegment] {
        profileRuntime("readingWalker.resolveWalk", details: "tokens=\(tokens.count)") {
            let readings = tokens.map(\.rawValue)
            guard !readings.isEmpty else { return [] }

            struct WalkChoice {
                let score: Double
                let segment: ComposedSegment
                let nextIndex: Int
            }

            let count = readings.count
            var best: [WalkChoice?] = Array(repeating: nil, count: count)
            let terminalScore = 0.0
            var candidatesByReading: [String: [String]] = [:]
            var scoredCandidatesBySpan: [String: [String]] = [:]
            var userFrequencyByReading: [String: [String: Int]] = [:]
            var exactPhraseCandidatesByReading: [String: Set<String>] = [:]
            var followingTokensByEnd: [Int: [InputToken]] = [:]

            for start in stride(from: count - 1, through: 0, by: -1) {
                var combined = ""
                var localBest: WalkChoice?

                for end in start..<min(count, start + 8) {
                    combined += readings[end]
                    let spanLength = end - start + 1
                    let nextScore = (end + 1 < count) ? best[end + 1]?.score : terminalScore
                    guard let nextScore else { continue }
                    let segmentationBonus = Double(max(0, spanLength - 1) * 1800)
                    let singleSyllablePenalty = spanLength == 1 ? 150.0 : 0.0

                    let candidates = candidatesByReading[combined] ?? {
                        let resolved = lexicon.resolveCandidates(for: combined)
                        candidatesByReading[combined] = resolved
                        return resolved
                    }()
                    let spanKey = "\(combined)|\(spanLength)"
                    let scoredCandidates = scoredCandidatesBySpan[spanKey] ?? {
                        let resolved: [String]
                        if spanLength == 1 {
                            let singles = candidates.filter { $0.count == 1 }
                            resolved = singles.isEmpty ? candidates : singles
                        } else {
                            resolved = candidates
                        }
                        scoredCandidatesBySpan[spanKey] = resolved
                        return resolved
                    }()
                    if scoredCandidates != [combined] {
                        let userFreqMap = userFrequencyByReading[combined] ?? {
                            let frequencies = UserFrequencyStore.frequencyMap(languageID: languageID, reading: combined)
                            userFrequencyByReading[combined] = frequencies
                            return frequencies
                        }()
                        let followingTokens = followingTokensByEnd[end] ?? {
                            let suffix = end + 1 < count ? Array(tokens[(end + 1)...]) : []
                            followingTokensByEnd[end] = suffix
                            return suffix
                        }()
                        let context = CandidateSelectionContext(
                            languageID: languageID,
                            allTokens: tokens,
                            combinedToken: combined,
                            spanLength: spanLength,
                            precedingValues: [],
                            followingTokens: followingTokens,
                            focusedToken: combined
                        )
                        let rankedValues = Array(scoredCandidates.prefix(8))
                        let units = rankedValues.enumerated().map { rank, value in
                            CandidateUnit(
                                languageID: languageID,
                                surface: value,
                                readingOrToken: combined,
                                spanStart: start,
                                spanLength: spanLength,
                                providerScore: Double(-rank),
                                baseRank: rank
                            )
                        }
                        // Keep the dynamic-programming search on the cheap
                        // heuristic/legacy scalar path.  Running a listwise
                        // Transformer for every possible span multiplies the
                        // inference count quadratically on long input.
                        let rankerScores = units.map {
                            ranker.score(unit: $0, context: context)
                        }
                        let exactPhraseCandidates = exactPhraseCandidatesByReading[combined] ?? {
                            let phrases = Set(lexicon.phraseCandidateMap[combined] ?? [])
                            exactPhraseCandidatesByReading[combined] = phrases
                            return phrases
                        }()
                        for rank in rankedValues.indices {
                            let value = rankedValues[rank]
                            let segment = ComposedSegment(
                                languageID: languageID,
                                reading: combined,
                                value: value,
                                start: start,
                                length: spanLength,
                                rawLength: rawLength(for: combined)
                            )
                            let phraseWeight = Self.phraseStats.surfaceWeights[value] ?? 0.0
                            let frequencyBonus = phraseWeight > 0 ? min(log10(phraseWeight + 1.0) * 1200.0, 5000.0) : 0.0
                            // An exact multi-syllable lexicon phrase is stronger evidence than
                            // an accidental sequence of individually valid characters. Keep the
                            // learned ranker for ordering competing phrases, but do not let its
                            // absolute scale break phrase segmentation.
                            let exactPhraseBonus = (spanLength > 1 && exactPhraseCandidates.contains(value)) ? 100_000.0 : 0.0
                            let userFreq = userFreqMap[value] ?? 0
                            let userFreqBonus = userFreq > 0 ? min(Double(userFreq) * 600.0, 10000.0) : 0.0
                            let score = nextScore + rankerScores[rank] + segmentationBonus + frequencyBonus + exactPhraseBonus + userFreqBonus - singleSyllablePenalty
                            if localBest == nil || score > localBest!.score {
                                localBest = WalkChoice(score: score, segment: segment, nextIndex: end + 1)
                            }
                        }
                    }

                    if spanLength == 1 {
                        let single = readings[start]
                        let fallbackValue = scoredCandidates.first ?? candidates.first ?? single
                        let segment = ComposedSegment(
                            languageID: languageID,
                            reading: single,
                            value: fallbackValue,
                            start: start,
                            length: 1,
                            rawLength: rawLength(for: single)
                        )
                        let score = nextScore - 4000 - singleSyllablePenalty
                        if localBest == nil || score > localBest!.score {
                            localBest = WalkChoice(score: score, segment: segment, nextIndex: start + 1)
                        }
                    }
                }

                best[start] = localBest
            }

            var result: [ComposedSegment] = []
            var cursor = 0
            while cursor < count, let choice = best[cursor] {
                result.append(choice.segment)
                cursor = choice.nextIndex
            }
            return rerankResolvedSegments(result, allTokens: tokens)
        }
    }

    private func rerankResolvedSegments(
        _ segments: [ComposedSegment],
        allTokens: [InputToken]
    ) -> [ComposedSegment] {
        guard ranker.isListwiseRerankingAvailable, !segments.isEmpty else { return segments }
        var resolved = segments
        for index in resolved.indices {
            let segment = resolved[index]
            let exactPhrases = lexicon.phraseCandidateMap[segment.reading] ?? []
            // Automatic replacement is intentionally conservative: only an
            // exact multi-syllable phrase may be replaced, and only by another
            // exact phrase for the same reading.  Single-character homophones
            // remain visible in the candidate window but never silently alter
            // committed text.
            guard segment.length > 1,
                  exactPhrases.contains(segment.value),
                  exactPhrases.count > 1 else { continue }
            let candidates = Array(exactPhrases.prefix(20))
            guard candidates.count > 1 else { continue }
            let precedingValues = Array(resolved.prefix(index).map(\.value).suffix(3))
            let followingTokens = Array(allTokens.dropFirst(segment.start + segment.length))
            let context = CandidateSelectionContext(
                languageID: languageID,
                allTokens: allTokens,
                combinedToken: segment.reading,
                spanLength: segment.length,
                precedingValues: precedingValues,
                followingTokens: followingTokens,
                focusedToken: segment.reading
            )
            let units = candidates.enumerated().map { rank, value in
                CandidateUnit(
                    languageID: languageID,
                    surface: value,
                    readingOrToken: segment.reading,
                    spanStart: segment.start,
                    spanLength: segment.length,
                    providerScore: Double(-rank),
                    baseRank: rank
                )
            }
            let scores = ranker.scores(units: units, context: context)
            guard scores.count == units.count else { continue }
            let bestIndex = units.indices.max { lhs, rhs in
                if scores[lhs] == scores[rhs] {
                    return units[lhs].baseRank > units[rhs].baseRank
                }
                return scores[lhs] < scores[rhs]
            } ?? 0
            let selected = units[bestIndex].surface
            if selected != segment.value {
                resolved[index] = ComposedSegment(
                    languageID: segment.languageID,
                    reading: segment.reading,
                    value: selected,
                    start: segment.start,
                    length: segment.length,
                    rawLength: segment.rawLength
                )
            }
        }
        return resolved
    }
}
