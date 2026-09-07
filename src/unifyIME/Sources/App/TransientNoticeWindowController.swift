import AppKit

final class TransientNoticeWindowController: NSWindowController {
    static let shared = TransientNoticeWindowController()

    private let titleLabel = NSTextField(labelWithString: "全一輸入法")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton(title: "知道了", target: nil, action: nil)
    private var hideWorkItem: DispatchWorkItem?

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 420, height: 176)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "全一輸入法"
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let content = NSView(frame: rect)
        window.contentView = content

        titleLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        titleLabel.frame = NSRect(x: 20, y: 120, width: 380, height: 24)
        content.addSubview(titleLabel)

        bodyLabel.font = .systemFont(ofSize: 14, weight: .regular)
        bodyLabel.alignment = .left
        bodyLabel.lineBreakMode = .byWordWrapping
        bodyLabel.maximumNumberOfLines = 4
        bodyLabel.frame = NSRect(x: 20, y: 54, width: 380, height: 60)
        content.addSubview(bodyLabel)

        closeButton.frame = NSRect(x: 300, y: 16, width: 100, height: 28)
        content.addSubview(closeButton)

        super.init(window: window)
        closeButton.target = self
        closeButton.action = #selector(handleClose(_:))
        window.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    private func handleClose(_ sender: Any?) {
        hideWorkItem?.cancel()
        window?.orderOut(nil)
    }

    func show(title: String = "全一輸入法", message: String, duration: TimeInterval? = nil) {
        guard let window else { return }
        hideWorkItem?.cancel()
        titleLabel.stringValue = title
        bodyLabel.stringValue = message
        if let screen = NSScreen.main?.visibleFrame {
            let origin = NSPoint(
                x: screen.midX - window.frame.width / 2,
                y: screen.midY - window.frame.height / 2
            )
            window.setFrameOrigin(origin)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        if let duration {
            let workItem = DispatchWorkItem { [weak self] in
                self?.window?.orderOut(nil)
            }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: workItem)
        }
    }
}
