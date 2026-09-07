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
        guard token.count == 1, let scalar = token.unicodeScalars.first else { return false }
        return scalar.isASCII && CharacterSet.letters.contains(scalar)
    }

    static func resolve(run: String, boundary: String) -> MixedInputBoundaryResolution? {
        guard !run.isEmpty else { return nil }

        if isExplicitEnglishBoundary(boundary), isExactEnglishWord(run) {
            return MixedInputBoundaryResolution(englishCommit: run, primaryToken: nil)
        }

        let chars = Array(run)
        for split in stride(from: chars.count, through: 0, by: -1) {
            let englishPart = String(chars.prefix(split))
            let primaryPart = String(chars.dropFirst(split)) + boundary
            let englishOK = englishPart.isEmpty || isExactEnglishWord(englishPart)
            guard englishOK else { continue }
            guard primaryMaterializes(token: primaryPart) else { continue }
            return MixedInputBoundaryResolution(
                englishCommit: englishPart.isEmpty ? nil : englishPart,
                primaryToken: primaryPart
            )
        }

        if isExactEnglishWord(run) {
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
        let prediction = CompositionLanguageRegistry.primary.predict(state)
        return !prediction.presentation.markedText.isEmpty
            || !prediction.presentation.displayedSegments.isEmpty
            || !prediction.presentation.candidateEntries.isEmpty
            || state.hasComposition
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
