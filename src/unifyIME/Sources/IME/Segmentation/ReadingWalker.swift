import Foundation

struct ReadingWalker {
    private static let phraseStats = LexiconStore.loadPhraseContextStats()
    // 常見功能字不能被同音名詞或偶然雙字詞完全壓過；分數只在
    // 該字位於詞組邊界且仍有左右上下文時啟用。
    private static let aspectualFunctionWords: Set<String> = ["已", "曾", "正", "將", "再"]
    private static let neutralParticles: Set<String> = ["了", "著", "的", "地", "得", "嗎", "吧", "呢", "啊"]
    private static let grammaticalFunctionWords: Set<String> = [
        "而", "且", "並", "或", "及", "與", "但", "卻", "則", "也", "都", "的", "地", "得", "把", "被", "將", "在", "再"
    ]

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
                // 功能字也可能是完整詞的首字。若相同讀音已有保留該字的
                // 完整詞，不能再用功能字加分鼓勵把它拆開；交由詞與路徑
                // 本身的分數決定，不限制之後追加輸入時正常的重新切詞。
                var lexicalizedAspectWeights: [String: Double] = [:]
                var phraseReading = readings[start]
                for end in (start + 1)..<min(count, start + 8) {
                    phraseReading += readings[end]
                    for phrase in lexicon.phraseCandidateMap[phraseReading] ?? [] {
                        guard phrase.count == end - start + 1,
                              let first = phrase.first else { continue }
                        let word = String(first)
                        if Self.aspectualFunctionWords.contains(word) {
                            lexicalizedAspectWeights[word] = max(lexicalizedAspectWeights[word] ?? 0.0, Self.phraseStats.surfaceWeights[phrase] ?? 0.0)
                        }
                    }
                }
                // 比較與目前首字重疊、但從左側開始的完整詞。只有較強的
                // 詞庫證據存在時，才降低助詞組合的跨詞獎勵。
                var overlappingPrefixWeight = 0.0
                for prefixStart in max(0, start - 7)..<start {
                    let prefixReading = readings[prefixStart...start].joined()
                    for phrase in lexicon.phraseCandidateMap[prefixReading] ?? []
                        where phrase.count == start - prefixStart + 1 {
                        overlappingPrefixWeight = max(overlappingPrefixWeight, Self.phraseStats.surfaceWeights[phrase] ?? 0.0)
                    }
                }

