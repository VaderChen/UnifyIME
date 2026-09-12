import Foundation

struct HeuristicCandidateRanker: UnifiedCandidateRanker {
    private static let phraseStats = LexiconStore.loadPhraseContextStats()

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
        return corpusBonus + usageBonus + preference - rankPenalty
    }
}
