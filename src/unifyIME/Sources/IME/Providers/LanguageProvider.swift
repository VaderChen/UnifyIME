import Foundation

protocol LanguageProvider {
    var languageID: String { get }

    func resolveCandidates(for token: String) -> [String]
    func resolveComposition(tokens: [InputToken]) -> [ComposedSegment]
    func buildReverseLexicon() -> [String: [String]]
    func isDisplayableCandidate(_ candidate: String) -> Bool
    func prewarm()
}
