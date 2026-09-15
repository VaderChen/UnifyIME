import Foundation

struct HeuristicCandidateRanker: UnifiedCandidateRanker {
    private static let phraseStats = LexiconStore.loadPhraseContextStats()
    private static let spanCalibration: [String: [Int: Double]] = {
        // 每個詞形只計一次，異讀不能重複增加字的背景頻率。
        let words = phraseStats.surfaceWeights.filter {
            (2...8).contains($0.key.count) && LexiconStore.isDisplayableCandidate($0.key)
        }
        var characters: [Character: Double] = [:]
        var wordMass = 0.0
        var characterMass = 0.0
        for (word, weight) in words {
            wordMass += weight
            for character in word {
                characters[character, default: 0] += weight
                characterMass += weight
            }
        }
        guard wordMass > 0, characterMass > 0 else { return [:] }
        var result: [String: [Int: Double]] = [:]
        for (reading, candidates) in phraseStats.readingSurfaceWeights {
            var references: [Int: (String, Double)] = [:]
            for (word, weight) in candidates where words[word] != nil {
                let length = word.count
                if let current = references[length],
                   current.1 > weight || (current.1 == weight && current.0 < word) { continue }
                references[length] = (word, weight)
            }
            for (length, reference) in references {
                let (word, weight) = reference
                // 詞的觀察機率，相對於各字獨立出現的機率；保留負證據。
                let independent = word.reduce(0.0) { total, character in
                    total + log((characters[character] ?? 1) / characterMass)
                }
                let association = (log(weight / wordMass) - independent) * 120
                let bound = 500.0 * Double(length - 1)
                let evidence = min(bound, max(-bound, association)) * weight / (weight + 1)
                let referenceCorpus = min(log10(weight + 1) * 120, 500) * Double(length)
                // 相同讀音與跨度扣除同一基準，同音候選分差不變。
                result[reading, default: [:]][length] = evidence - referenceCorpus
            }
        }
        return result
    }()

    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double {
        let count = UserFrequencyStore.frequency(languageID: unit.languageID,
            reading: unit.readingOrToken, surface: unit.surface)
        let preference = PersonalVocabularyStore.bonus(language: unit.languageID,
            reading: unit.readingOrToken, surface: unit.surface)
        return score(unit: unit, count: count, preference: preference)
    }

    func scores(units: [CandidateUnit], context: CandidateSelectionContext) -> [Double] {
        // 同一讀音只讀一次彙整紀錄，避免每個候選重建整張詞頻表。
        struct Key: Hashable { let language: String; let reading: String }
        var counts: [Key: [String: Int]] = [:]
        var preferences: [Key: [String: Int]] = [:]
        return units.map { unit in
            let key = Key(language: unit.languageID, reading: unit.readingOrToken)
            if counts[key] == nil {
                counts[key] = UserFrequencyStore.frequencyMap(languageID: key.language, reading: key.reading)
                preferences[key] = key.language == "zh-Hant"
                    ? Dictionary(PersonalVocabularyStore.entries(reading: key.reading).map { ($0.surface, $0.priority) },
                        uniquingKeysWith: { _, new in new }) : [:]
            }
            return score(unit: unit, count: counts[key]?[unit.surface] ?? 0,
                preference: Double(preferences[key]?[unit.surface] ?? 0))
        }
    }

    private func score(unit: CandidateUnit, count: Int, preference: Double) -> Double {
        // 名次只作有界先驗；候選清單變長不能抵銷全部個人偏好。
        let rankPenalty = min(log2(Double(max(0, unit.baseRank)) + 1.0) * 40.0, 240.0)
        let usageBonus = count > 0 ? min(log2(Double(count) + 1.0) * 40.0, 400.0) : 0.0
        // 語料證據按涵蓋字數計入，避免每多切一個詞就多領固定獎勵。
        // 同音排序只在此計分，呼叫端不得再加使用紀錄或個人偏好。
        let weight = Self.phraseStats.readingSurfaceWeights[unit.readingOrToken]?[unit.surface] ?? 0
        let corpusBonus = unit.languageID == "zh-Hant" && unit.surface.count == unit.spanLength
            && unit.spanLength > 1 && weight.isFinite && weight > 0
            ? min(log10(weight + 1.0) * 120.0, 500.0) * Double(unit.spanLength) : 0.0
        let calibration = unit.languageID == "zh-Hant" && unit.surface.count == unit.spanLength
            ? Self.spanCalibration[unit.readingOrToken]?[unit.spanLength] ?? 0 : 0
        return corpusBonus + calibration + usageBonus + preference - rankPenalty
    }
}
