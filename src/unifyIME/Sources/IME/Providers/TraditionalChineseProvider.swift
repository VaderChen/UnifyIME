import Foundation

struct TraditionalChineseProvider: LanguageProvider {
    let languageID = "zh-Hant"

    let lexicon: LexiconStore
    let readingWalker: ReadingWalker

    init(overrideCharacterMap: [String: [String]], ranker: UnifiedCandidateRanker) {
        let lexicon = LexiconStore(overrideCharacterMap: overrideCharacterMap)
        self.lexicon = lexicon
        readingWalker = ReadingWalker(lexicon: lexicon, ranker: ranker, languageID: languageID)
    }

    func resolveCandidates(for token: String) -> [String] {
        lexicon.resolveCandidates(for: token)
    }

    func resolveComposition(tokens: [InputToken]) -> [ComposedSegment] {
        readingWalker.resolveWalk(tokens)
    }

    func buildReverseLexicon() -> [String: [String]] {
        var reverse: [String: [String]] = [:]
        func add(_ text: String, reading: String) {
            guard !text.isEmpty, !reading.isEmpty else { return }
            var list = reverse[text, default: []]
            if !list.contains(reading) {
                list.append(reading)
            }
            reverse[text] = list
        }
        for reading in lexicon.phraseCandidateMap.keys.sorted() {
            let phrases = lexicon.phraseCandidateMap[reading] ?? []
            for phrase in phrases {
                add(phrase, reading: reading)
            }
        }
        for reading in lexicon.commonCharacterMap.keys.sorted() {
            let values = lexicon.commonCharacterMap[reading] ?? []
            for value in values {
                add(value, reading: reading)
            }
        }
        return reverse
    }

    func isDisplayableCandidate(_ candidate: String) -> Bool {
        LexiconStore.isDisplayableCandidate(candidate)
    }

    func prewarm() {
        _ = lexicon.phraseCandidateMap.count
        _ = lexicon.commonCharacterMap.count
        _ = lexicon.readingPrefixes.count
    }
}
