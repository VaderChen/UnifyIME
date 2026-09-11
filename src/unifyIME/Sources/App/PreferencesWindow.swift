import AppKit

/// 輸入法常處於背景；關閉鈕的首次點擊不應只啟用偏好設定視窗。
final class PreferencesWindow: NSWindow {
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           !NSApp.isActive || !isKeyWindow,
           isVisible, attachedSheet == nil, NSApp.modalWindow == nil,
           let button = standardWindowButton(.closeButton),
           button.isEnabled, !button.isHidden,
           button.bounds.contains(button.convert(event.locationInWindow, from: nil)) {
            // 沿用 AppKit 的 delegate／關閉通知，不直接隱藏或終止輸入法。
            performClose(button)
            return
        }
        super.sendEvent(event)
    }
}
