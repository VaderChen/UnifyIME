import Foundation

protocol UnifiedSentenceReranker {
    func score(path: SentenceCandidatePath, context: SentenceRerankerContext) -> Double
}
