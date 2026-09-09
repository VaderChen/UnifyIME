import Foundation

/// 只重排同一個未完成音節，不增刪注音、不猜聲調，也不跨越合法音節邊界。
enum BopomofoOrderCorrection {
    private static let groups = [
        "ㄅㄆㄇㄈㄉㄊㄋㄌㄍㄎㄏㄐㄑㄒㄓㄔㄕㄖㄗㄘㄙ", "ㄧㄨㄩ",
        "ㄚㄛㄜㄝㄞㄟㄠㄡㄢㄣㄤㄥㄦ", "ˊˇˋ˙"
    ]
    private static let knownBases: Set<String> = {
        let lexicon = SessionCtl.traditionalChineseProvider.lexicon
        var result = Set<String>()
        for map in [lexicon.commonCharacterMap, lexicon.overrideCharacterMap] {
            for (reading, values) in map where values.contains(where: { $0.count == 1 }) {
                if let ordered = orderedSymbols(reading), ordered == reading {
                    result.insert(base(reading))
                }
            }
        }
        return result
    }()
    private static func base(_ reading: String) -> String {
        String(reading.filter { !groups[3].contains($0) })
    }
    private static func orderedSymbols(_ reading: String) -> String? {
        var slots = Array(repeating: "", count: groups.count)
        for symbol in reading {
            guard let index = groups.firstIndex(where: { $0.contains(symbol) }), slots[index].isEmpty else { return nil }
            slots[index] = String(symbol)
        }
        guard !slots.prefix(3).joined().isEmpty else { return nil }
        return slots.joined()
    }
    static func normalize(_ reading: String) -> String? {
        guard let ordered = orderedSymbols(reading), knownBases.contains(base(ordered)) else { return nil }
        return ordered
    }
    static func appending(_ symbol: String, to current: String) -> String? {
        guard !current.isEmpty, !current.contains(where: { groups[3].contains($0) }),
              !knownBases.contains(base(current)),
              let corrected = normalize(current + symbol), corrected != current + symbol else { return nil }
        return corrected
    }
}
