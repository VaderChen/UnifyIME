import Foundation

/// 標點以單一組字單位保存；顯示形式可替換，來源與位置維持不變。
enum SymbolCandidates {
    static let groups: [[String]] = [
        ["，", "、", ",", "﹐", "﹑"], ["。", "．", ".", "·", "•"],
        ["？", "?", "﹖"], ["！", "!", "﹗"], ["：", ":", "﹕"], ["；", ";", "﹔"],
        ["（", "(", "〔", "【", "〈", "《"], ["）", ")", "〕", "】", "〉", "》"],
        ["「", "『", "“", "‘", "［", "[", "｛", "{"],
        ["」", "』", "”", "’", "］", "]", "｝", "}"],
        ["—", "–", "－", "-", "…", "⋯", "＿", "_"],
        ["＝", "=", "≠", "≈", "≡", "≤", "≥"],
        ["＋", "+", "±", "×", "÷", "／", "/", "％", "%"],
        ["＠", "@", "＃", "#", "＆", "&", "＊", "*", "＄", "$", "￥", "€", "￡"]
    ]

    static func values(for reading: String) -> [String] {
        guard let group = groups.first(where: { $0.contains(reading) }) else { return [] }
        return [reading] + group.filter { $0 != reading }
    }

    // 僅處理列出的標點鍵；字母、數字與其他應用程式快捷鍵不在此表。
    static let shortcutByKeyCode: [UInt16: String] = [
        43: "，", 47: "。", 44: "？", 41: "；", 39: "、", 42: "、",
        33: "「", 30: "」"
    ]

    static func insert(_ symbol: String, state: inout UnifiedCompositionState) {
        guard !values(for: symbol).isEmpty else { return }
        UnifiedCompositionEngine.finalizePendingReadingForCommit(state: &state)
        let index = state.currentCompositionCursorIndex()
        state.readings = state.allReadings
        state.trailingReadings = []
        state.rebaseOverrides(replacing: index..<index, insertedCount: 1, insertedRawInputs: [symbol])
        state.readings.insert(symbol, at: index)
        let key = CompositionSegmentKey(start: index, length: 1, reading: symbol)
        state.segmentOverrides[key] = symbol
        state.explicitLockedKeys.insert(key)
        state.compositionCursorIndex = index + 1
        state.selectedCandidateIndex = 0
        state.rawReadingSymbols = state.readings.joined().map(String.init)
    }
}
