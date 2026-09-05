import Foundation

struct UnifiedRankerSegmentSample: Codable, Equatable {
    let sampleID: String
    let caseID: String
    let stepID: Int
    let source: String
    let tags: [String]
    let languageID: String
    let allTokens: [String]
    let combinedToken: String
    let focusedToken: String
    let precedingValues: [String]
    let followingTokens: [String]
    let candidateSurface: String
    let candidateReadingOrToken: String
    let spanStart: Int
    let spanLength: Int
    let providerScore: Double
    let baseRank: Int
    let label: Double
    let sampleWeight: Double

    enum CodingKeys: String, CodingKey {
        case sampleID = "sample_id"
        case caseID = "case_id"
        case stepID = "step_id"
        case source
        case tags
        case languageID = "language_id"
        case allTokens = "all_tokens"
        case combinedToken = "combined_token"
        case focusedToken = "focused_token"
        case precedingValues = "preceding_values"
        case followingTokens = "following_tokens"
        case candidateSurface = "candidate_surface"
        case candidateReadingOrToken = "candidate_reading_or_token"
        case spanStart = "span_start"
        case spanLength = "span_length"
        case providerScore = "provider_score"
        case baseRank = "base_rank"
        case label
        case sampleWeight = "sample_weight"
    }
}

struct SentenceCandidatePath: Codable, Equatable {
    let text: String
    let readings: [String]
    let segments: [ComposedSegment]
    let localScore: Double
    let metadata: [String: Double]?

    init(
        text: String,
        readings: [String],
        segments: [ComposedSegment],
        localScore: Double,
        metadata: [String: Double]? = nil
    ) {
        self.text = text
        self.readings = readings
        self.segments = segments
        self.localScore = localScore
        self.metadata = metadata
    }
}

struct SentenceRerankerContext: Codable, Equatable {
    let committedLeftContext: [String]
    let committedRightContext: [String]

    init(committedLeftContext: [String] = [], committedRightContext: [String] = []) {
        self.committedLeftContext = committedLeftContext
        self.committedRightContext = committedRightContext
    }
}

struct SentenceRerankerExample: Codable, Equatable {
    let groupID: String
    let readings: [String]
    let goldText: String?
    let candidates: [SentenceCandidatePath]
    let context: SentenceRerankerContext?
    let segmentSamples: [UnifiedRankerSegmentSample]?

    enum CodingKeys: String, CodingKey {
        case groupID = "group_id"
        case readings
        case goldText = "gold_text"
        case candidates
        case context
        case segmentSamples = "segment_samples"
    }
}

struct SentenceRerankerScore: Codable, Equatable {
    let text: String
    let localScore: Double
    let sentenceScore: Double
    let finalScore: Double
}
