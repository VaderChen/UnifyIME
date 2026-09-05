import Foundation

enum CompositionLanguageSetting: String {
    case disabled
    case bopomofo
    case english
    case japanese
}

protocol CompositionLanguageBehavior {
    func feed(token: String, state: inout UnifiedCompositionState)
    func predict(_ state: UnifiedCompositionState) -> UnifiedCompositionPrediction
    func resolveCandidates(for reading: String) -> [String]
    func resolveWalk(_ readings: [String]) -> [ComposedSegment]
    func resolveCommittedText(allReadings: [String]) -> String
    func splitReadingIntoSyllables(_ reading: String) -> [String]
    func rankCandidates(
        _ candidates: [String],
        allReadings: [String],
        combinedReading: String,
        spanLength: Int,
        precedingValues: [String],
        followingReadings: [String],
        focusedReading: String
    ) -> [String]
    func buildReverseLexicon() -> [String: [String]]
    func reverseReadings(for sentence: String, reverseMap: [String: [String]]) -> [String]?
    func simulateIncrementalInput(readings: [String]) -> String
    func keySequence(for readings: [String]) -> String
}

struct CompositionLanguageTarget {
    let id: String
    let behavior: CompositionLanguageBehavior
}

enum CompositionLanguageRegistry {
    private static let bopomofoChinese = BopomofoChineseBehavior()
    private static let english = EnglishIMEEngine()
    private static let defaults = UserDefaults(suiteName: Bundle.main.bundleIdentifier ?? "com.vader.inputmethod.UnifyIME") ?? .standard

    private static let allTargets: [CompositionLanguageTarget] = [
        CompositionLanguageTarget(id: "bopomofo-zh-hant", behavior: bopomofoChinese),
        CompositionLanguageTarget(id: "english-ime", behavior: english)
    ]

    private static func languageSetting(for key: String, fallback: CompositionLanguageSetting) -> CompositionLanguageSetting {
        let raw = defaults.string(forKey: key)
        return CompositionLanguageSetting(rawValue: raw ?? "") ?? fallback
    }

    static var targets: [CompositionLanguageTarget] {
        var enabled: [CompositionLanguageTarget] = []

        switch languageSetting(for: "UnifyIME.Language.zh", fallback: .bopomofo) {
        case .bopomofo:
            if let target = allTargets.first(where: { $0.id == "bopomofo-zh-hant" }) {
                enabled.append(target)
            }
        case .disabled, .english, .japanese:
            break
        }

        switch languageSetting(for: "UnifyIME.Language.en", fallback: .english) {
        case .english:
            if let target = allTargets.first(where: { $0.id == "english-ime" }) {
                enabled.append(target)
            }
        case .disabled, .bopomofo, .japanese:
            break
        }

        return enabled.isEmpty ? [allTargets[0]] : enabled
    }

    static var primary: CompositionLanguageBehavior {
        targets[0].behavior
    }
}

struct BopomofoChineseBehavior: CompositionLanguageBehavior {
    func feed(token: String, state: inout UnifiedCompositionState) {
        PhoneticIMECore.feed(token: token, state: &state)
    }

    func predict(_ state: UnifiedCompositionState) -> UnifiedCompositionPrediction {
        PhoneticIMECore.predict(state)
    }

    func resolveCandidates(for reading: String) -> [String] {
        SessionCtl.resolveCandidates(for: reading)
    }

    func resolveWalk(_ readings: [String]) -> [ComposedSegment] {
        SessionCtl.resolveWalk(readings)
    }

    func resolveCommittedText(allReadings: [String]) -> String {
        SessionCtl.resolveCommittedText(allReadings: allReadings)
    }

    func splitReadingIntoSyllables(_ reading: String) -> [String] {
        SessionCtl.splitReadingIntoSyllables(reading)
    }

    func rankCandidates(
        _ candidates: [String],
        allReadings: [String],
        combinedReading: String,
        spanLength: Int,
        precedingValues: [String],
        followingReadings: [String],
        focusedReading: String
    ) -> [String] {
        SessionCtl.rankCandidates(
            candidates,
            allReadings: allReadings,
            combinedReading: combinedReading,
            spanLength: spanLength,
            precedingValues: precedingValues,
            followingReadings: followingReadings,
            focusedReading: focusedReading
        )
    }

    func buildReverseLexicon() -> [String: [String]] {
        SessionCtl.buildReverseLexicon()
    }

    func reverseReadings(for sentence: String, reverseMap: [String: [String]]) -> [String]? {
        SessionCtl.reverseReadings(for: sentence, reverseMap: reverseMap)
    }

    func simulateIncrementalInput(readings: [String]) -> String {
        SessionCtl.simulateIncrementalInput(readings: readings)
    }

    func keySequence(for readings: [String]) -> String {
        SessionCtl.keySequence(for: readings)
    }
}
