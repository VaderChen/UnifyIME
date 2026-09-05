import AppKit
import InputMethodKit

final class CompositionPanelController: NSWindowController {
    static let shared = CompositionPanelController()

    private let contentLabel = NSTextField(labelWithString: "")
    private let bubble: NSVisualEffectView
    private let panelSize = NSSize(width: 560, height: 220)

    private init() {
        let rect = NSRect(origin: .zero, size: panelSize)
        let panel = NSPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = true
        panel.backgroundColor = NSColor.windowBackgroundColor
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true

        let content = NSView(frame: rect)
        panel.contentView = content

        bubble = NSVisualEffectView(frame: rect)
        bubble.material = .windowBackground
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        bubble.layer?.masksToBounds = true
        bubble.layer?.borderWidth = 2
        bubble.layer?.borderColor = NSColor.separatorColor.cgColor
        content.addSubview(bubble)

        contentLabel.font = .monospacedSystemFont(ofSize: 24, weight: .medium)
        contentLabel.alignment = .left
        contentLabel.textColor = .labelColor
        contentLabel.lineBreakMode = .byWordWrapping
        contentLabel.maximumNumberOfLines = 10
        contentLabel.usesSingleLineMode = false
        contentLabel.frame = NSRect(x: 20, y: 20, width: 520, height: 180)
        bubble.addSubview(contentLabel)

        super.init(window: panel)
        panel.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(text: String, candidateEntries: [CandidateEntry] = [], selectedIndex: Int = 0, client: IMKTextInput? = nil) {
        show(text: text, candidates: candidateEntries.map(\.text), selectedIndex: selectedIndex, client: client)
    }

    func show(text: String, candidates: [String] = [], selectedIndex: Int = 0, client: IMKTextInput? = nil) {
        guard let window = window, let screen = NSScreen.main else { return }
        let targetSize = panelSize
        let visibleCandidates = candidates.isEmpty ? ["（目前沒有候選）"] : candidates
        let safeIndex = min(selectedIndex, max(visibleCandidates.count - 1, 0))
        let candidateText = visibleCandidates.enumerated().map {
            let marker = $0.offset == safeIndex ? "›" : " "
            return "\(marker) \($0.offset + 1). \($0.element)"
        }.joined(separator: "\n")
        contentLabel.stringValue = "\(text)\n——\n\(candidateText)"

        resize(to: targetSize)
        let visible = screen.visibleFrame
        let x = visible.maxX - targetSize.width - 24
        let y = visible.maxY - targetSize.height - 24
        window.setFrameOrigin(NSPoint(x: x, y: y))
        window.orderFront(nil)
    }

    private func resize(to size: NSSize) {
        guard let window = window else { return }
        window.setContentSize(size)
        window.contentView?.frame = NSRect(origin: .zero, size: size)
        bubble.frame = NSRect(origin: .zero, size: size)
        contentLabel.frame = NSRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40)
    }

    func hide() {
        window?.orderOut(nil)
    }
}
