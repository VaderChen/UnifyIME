import Foundation
import Carbon

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

enum CompositionConfirmation: String, Codable {
    case inferred
    case preview
    case confirmed
}

/// 原始按鍵字元座標；與音節索引、Cocoa UTF-16 座標分開。
struct CompositionInputSpan: Codable, Equatable {
    let start: Int
    let end: Int
    let input: String
}

struct ComposedSegment: Codable, Equatable {
    let languageID: String
    let reading: String
    let value: String
    let start: Int
    let length: Int
    let rawLength: Int
    var inputSpan: CompositionInputSpan? = nil
    var confirmation: CompositionConfirmation = .inferred

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
    // 跨語言更正可能改變音節數；原範圍與替換後讀音分開保存。
    var replacementReadings: [String]? = nil
    var sourceRawInput: String? = nil
    var inputSpan: CompositionInputSpan? = nil
}

/// 候選身分只描述選取效果；來源標記的補齊不應製造重複候選。
struct CandidateIdentity: Hashable {
    let text: String
    let languageID: String
    let replacementKey: CompositionSegmentKey
    let replacementReadings: [String]?
}

extension CandidateEntry {
    var identity: CandidateIdentity {
        CandidateIdentity(text: text, languageID: languageID, replacementKey: replacementKey,
            replacementReadings: replacementReadings)
    }
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

// CLI 的數字鍵盤動作只接受實體 Numeric Keypad 上的可列印按鍵。
// 鍵碼使用 Carbon 定義，與主鍵盤的注音鍵碼區分。
enum NumericKeypadInput {
    static let keyCodes: [String: UInt16] = [
        "0": UInt16(kVK_ANSI_Keypad0), "1": UInt16(kVK_ANSI_Keypad1),
        "2": UInt16(kVK_ANSI_Keypad2), "3": UInt16(kVK_ANSI_Keypad3),
        "4": UInt16(kVK_ANSI_Keypad4), "5": UInt16(kVK_ANSI_Keypad5),
        "6": UInt16(kVK_ANSI_Keypad6), "7": UInt16(kVK_ANSI_Keypad7),
        "8": UInt16(kVK_ANSI_Keypad8), "9": UInt16(kVK_ANSI_Keypad9),
        ".": UInt16(kVK_ANSI_KeypadDecimal), "*": UInt16(kVK_ANSI_KeypadMultiply),
        "+": UInt16(kVK_ANSI_KeypadPlus), "/": UInt16(kVK_ANSI_KeypadDivide),
        "-": UInt16(kVK_ANSI_KeypadMinus), "=": UInt16(kVK_ANSI_KeypadEquals)
    ]
    static let allowedCharacters = CharacterSet(charactersIn: keyCodes.keys.joined())
    static func text(for keyCode: UInt16) -> String? {
        keyCodes.first { $0.value == keyCode }?.key
    }
}

/// 僅依標準 Delete／Backspace 鍵碼判斷，不提供字元碼別名。
enum CompositionDeletionKey {
    case backward
    case forward

    static func resolve(keyCode: UInt16) -> Self? {
        switch Int(keyCode) {
        case kVK_Delete: return .backward // Backspace
        case kVK_ForwardDelete: return .forward // Delete
        default: return nil
        }
    }
}
