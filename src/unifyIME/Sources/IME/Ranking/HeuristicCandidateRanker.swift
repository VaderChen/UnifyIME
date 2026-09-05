import Foundation

struct HeuristicCandidateRanker: UnifiedCandidateRanker {
    func score(unit: CandidateUnit, context: CandidateSelectionContext) -> Double {
        let script = RankingFeatureEncoder().encode(unit: unit, context: context).values
        let rankPenalty = Double(unit.baseRank * 40)
        let spanBonus = Double(context.spanLength * 1000)
        let phraseBonus = unit.surface.count > 1 ? 120.0 : 0.0
        let exactReadingPenalty = unit.surface == context.combinedToken ? 200.0 : 0.0
        let contextBonus = context.precedingValues.isEmpty ? 0.0 : min(Double(unit.surface.count - 1) * 25.0, 75.0)
        let languageBias = unit.languageID == "zh-Hant" ? 20.0 : 0.0
        let hanBias = script[15] > 0.5 ? 10.0 : 0.0
        return spanBonus + phraseBonus + contextBonus + languageBias + hanBias - rankPenalty - exactReadingPenalty
    }
}
