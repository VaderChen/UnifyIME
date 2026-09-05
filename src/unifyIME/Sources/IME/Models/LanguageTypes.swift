import Foundation

struct InputToken: Equatable {
    let languageID: String
    let rawValue: String
}

struct CandidateUnit: Equatable {
    let languageID: String
    let surface: String
    let readingOrToken: String
    let spanStart: Int
    let spanLength: Int
    let providerScore: Double
    let baseRank: Int
}

struct ComposedSegment: Codable, Equatable {
    let languageID: String
    let reading: String
    let value: String
    let start: Int
    let length: Int
    let rawLength: Int

    init(
        languageID: String,
        reading: String,
        value: String,
        start: Int,
        length: Int,
        rawLength: Int? = nil
    ) {
        self.languageID = languageID
        self.reading = reading
        self.value = value
        self.start = start
        self.length = length
        self.rawLength = rawLength ?? length
    }
}

struct CandidateEntry: Equatable {
    let text: String
    let languageID: String
    let replacementKey: CompositionSegmentKey
}

struct CandidateSelectionContext {
    let languageID: String
    let allTokens: [InputToken]
    let combinedToken: String
    let spanLength: Int
    let precedingValues: [String]
    let followingTokens: [InputToken]
    let focusedToken: String
}

struct RankedCandidate: Equatable {
    let unit: CandidateUnit
    let score: Double
}

struct RawSpanCoverage: Equatable {
    let targetID: String
    let start: Int
    let end: Int
    let text: String
    let score: Double
}

struct RawSpanMergeResult: Equatable {
    let coverages: [RawSpanCoverage]
    let mergedText: String
    let coveredRawLength: Int
    let fullCoverage: Bool
}

enum CandidateScriptClass: Int, Equatable {
    case han = 0
    case latin = 1
    case kana = 2
    case mixed = 3
    case other = 4
}

struct RankingFeatureVector: Equatable {
    static let expectedDimension = 88

    let values: [Double]

    init(values: [Double]) {
        precondition(values.count == Self.expectedDimension)
        self.values = values
    }
}
