import AppKit
import InputMethodKit

/// 切換模式時在插入點附近短暫提示，不取得鍵盤或滑鼠焦點。
final class InputLanguageCaretIndicator {
    static let shared = InputLanguageCaretIndicator()
    static let notification = Notification.Name("com.vader.unifyime.caretMode")
    private var pending = false
    private lazy var panel: NSPanel = makePanel()
    private let icon = NSImageView(frame: NSRect(x: 4, y: 4, width: 24, height: 24))
    private var dismissal: DispatchWorkItem?
    private var requestID = UUID()

    private init() {}

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView?.addSubview(icon)
        return panel
    }

    func show(client: Any?, english: Bool) {
        hide()
        guard let client = client as? IMKTextInput else { return }
        pending = true
        let request = requestID
        // 組字送出後，客戶端可能到下一輪事件才更新插入點。
        DispatchQueue.main.async { [weak self] in
            self?.present(client: client, english: english, request: request, attempt: 0)
        }
    }

    private func caretRect(client: IMKTextInput) -> NSRect? {
        let selected = client.selectedRange()
        let index = selected.location == NSNotFound ? 0 : selected.location
        var rect = NSRect.zero
        if let textClient = client as? NSTextInputClient {
            var actual = NSRange(location: NSNotFound, length: 0)
            rect = textClient.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: &actual)
            if valid(rect) { return rect }
        }
        // 不同客戶端可能只提供目前插入點（索引 0）的行高矩形。
        var indices = [index]
        if index > 0 { indices.append(index - 1) }
        if index != 0 { indices.append(0) }
        for query in indices {
            rect = .zero
            client.attributes(forCharacterIndex: query, lineHeightRectangle: &rect)
            if valid(rect) { return rect }
        }
        return nil
    }

    private func valid(_ rect: NSRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite &&
        rect.width.isFinite && rect.height.isFinite && rect.height > 0 && rect.width >= 0
    }

    private func present(client: IMKTextInput, english: Bool, request: UUID, attempt: Int) {
        guard requestID == request else { return }
        guard let rect = caretRect(client: client) else {
            if attempt < 3 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.present(client: client, english: english, request: request, attempt: attempt + 1)
                }
            }
            return
        }
        DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil,
            userInfo: ["rect": NSStringFromRect(rect), "english": english], deliverImmediately: true)
    }

    /// 僅由既有選字窗輔助程序呼叫，不在 IMK 主程序建立視窗。
    func receive(_ notification: Notification) {
        dismissal?.cancel()
        guard let encoded = notification.userInfo?["rect"] as? String,
              let english = notification.userInfo?["english"] as? Bool else {
            panel.orderOut(nil)
            return
        }
        let rect = NSRectFromString(encoded)
        guard valid(rect) else { return }
        // 插入點通常沒有寬度；僅為螢幕交集判斷補上 1 點寬度。
        let hitRect = NSRect(x: rect.minX, y: rect.minY, width: max(1, rect.width), height: rect.height)
        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(hitRect) }) else { return }
        guard let url = Bundle.main.url(forResource: english ? "English" : "Bopomofo", withExtension: "tiff"),
              let image = NSImage(contentsOf: url) else { return }
        icon.image = image
        let visible = screen.visibleFrame
        let x = min(max(rect.maxX + 5, visible.minX), visible.maxX - 32)
        let below = rect.minY - 36
        let y = min(max(below >= visible.minY ? below : rect.maxY + 4, visible.minY), visible.maxY - 32)
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.orderFrontRegardless()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        dismissal = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func hide() {
        requestID = UUID()
        guard pending else { return }
        pending = false
        DistributedNotificationCenter.default().postNotificationName(Self.notification, object: nil,
            userInfo: nil, deliverImmediately: true)
    }
}
