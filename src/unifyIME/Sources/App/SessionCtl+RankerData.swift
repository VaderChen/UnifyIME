import Foundation

extension SessionCtl {
    static func dumpRankerData(
        cases: [SelfTestCase],
        source: String,
        outputPath: String,
        topK: Int = 20,
        tags: [String] = []
    ) -> DatasetDumpResult {
        let reverseMap = buildReverseLexicon()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            return DatasetDumpResult(totalCases: cases.count, resolvedCases: 0, sampleCount: 0)
        }
        defer { try? handle.close() }

        var resolvedCases = 0
        var sampleCount = 0

        for (caseIndex, testCase) in cases.enumerated() {
            guard let _ = testCase.readings,
                  let segments = reverseSegments(for: testCase.sentence, reverseMap: reverseMap) else {
                continue
            }
            resolvedCases += 1
            let allTokens = segments.flatMap { splitReadingIntoSyllables($0.reading) }
            var tokenCursor = 0

            for (segmentIndex, segment) in segments.enumerated() {
                let spanTokens = splitReadingIntoSyllables(segment.reading)
                let spanLength = spanTokens.count
                guard spanLength > 0 else { continue }

                let tokens = allTokens.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
                let prefix = Array(segments.prefix(segmentIndex).map(\.text).suffix(3))
                guard let input = traditionalChineseProvider.readingWalker.inputForSpan(tokens,
                    start: tokenCursor, length: spanLength, precedingValues: prefix) else {
                    tokenCursor += spanLength
                    continue
                }
                let ranked = candidateRanker.ranked(units: input.units, context: input.context, limit: max(1, topK))
                for (candidateIndex, item) in ranked.enumerated() {
                    let candidate = item.unit.surface
                    let isPositive = candidate == segment.text
                    let isHardNegative = !isPositive && candidate.count == segment.text.count
                    let sample = RankerSample(
                        feature_contract: CandidateFeatureContract.boundedSegmentsV2.rawValue,
                        sample_id: "case-\(caseIndex + 1)-seg-\(segmentIndex + 1)-cand-\(candidateIndex + 1)",
                        case_id: "case-\(caseIndex + 1)",
                        step_id: segmentIndex + 1,
                        source: source,
                        tags: tags,
                        language_id: traditionalChineseProvider.languageID,
                        all_tokens: input.context.allTokens.map(\.rawValue),
                        combined_token: segment.reading,
                        focused_token: segment.reading,
                        preceding_values: input.context.precedingValues,
                        following_tokens: input.context.followingTokens.map(\.rawValue),
                        candidate_surface: candidate,
                        candidate_reading_or_token: segment.reading,
                        span_start: item.unit.spanStart,
                        span_length: spanLength,
                        provider_score: item.unit.providerScore,
                        base_rank: item.unit.baseRank,
                        label: isPositive ? 1.0 : 0.0,
                        sample_weight: isPositive ? 1.5 : (isHardNegative ? 1.25 : 1.0)
                    )
                    guard let data = try? encoder.encode(sample) else { continue }
                    try? handle.write(contentsOf: data)
                    try? handle.write(contentsOf: Data("\n".utf8))
                    sampleCount += 1
                }

                tokenCursor += spanLength
            }
        }

