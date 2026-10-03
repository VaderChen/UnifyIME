import Foundation

struct MixedInputBoundaryResolution {
    let englishCommit: String?
    let primaryToken: String?
}

enum MixedInputBoundaryResolver {
    private static var englishBehavior: CompositionLanguageBehavior? {
        CompositionLanguageRegistry.targets.first { $0.id == "english-ime" }?.behavior
    }

    static func isASCIIAlpha(_ token: String) -> Bool {
        guard !token.isEmpty, token.index(after: token.startIndex) == token.endIndex,
              let scalar = token.unicodeScalars.first else { return false }
        return scalar.isASCII && CharacterSet.letters.contains(scalar)
    }

    static func resolve(run: String, boundary: String) -> MixedInputBoundaryResolution? {
        guard !run.isEmpty else { return nil }

        let exactRun = isExactEnglishWord(run)
        if isExplicitEnglishBoundary(boundary), exactRun {
            return MixedInputBoundaryResolution(englishCommit: run, primaryToken: nil)
        }

        var split = run.endIndex
        while true {
            // 按字元邊界向前走，保留 Unicode 行為，且只為合格前綴建立後綴。
            let englishPart = String(run[..<split])
            let englishOK = englishPart.isEmpty || (split == run.endIndex ? exactRun : isExactEnglishWord(englishPart))
            if englishOK {
                let primaryPart = String(run[split...]) + boundary
                if primaryMaterializes(token: primaryPart) {
                    return MixedInputBoundaryResolution(englishCommit: englishPart.isEmpty ? nil : englishPart,
                        primaryToken: primaryPart)
                }
            }
            guard split > run.startIndex else { break }
            split = run.index(before: split)
        }

        if exactRun {
            return MixedInputBoundaryResolution(englishCommit: run, primaryToken: nil)
        }

        return nil
    }

    static func isExactEnglishWord(_ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        if EnglishIMEEngine.isExactWord(word) {
            return true
        }
        guard let englishBehavior else { return false }
        let lowered = word.lowercased()
        return englishBehavior.resolveCandidates(for: lowered).contains {
            $0.caseInsensitiveCompare(lowered) == .orderedSame
        }
    }

    static func primaryMaterializes(token: String) -> Bool {
        guard !token.isEmpty else { return false }
        var state = UnifiedCompositionState()
        CompositionLanguageRegistry.primary.feed(token: token, state: &state)
        if state.hasComposition { return true }
        let prediction = CompositionLanguageRegistry.primary.predict(state)
        return !prediction.presentation.markedText.isEmpty
            || !prediction.presentation.displayedSegments.isEmpty
            || !prediction.presentation.candidateEntries.isEmpty
    }

    private static func isExplicitEnglishBoundary(_ token: String) -> Bool {
        switch token {
        case "<space>", "<enter>", ".", ",", "!", "?":
            return true
        default:
            return false
        }
    }
}
