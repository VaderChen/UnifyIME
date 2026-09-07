import Foundation

struct HeuristicSentenceReranker: UnifiedSentenceReranker {
    private let encoder = SentenceFeatureEncoder()

    func score(path: SentenceCandidatePath, context: SentenceRerankerContext) -> Double {
        let f = encoder.encode(path: path, context: context)
        let segmentPenalty = f[1] * -40.0
        let phraseBonus = f[8] * 80.0
        let fallbackPenalty = f[9] * -120.0
        let phraseWeightBonus = f[10] * 200.0
        let adjacencyBonus = f[13] * 150.0
        let boundaryBonus = f[23] * 90.0
        return segmentPenalty + phraseBonus + fallbackPenalty + phraseWeightBonus + adjacencyBonus + boundaryBonus
    }
}