        return DatasetDumpResult(totalCases: cases.count, resolvedCases: resolvedCases, sampleCount: sampleCount)
    }

    private static func goldSentenceCandidatePath(
        sentence: String,
        readings: [String],
        reverseMap: [String: [String]]
    ) -> SentenceCandidatePath? {
        let goldSegments = reverseSegments(for: sentence, reverseMap: reverseMap)
            ?? fallbackGoldSegments(for: sentence, groupedReadings: readings)
        guard let goldSegments else { return nil }
        var cursor = 0
        var composed: [ComposedSegment] = []
        for segment in goldSegments {
            let syllables = splitReadingIntoSyllables(segment.reading)
            guard !syllables.isEmpty else { return nil }
            composed.append(
                ComposedSegment(
                    languageID: traditionalChineseProvider.languageID,
                    reading: segment.reading,
                    value: segment.text,
                    start: cursor,
                    length: syllables.count
                )
            )
            cursor += syllables.count
        }
        return SentenceCandidatePath(
            text: sentence,
            readings: readings,
            segments: composed,
            localScore: sentenceLocalScore(for: composed, allTokens: readings)
        )
    }

    private static func fallbackGoldSegments(
        for sentence: String,
        groupedReadings: [String]
    ) -> [GoldSegment]? {
        let chars = Array(sentence)
        var cursor = 0
        var result: [GoldSegment] = []

        for reading in groupedReadings {
            let candidates = resolveCandidates(for: reading)
            guard let matched = candidates.first(where: { candidate in
                let candidateChars = Array(candidate)
                guard cursor + candidateChars.count <= chars.count else { return false }
                return Array(chars[cursor..<(cursor + candidateChars.count)]) == candidateChars
            }) else {
                return nil
            }
            result.append(GoldSegment(text: matched, reading: reading))
            cursor += matched.count
        }

        return cursor == chars.count ? result : nil
    }

    private static func sentenceLocalScore(for segments: [ComposedSegment], allTokens: [String]) -> Double {
        guard !segments.isEmpty else { return 0.0 }
        let tokens = allTokens.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
        return traditionalChineseProvider.readingWalker.scorePath(segments, tokens: tokens)
            ?? -Double.greatestFiniteMagnitude
    }

    private static func enumerateSentenceBeamPaths(
        tokens: [String],
        beamWidth: Int,
        topCandidatesPerSpan: Int,
        maxSpanLength: Int = 8
    ) -> [SentenceCandidatePath] {
        guard !tokens.isEmpty, maxSpanLength > 0, beamWidth > 0 else { return [] }
        let inputTokens = tokens.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
        let walker = traditionalChineseProvider.readingWalker
        var beams: [Int: [SentenceBeamPath]] = [0: [SentenceBeamPath(segments: [], localScore: 0.0)]]
        for start in 0..<tokens.count {
            guard let currentBeam = beams[start], !currentBeam.isEmpty else { continue }
            var nextBuckets: [Int: [SentenceBeamPath]] = [:]
            for path in currentBeam {
                let prefix = CandidateScoringInput.precedingValues(segments: path.segments, before: start)
                for length in 1...min(min(maxSpanLength, 8), tokens.count - start) {
                    let ranked = walker.rankedCandidates(inputTokens, start: start, length: length,
                        precedingValues: prefix, limit: max(1, topCandidatesPerSpan))
                    for candidate in ranked {
                        let segment = ComposedSegment(languageID: candidate.unit.languageID,
                            reading: candidate.unit.readingOrToken, value: candidate.unit.surface,
                            start: start, length: length)
                        let next = SentenceBeamPath(segments: path.segments + [segment],
                            localScore: path.localScore + candidate.score)
                        nextBuckets[start + length, default: []].append(next)
                    }
                }
            }

            for (index, bucket) in nextBuckets {
                let existing = beams[index] ?? []
                beams[index] = Array((existing + bucket).sorted { lhs, rhs in
                    if lhs.localScore == rhs.localScore {
                        return lhs.segments.map(\.value).joined() < rhs.segments.map(\.value).joined()
                    }
                    return lhs.localScore > rhs.localScore
                }.prefix(beamWidth))
            }
        }

        let finalPaths = beams[tokens.count] ?? []
        var dedup: [String: SentenceCandidatePath] = [:]
        for path in finalPaths {
            let text = path.segments.map(\.value).joined()
            let key = path.segments.map { "\($0.start):\($0.length):\($0.value)" }.joined(separator: "|")
            dedup[key] = SentenceCandidatePath(
                text: text,
                readings: tokens,
                segments: path.segments,
                localScore: path.localScore
            )
        }
        return dedup.values.sorted {
            if $0.localScore == $1.localScore {
                return $0.text < $1.text
            }
            return $0.localScore > $1.localScore
        }
    }

    private static func sentenceCandidatePath(
        segments: [ComposedSegment],
        readings: [String]
    ) -> SentenceCandidatePath {
        SentenceCandidatePath(
            text: segments.map(\.value).joined(),
            readings: readings,
            segments: segments,
            localScore: sentenceLocalScore(for: segments, allTokens: readings)
        )
    }

    private static func unifiedSegmentSamples(
        caseID: String,
        source: String,
        tags: [String],
        gold: SentenceCandidatePath,
        candidates: [SentenceCandidatePath]
    ) -> [UnifiedRankerSegmentSample] {
        var samples: [UnifiedRankerSegmentSample] = []
        let allTokens = gold.readings
        let goldByStart = Dictionary(uniqueKeysWithValues: gold.segments.map { ($0.start, $0) })
        var seen = Set<String>()

        for candidate in candidates {
            for segment in candidate.segments {
                let key = "\(segment.start):\(segment.length):\(segment.reading):\(segment.value)"
                if seen.contains(key) { continue }
                seen.insert(key)

                let stepID = segment.start + 1
                let tokens = allTokens.map { InputToken(languageID: segment.languageID, rawValue: $0) }
                let prefix = CandidateScoringInput.precedingValues(segments: candidate.segments, before: segment.start)
                guard let input = traditionalChineseProvider.readingWalker.inputForSpan(tokens,
                    start: segment.start, length: segment.length, precedingValues: prefix),
                      let unit = input.units.first(where: { $0.surface == segment.value }) else { continue }
                let label = goldByStart[segment.start].map {
                    $0.length == segment.length && $0.reading == segment.reading && $0.value == segment.value
                } == true ? 1.0 : 0.0

                samples.append(
                    UnifiedRankerSegmentSample(
                        sampleID: "\(caseID)-seg-\(stepID)-\(samples.count + 1)",
                        caseID: caseID,
                        stepID: stepID,
                        source: source,
                        tags: tags,
                        languageID: traditionalChineseProvider.languageID,
                        allTokens: input.context.allTokens.map(\.rawValue),
                        combinedToken: segment.reading,
                        focusedToken: segment.reading,
                        precedingValues: input.context.precedingValues,
                        followingTokens: input.context.followingTokens.map(\.rawValue),
                        candidateSurface: segment.value,
                        candidateReadingOrToken: segment.reading,
                        spanStart: unit.spanStart,
                        spanLength: segment.length,
                        providerScore: unit.providerScore,
                        baseRank: unit.baseRank,
                        label: label,
                        sampleWeight: label > 0 ? 1.5 : 1.0
                    )
                )
            }
        }

        return samples
    }

    private static func enumerateSentenceCandidatesAroundGold(
        gold: SentenceCandidatePath,
        topPaths: Int,
        topCandidatesPerSpan: Int
    ) -> [SentenceCandidatePath] {
        var candidates: [SentenceCandidatePath] = [gold]
        let segments = gold.segments
        let perSpanLimit = max(2, topCandidatesPerSpan)
        let targetCount = max(4, topPaths)

        func isNaturalSentenceCandidate(_ path: SentenceCandidatePath) -> Bool {
            guard !path.text.isEmpty, path.localScore.isFinite,
                  path.localScore > -Double.greatestFiniteMagnitude else { return false }
            guard !path.segments.contains(where: { $0.value == $0.reading }) else { return false }
            let bopomofoScalars = CharacterSet(charactersIn: "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙㄧㄨㄩㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦˇˋˊ˙")
            return !path.text.unicodeScalars.contains(where: { bopomofoScalars.contains($0) })
        }

        let inputTokens = gold.readings.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
        func replacementOptions(for segment: ComposedSegment, in path: [ComposedSegment], excluding value: String, limit: Int) -> [String] {
            let prefix = CandidateScoringInput.precedingValues(segments: path, before: segment.start)
            return Array(traditionalChineseProvider.readingWalker.rankedCandidates(inputTokens,
                start: segment.start, length: segment.length, precedingValues: prefix,
                limit: max(1, limit) + 1).map(\.unit.surface)
                .filter { $0 != value && isDisplayableCandidate($0) }.prefix(max(1, limit)))
        }

        for (index, segment) in segments.enumerated() {
            let options = replacementOptions(for: segment, in: segments, excluding: segment.value, limit: perSpanLimit)

            for value in options {
                var mutated = segments
                mutated[index] = ComposedSegment(
                    languageID: segment.languageID,
                    reading: segment.reading,
                    value: value,
                    start: segment.start,
                    length: segment.length
                )
                candidates.append(sentenceCandidatePath(segments: mutated, readings: gold.readings))
            }
        }

        if segments.count >= 2 {
            for firstIndex in 0..<(segments.count - 1) {
                let firstOptions = replacementOptions(
                    for: segments[firstIndex],
                    in: segments,
                    excluding: segments[firstIndex].value,
                    limit: 2
                )
                guard !firstOptions.isEmpty else { continue }
                for secondIndex in (firstIndex + 1)..<segments.count {
                    for firstValue in firstOptions {
                        var prefixPath = segments
                        prefixPath[firstIndex] = ComposedSegment(
                            languageID: segments[firstIndex].languageID,
                            reading: segments[firstIndex].reading, value: firstValue,
                            start: segments[firstIndex].start, length: segments[firstIndex].length)
                        let secondOptions = replacementOptions(for: prefixPath[secondIndex], in: prefixPath,
                            excluding: prefixPath[secondIndex].value, limit: 2)
                        for secondValue in secondOptions {
                            var mutated = prefixPath
                            mutated[secondIndex] = ComposedSegment(
                                languageID: segments[secondIndex].languageID,
                                reading: segments[secondIndex].reading,
                                value: secondValue,
                                start: segments[secondIndex].start,
                                length: segments[secondIndex].length
                            )
                            candidates.append(sentenceCandidatePath(segments: mutated, readings: gold.readings))
                        }
                    }
                }
            }
        }

        if segments.count >= 2 {
            for index in 0..<(segments.count - 1) {
                let lhs = segments[index]
                let rhs = segments[index + 1]
                let mergedReading = lhs.reading + rhs.reading
                let mergedSegment = ComposedSegment(languageID: lhs.languageID, reading: mergedReading,
                    value: lhs.value + rhs.value, start: lhs.start, length: lhs.length + rhs.length)
                let mergedOptions = replacementOptions(for: mergedSegment, in: segments,
                    excluding: mergedSegment.value, limit: perSpanLimit)
                for value in mergedOptions {
                    var mutated: [ComposedSegment] = Array(segments[..<index])
                    mutated.append(
                        ComposedSegment(
                            languageID: lhs.languageID,
                            reading: mergedReading,
                            value: value,
                            start: lhs.start,
                            length: lhs.length + rhs.length
                        )
                    )
                    if index + 2 < segments.count {
                        mutated.append(contentsOf: segments[(index + 2)...])
                    }
                    candidates.append(sentenceCandidatePath(segments: mutated, readings: gold.readings))
                }
            }
        }

        for (index, segment) in segments.enumerated() where segment.length > 1 {
            let tokenStart = segment.start
            let tokenEnd = segment.start + segment.length
            let slice = Array(gold.readings[tokenStart..<tokenEnd])
            let splitSegments = UnifiedCompositionEngine.resolveWalk(slice).map { resolved in
                ComposedSegment(
                    languageID: resolved.languageID,
                    reading: resolved.reading,
                    value: resolved.value,
                    start: resolved.start + tokenStart,
                    length: resolved.length
                )
            }
            guard splitSegments.count > 1 else { continue }
            var mutated = Array(segments[..<index])
            mutated.append(contentsOf: splitSegments)
            if index + 1 < segments.count {
                mutated.append(contentsOf: segments[(index + 1)...])
            }
            candidates.append(sentenceCandidatePath(segments: mutated, readings: gold.readings))
        }

        if !gold.readings.isEmpty {
            let beamCandidates = enumerateSentenceBeamPaths(
                tokens: gold.readings,
                beamWidth: max(topPaths * 3, 16),
                topCandidatesPerSpan: perSpanLimit,
                maxSpanLength: 8
            )
            candidates.append(contentsOf: beamCandidates.prefix(max(targetCount * 2, topPaths)))
        }

        var dedup: [String: SentenceCandidatePath] = [:]
        for candidate in candidates where isNaturalSentenceCandidate(candidate) {
            let key = candidate.segments.map { "\($0.start):\($0.length):\($0.value)" }.joined(separator: "|")
            if let existing = dedup[key], existing.localScore >= candidate.localScore {
                continue
            }
            dedup[key] = candidate
        }

        return dedup.values.sorted {
            if $0.localScore == $1.localScore {
                return $0.text < $1.text
            }
            return $0.localScore > $1.localScore
        }
    }

    static func dumpSentenceRerankerData(
        cases: [SelfTestCase],
        source: String,
        outputPath: String,
        topPaths: Int = 8,
        topCandidatesPerSpan: Int = 6,
        maxTokensPerCase: Int = 30,
        tags: [String] = []
    ) -> DatasetDumpResult {
        let reverseMap = buildReverseLexicon()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]

        let outputURL = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: outputURL) else {
            return DatasetDumpResult(totalCases: cases.count, resolvedCases: 0, sampleCount: 0)
        }
        defer { try? handle.close() }

        var resolvedCases = 0
        var sampleCount = 0

        for (caseIndex, testCase) in cases.enumerated() {
            guard let groupedReadings = testCase.readings else { continue }
            let tokens = groupedReadings.flatMap(splitReadingIntoSyllables)
            guard !tokens.isEmpty else { continue }
            guard tokens.count <= maxTokensPerCase else { continue }
            guard let gold = goldSentenceCandidatePath(sentence: testCase.sentence, readings: tokens, reverseMap: reverseMap) else {
                continue
            }
            resolvedCases += 1
            let rawCandidates = enumerateSentenceCandidatesAroundGold(
                gold: gold,
                topPaths: max(1, topPaths),
                topCandidatesPerSpan: max(1, topCandidatesPerSpan)
            )
            var textDedup: [String: SentenceCandidatePath] = [:]
            for candidate in rawCandidates {
                if let existing = textDedup[candidate.text], existing.localScore >= candidate.localScore {
                    continue
                }
                textDedup[candidate.text] = candidate
            }
            var candidates = Array(textDedup.values).sorted {
                if $0.localScore == $1.localScore {
                    return $0.text < $1.text
                }
                return $0.localScore > $1.localScore
            }
            candidates = Array(candidates.prefix(max(1, topPaths)))
            if !candidates.contains(where: { $0.text == gold.text && $0.segments == gold.segments }) {
                candidates.append(gold)
            }

            let context = SentenceRerankerContext()
            let caseID = "sentence-case-\(caseIndex + 1)"
            let example = SentenceRerankerExample(
                groupID: caseID,
                readings: tokens,
                goldText: testCase.sentence,
                candidates: candidates,
                context: context,
                segmentSamples: unifiedSegmentSamples(
                    caseID: caseID,
                    source: source,
                    tags: tags,
                    gold: gold,
                    candidates: rawCandidates
                )
            )
            guard let data = try? encoder.encode(example) else { continue }
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data("\n".utf8))
            sampleCount += 1
        }

        return DatasetDumpResult(totalCases: cases.count, resolvedCases: resolvedCases, sampleCount: sampleCount)
    }

    fileprivate static func rankCandidatesForAB(
        sentence: String,
        segments: [GoldSegment],
        useCoreML: Bool
    ) -> [RankerABRecord] {
        let ranker: UnifiedCandidateRanker = useCoreML ? CoreMLCandidateRanker() : HeuristicCandidateRanker()
        let allTokens = segments.flatMap { splitReadingIntoSyllables($0.reading) }
        var tokenCursor = 0
        var records: [RankerABRecord] = []

        for (segmentIndex, segment) in segments.enumerated() {
            let spanTokens = splitReadingIntoSyllables(segment.reading)
            let spanLength = spanTokens.count
            guard spanLength > 0 else { continue }
            let prefix = Array(segments.prefix(segmentIndex).map(\.text).suffix(3))
            let tokens = allTokens.map { InputToken(languageID: traditionalChineseProvider.languageID, rawValue: $0) }
            guard let input = traditionalChineseProvider.readingWalker.inputForSpan(tokens,
                start: tokenCursor, length: spanLength, precedingValues: prefix), !input.units.isEmpty else {
                tokenCursor += spanLength
                continue
            }
            let units = input.units
            let context = input.context
            let candidates = units.map(\.surface)
            let rankerScores = ranker.scores(units: units, context: context)
            let scored = zip(candidates, rankerScores).map { value, score in (value, score) }
            let ordered = scored.sorted { $0.1 > $1.1 }.map(\.0)
            let scores = scored.map(\.1)
            records.append(RankerABRecord(
                sentence: sentence,
                segment_index: segmentIndex + 1,
                segment_text: segment.text,
                reading: segment.reading,
                candidates: candidates,
                heuristic_scores: useCoreML ? [] : scores,
                coreml_scores: useCoreML ? scores : [],
                heuristic_order: useCoreML ? [] : ordered,
                coreml_order: useCoreML ? ordered : []
            ))
            tokenCursor += spanLength
        }

        return records
    }

    static func dumpRankerAB(
        cases: [SelfTestCase],
        outputPath: String
    ) {
        let reverseMap = buildReverseLexicon()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        var merged: [[String: Any]] = []

        for testCase in cases {
            guard let segments = reverseSegments(for: testCase.sentence, reverseMap: reverseMap) else { continue }
            let heur = rankCandidatesForAB(sentence: testCase.sentence, segments: segments, useCoreML: false)
            let core = rankCandidatesForAB(sentence: testCase.sentence, segments: segments, useCoreML: true)
            for idx in 0..<min(heur.count, core.count) {
                merged.append([
                    "sentence": testCase.sentence,
                    "segment_index": heur[idx].segment_index,
                    "segment_text": heur[idx].segment_text,
                    "reading": heur[idx].reading,
                    "candidates": heur[idx].candidates,
                    "heuristic_scores": heur[idx].heuristic_scores,
                    "coreml_scores": core[idx].coreml_scores,
                    "heuristic_order": heur[idx].heuristic_order,
                    "coreml_order": core[idx].coreml_order
                ])
            }
        }

        let url = URL(fileURLWithPath: outputPath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: merged, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: url)
        } else if let data = try? encoder.encode([RankerABRecord]()) {
            try? data.write(to: url)
        }
    }
}
