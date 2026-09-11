import Foundation

/// 以按下／放開的狀態轉換辨識單按 Shift；重複通知不取消手勢。
struct ShiftLanguageGesture {
    private var shiftDown = false
    private var pending = false
    private var pressedKey: UInt16?
    mutating func reset() { shiftDown = false; pending = false; pressedKey = nil }
    mutating func keyDown() { pending = false }
    mutating func flagsChanged(keyCode: UInt16, shift: Bool, otherModifiers: Bool) -> Bool {
        let isShiftKey = keyCode == 56 || keyCode == 60
        if otherModifiers || !isShiftKey {
            pending = false
        }
        if shift == shiftDown {
            // 同一按鍵重複通知可忽略；另一側 Shift 介入則取消單按。
            if shift && pressedKey != keyCode { pending = false }
            return false
        }
        shiftDown = shift
        if shift {
            pressedKey = keyCode
            pending = isShiftKey && !otherModifiers
            return false
        }
        let toggle = pending && isShiftKey && pressedKey == keyCode && !otherModifiers
        pending = false
        pressedKey = nil
        return toggle
    }
}
