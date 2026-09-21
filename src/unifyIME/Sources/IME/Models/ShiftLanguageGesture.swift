import Foundation

/// 以按下／放開的狀態轉換辨識單按修飾鍵；重複通知不取消手勢。
struct ShiftLanguageGesture {
    private var modifierDown = false
    private var trackedKeyCodes: [UInt16] = []
    private var pending = false
    private var pressedKey: UInt16?
    mutating func reset() { modifierDown = false; pending = false; pressedKey = nil }
    mutating func keyDown() { pending = false }
    mutating func flagsChanged(keyCode: UInt16, modifierActive: Bool, otherModifiers: Bool, keyCodes: [UInt16]) -> Bool {
        if trackedKeyCodes != keyCodes { reset(); trackedKeyCodes = keyCodes }
        let isModifierKey = keyCodes.contains(keyCode)
        if otherModifiers || !isModifierKey {
            pending = false
        }
        if modifierActive == modifierDown {
            // 同一按鍵重複通知可忽略；另一側修飾鍵介入則取消單按。
            if modifierActive && pressedKey != keyCode { pending = false }
            return false
        }
        modifierDown = modifierActive
        if modifierActive {
            pressedKey = keyCode
            pending = isModifierKey && !otherModifiers
            return false
        }
        let toggle = pending && isModifierKey && pressedKey == keyCode && !otherModifiers
        pending = false
        pressedKey = nil
        return toggle
    }
}
