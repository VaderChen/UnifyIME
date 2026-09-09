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
            // 原注音候選也在詞庫內，不能拿它證明這是可轉成中文字的音節。
            for (reading, values) in map where values.contains(where: {
                $0.count == 1 && LexiconStore.isDisplayableCandidate($0)
            }) {
                if let ordered = orderedSymbols(reading), ordered == reading {
                    result.insert(base(reading))
                }
            }
        }
        return result
    }()
    // 合法音節的非空符號子集；聲調提前時可逐鍵補齊缺少的音類。
    // 每種音類最多一個符號，因此集合大小有界，不依輸入長度搜尋。
    private static let completableBases: Set<String> = {
        var result = Set<String>()
        for reading in knownBases {
            let symbols = Array(reading)
            for mask in 1..<(1 << symbols.count) {
                result.insert(String(symbols.indices.filter { mask & (1 << $0) != 0 }.map { symbols[$0] }))
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
        guard !current.isEmpty,
              !knownBases.contains(base(current)),
              let ordered = orderedSymbols(current + symbol), ordered != current + symbol else { return nil }
        if knownBases.contains(base(ordered)) { return ordered }
        // 已有聲調但尚不合法，只在仍能補成同一合法音節時保持待完成。
        guard current.contains(where: { groups[3].contains($0) }),
              completableBases.contains(base(ordered)) else { return nil }
        return ordered
    }
}