                for end in start..<min(count, start + 8) {
                    combined += readings[end]
                    let spanLength = end - start + 1
                    let nextScore = (end + 1 < count) ? best[end + 1]?.score : terminalScore
                    guard let nextScore else { continue }
                    let segmentationBonus = Double(max(0, spanLength - 1) * 1800)
                    let singleSyllablePenalty = spanLength == 1 ? 150.0 : 0.0
                    // 保存各音節的功能字證據；是否跨越語法邊界，須在
                    // 取得候選詞字面後判斷，不能只因同音候選存在就懲罰完整詞。
                    let boundaryFunctions: [(left: [String], right: [String])] = spanLength > 1
                        ? (start..<end).map { boundary in
                            let left = lexicon.resolveCandidates(for: readings[boundary]).prefix(8)
                                .filter { Self.grammaticalFunctionWords.contains($0) }
                            let right = lexicon.resolveCandidates(for: readings[boundary + 1]).prefix(8)
                                .filter { Self.grammaticalFunctionWords.contains($0) }
                            return (left: left, right: right)
                        }
                        : []

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
                            // 每個讀音對應一個中文字；禁止以單字候選佔用多音節跨度，
                            // 避免「只要」被錯切成「之」等 DP 路徑。
                            let phraseSet = Set(lexicon.phraseCandidateMap[combined] ?? [])
                            // 多音節邊必須是詞庫中的完整詞；單純把各音節候選拼成
                            // 妖人、青幫等字串不能取得長度獎勵而吞掉正確拆分。
                            let matched = candidates.filter { $0.count == spanLength && phraseSet.contains($0) }
                            resolved = matched
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
                            let characters = value.map(String.init)
                            let phraseWeight = Self.phraseStats.surfaceWeights[value] ?? 0.0
                            // 單字接輕聲助詞是可自由組合的形式，不等同不可拆的
                            // 完整詞。保留候選與模型分數，但避免重複領取詞組加分，
                            // 使它跨越前一個完整詞的邊界搶走最後一字。
                            let isParticlePair = spanLength == 2 && characters.count == 2
                                && readings[end].hasSuffix("˙")
                                && Self.neutralParticles.contains(characters[1])
                                && lexicon.commonCharacterMap[readings[start]]?.contains(characters[0]) == true
                                && overlappingPrefixWeight > phraseWeight
                            let lexicalSegmentationBonus = isParticlePair ? 0.0 : segmentationBonus
                            var functionBoundaryPenalty = 0.0
                            for (offset, functions) in boundaryFunctions.enumerated() {
                                // 保留首選功能字才算保留原邊界證據；不能把所有
                                // 同音功能字視為等價，讓低順位替換也取得豁免。
                                let retainsLeft = functions.left.first == characters[offset]
                                let retainsRight = functions.right.first == characters[offset + 1]
                                if !functions.left.isEmpty && !functions.right.isEmpty {
                                    if !retainsLeft || !retainsRight {
                                        functionBoundaryPenalty += 5_000.0
                                    }
                                } else if !functions.right.isEmpty && !retainsRight {
                                    functionBoundaryPenalty += 6_000.0
                                }
                            }
                            let segment = ComposedSegment(
                                languageID: languageID,
                                reading: combined,
                                value: value,
                                start: start,
                                length: spanLength,
                                rawLength: rawLength(for: combined)
                            )
                            // Corpus frequency is only comparable for a lexicon-validated complete phrase.
                            // Applying it to arbitrary concatenations (for example 青幫) lets a
                            // suffix frequency overpower the left-context candidate (請幫).
                            let frequencyBonus = (spanLength > 1 && !isParticlePair && exactPhraseCandidates.contains(value) && phraseWeight > 0) ? min(log10(phraseWeight + 1.0) * 1200.0, 5000.0) : 0.0
                            // An exact multi-syllable lexicon phrase is stronger evidence than
                            // an accidental sequence of individually valid characters. Keep the
                            // learned ranker for ordering competing phrases, but do not let its
                            // absolute scale break phrase segmentation.
                            // 只有詞庫驗證的完整詞才取得完整詞 bonus；功能字詞本身
                            // 仍可作為合法詞尾（例如「以及」），不可用候選存在性否定它。
                            let exactPhraseBonus = (spanLength > 1 && !isParticlePair && exactPhraseCandidates.contains(value)) ? 5_000.0 : 0.0
                            let hasFollowingContext = end + 1 < count
                            // 語法上下文加分必須有精確讀音依據；聲調與近音退避候選
                            // 仍可顯示，但不能藉語法加分改寫已輸入的讀音。
                            let hasExactReading = exactPhraseCandidates.contains(value)
                                || lexicon.commonCharacterMap[combined]?.contains(value) == true
                            let functionWordBonus = hasExactReading && spanLength == 1 && value.count == 1 && Self.grammaticalFunctionWords.contains(value) && hasFollowingContext ? 500.0 : 0.0
                            let adjacentPhraseBonus = 0.0
                            let followingPhraseWeight = end + 1 < count
                                ? (best[end + 1].flatMap { Self.phraseStats.surfaceWeights[$0.segment.value] } ?? 0.0)
                                : 0.0
                            let hasStrongerLexicalContinuation = (lexicalizedAspectWeights[value] ?? 0.0) > followingPhraseWeight
                            let aspectContextBonus = hasExactReading && spanLength == 1 && Self.aspectualFunctionWords.contains(value) && !hasStrongerLexicalContinuation && end + 1 < count ? 3000.0 : 0.0
                            let userFreq = userFreqMap[value] ?? 0
                            let userFreqBonus = userFreq > 0 ? min(log2(Double(userFreq) + 1.0) * 40.0, 400.0) : 0.0
                            let localRankGuard = 0.0 // 基礎排序已計入模型，不重複獎勵拆分後的單字。
                            let score = nextScore + rankerScores[rank] + lexicalSegmentationBonus + localRankGuard + frequencyBonus + exactPhraseBonus + functionWordBonus + adjacentPhraseBonus + aspectContextBonus + userFreqBonus - singleSyllablePenalty - functionBoundaryPenalty
                            if isRuntimeTraceEnabled {
                                appendRuntimeTrace("lattice.edge range=\(start)..<\(end + 1) reading=\(combined) value=\(value) model=\(rankerScores[rank]) segmentation=\(lexicalSegmentationBonus) frequency=\(frequencyBonus) exact=\(exactPhraseBonus) function=\(functionWordBonus) aspect=\(aspectContextBonus) particlePair=\(isParticlePair) exactReading=\(hasExactReading) provider=\(units[rank].providerScore) baseRank=\(units[rank].baseRank) singlePenalty=\(singleSyllablePenalty) adjacent=\(adjacentPhraseBonus) boundaryPenalty=\(functionBoundaryPenalty) userCount=\(userFreq) userBonus=\(userFreqBonus) suffix=\(nextScore) total=\(score)")
                            }
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
            if isRuntimeTraceEnabled {
                appendRuntimeTrace("lattice.path readings=\(readings.joined(separator: "/")) segments=\(result.map { "\($0.start):\($0.length)=\($0.value)" }.joined(separator: "|")) score=\(best.first.flatMap { $0?.score } ?? 0)")
            }
            return rerankResolvedSegments(result, allTokens: tokens)
        }
    }

    private func rerankResolvedSegments(
        _ segments: [ComposedSegment],
        allTokens: [InputToken]
    ) -> [ComposedSegment] {
        // 此階段只輸出診斷，不參與決策；關閉 trace 時不執行額外模型推論。
        guard isRuntimeTraceEnabled, !segments.isEmpty else { return segments }
        let resolved = segments
        // DP 已在同一分數空間比較完整詞與拆分詞；禁止 DP 後依詞庫順序覆寫。
        for index in resolved.indices {
            let segment = resolved[index]
            let exactPhrases = lexicon.phraseCandidateMap[segment.reading] ?? []
            // Automatic replacement is intentionally conservative: only an
            // exact multi-syllable phrase may be replaced, and only by another
            // exact phrase for the same reading.  Single-character homophones
            // remain visible in the candidate window but never silently alter
            // committed text.
            let candidatePool: [String]
            if segment.length > 1 {
                guard exactPhrases.contains(segment.value), exactPhrases.count > 1 else { continue }
                candidatePool = Array(exactPhrases.prefix(20))
            } else {
                let singles = lexicon.resolveCandidates(for: segment.reading).filter { $0.count == 1 }
                guard singles.count > 1, singles.contains(segment.value) else { continue }
                candidatePool = Array(singles.prefix(20))
            }
            let candidates = candidatePool
            guard candidates.count > 1 else { continue }
            // The NN is an advisor over the algorithm path. Feed it the same
            // bounded prefix semantics used by training: the last three committed
            // characters of the algorithm's current best path.
            let prefixText = String(resolved.prefix(index).map(\.value).joined().suffix(3))
            let precedingValues = prefixText.isEmpty ? [] : [prefixText]
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
            let agreesWithAlgorithm = selected == segment.value
            if isRuntimeTraceEnabled {
                appendRuntimeTrace("nn.prefix reading=\(segment.reading) prefix=\(prefixText) algorithm=\(segment.value) nn=\(selected) consensus=\(agreesWithAlgorithm) right=\(followingTokens.map(\.rawValue).joined())")
            }
            // NN remains advisory here. A disagreement is observable in trace but
            // cannot replace the algorithm path after commit. The DP result is the
            // only committed value; candidate scores are exposed for diagnostics.
        }
        return resolved
    }
}
