import Foundation

struct HeuristicCandidateRanker: UnifiedCandidateRanker {
    private static let phraseStats = LexiconStore.loadPhraseContextStats()

    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double {
        let rankPenalty = Double(unit.baseRank) * 40.0
        let count = UserFrequencyStore.frequency(languageID: unit.languageID,
            reading: unit.readingOrToken, surface: unit.surface)
        let usageBonus = count > 0 ? min(log2(Double(count) + 1.0) * 40.0, 400.0) : 0.0
        let preference = PersonalVocabularyStore.bonus(language: unit.languageID,
            reading: unit.readingOrToken, surface: unit.surface)
        // 語料證據按涵蓋字數計入，避免每多切一個詞就多領固定獎勵。
        // 同音排序只在此計分，呼叫端不得再加使用紀錄或個人偏好。
        let weight = Self.phraseStats.readingSurfaceWeights[unit.readingOrToken]?[unit.surface] ?? 0
        let corpusBonus = unit.languageID == "zh-Hant" && unit.surface.count == unit.spanLength
            && unit.spanLength > 1 && weight.isFinite && weight > 0
            ? min(log10(weight + 1.0) * 120.0, 500.0) * Double(unit.spanLength) : 0.0
        return corpusBonus + usageBonus + preference - rankPenalty
    }
}
