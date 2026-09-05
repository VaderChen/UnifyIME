import AppKit

final class CandidateCaretOverlayController: NSWindowController {
    static let shared = CandidateCaretOverlayController()

    private let caretView = NSView(frame: NSRect(x: 0, y: 0, width: 3, height: 20))

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 3, height: 20)
        let window = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .statusBar
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false

        caretView.wantsLayer = true
        caretView.layer?.backgroundColor = NSColor.clear.cgColor
        caretView.layer?.cornerRadius = 1.5
        window.contentView = caretView

        super.init(window: window)
        window.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(anchor: CGPoint) {
        _ = anchor
        hide()
    }

    func hide() {
        window?.orderOut(nil)
    }
}

final class BasicCandidatePanelController: NSWindowController {
    static let shared = BasicCandidatePanelController()

    private final class CandidateListView: NSView {
        var rowStartIndex = 0
        var candidates: [String] = []
        var selectedIndex = 0
        var lineHeight: CGFloat = 18
        var horizontalPadding: CGFloat = 8
        var verticalPadding: CGFloat = 10
        var numberColumnWidth: CGFloat = 20
        var separatorX: CGFloat = 31
        var arrowColumnLeading: CGFloat = 39
        var arrowColumnWidth: CGFloat = 18
        var contentColumnLeading: CGFloat = 65

        let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .regular)
        let arrowFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        let contentFont = NSFont.systemFont(ofSize: 16, weight: .regular)

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)

            NSColor.separatorColor.withAlphaComponent(0.3).setFill()
            NSRect(
                x: separatorX,
                y: verticalPadding,
                width: 1,
                height: bounds.height - (verticalPadding * 2)
            ).fill()

            for (offset, value) in candidates.enumerated() {
                let absoluteIndex = rowStartIndex + offset
                let rowY = verticalPadding + (CGFloat(offset) * lineHeight)

                let numberAttrs: [NSAttributedString.Key: Any] = [
                    .font: numberFont,
                    .foregroundColor: NSColor.tertiaryLabelColor
                ]
                let numberText = NSString(string: "\(absoluteIndex + 1)")
                let numberSize = numberText.size(withAttributes: numberAttrs)
                numberText.draw(
                    at: CGPoint(
                        x: horizontalPadding + numberColumnWidth - numberSize.width,
                        y: rowY
                    ),
                    withAttributes: numberAttrs
                )

                if absoluteIndex == selectedIndex {
                    let arrowAttrs: [NSAttributedString.Key: Any] = [
                        .font: arrowFont,
                        .foregroundColor: NSColor.systemRed
                    ]
                    let arrowText = NSString(string: "▶")
                    let arrowSize = arrowText.size(withAttributes: arrowAttrs)
                    arrowText.draw(
                        at: CGPoint(
                            x: arrowColumnLeading + floor((arrowColumnWidth - arrowSize.width) / 2),
                            y: rowY
                        ),
                        withAttributes: arrowAttrs
                    )
                }

                let contentAttrs: [NSAttributedString.Key: Any] = [
                    .font: contentFont,
                    .foregroundColor: NSColor.labelColor
                ]
                NSString(string: value).draw(
                    at: CGPoint(x: contentColumnLeading, y: rowY),
                    withAttributes: contentAttrs
                )
            }
        }
    }

    private let listView = CandidateListView(frame: .zero)
    private let bubble: NSVisualEffectView
    private var pinnedTopLeft: NSPoint?
    private let maxVisibleRows = 7

    private init() {
        let rect = NSRect(x: 0, y: 0, width: 168, height: 240)
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
        bubble.layer?.borderWidth = 0
        bubble.layer?.borderColor = NSColor.clear.cgColor
        content.addSubview(bubble)

        listView.wantsLayer = true
        listView.layer?.backgroundColor = NSColor.clear.cgColor
        bubble.addSubview(listView)

        super.init(window: panel)
        panel.orderOut(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepare() {
        _ = window
        bubble.layoutSubtreeIfNeeded()
        listView.layoutSubtreeIfNeeded()
    }

    func prewarm() {
        prepare()
        let originalPinnedTopLeft = pinnedTopLeft
        show(anchor: CGPoint(x: 160, y: 160), candidates: ["預熱", "候選"], selectedIndex: 0)
        hide()
        pinnedTopLeft = originalPinnedTopLeft
    }

    func show(anchor: CGPoint?, candidates: [String], selectedIndex: Int) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.show(anchor: anchor, candidates: candidates, selectedIndex: selectedIndex)
            }
            return
        }
        guard let window, !candidates.isEmpty else { return }
        let safeIndex = max(0, min(selectedIndex, candidates.count - 1))
        let visibleCount = min(maxVisibleRows, candidates.count)
        let startIndex = min(max(0, safeIndex - visibleCount / 2), max(0, candidates.count - visibleCount))
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 10
        let numberColumnWidth: CGFloat = 20
        let arrowColumnWidth: CGFloat = 18
        let separatorX = horizontalPadding + numberColumnWidth + 3
        let arrowColumnLeading: CGFloat = separatorX + 8
        let textGap: CGFloat = 8
        let contentColumnLeading: CGFloat = arrowColumnLeading + arrowColumnWidth + textGap
        let visibleCandidates = Array(candidates[startIndex..<(startIndex + visibleCount)])
        let font = listView.contentFont
        let valueAttrs: [NSAttributedString.Key: Any] = [.font: font]
        let valueWidest = visibleCandidates
            .map { ceil(($0 as NSString).size(withAttributes: valueAttrs).width) }
            .max() ?? 80
        let lineHeight = ceil(font.ascender - font.descender) + 1
        let height = CGFloat(max(visibleCount, 4)) * lineHeight + (verticalPadding * 2) + 2
        let width = min(max(contentColumnLeading + valueWidest + horizontalPadding + 2, 110), 172)
        window.setContentSize(NSSize(width: width, height: height))
        window.contentView?.frame = NSRect(x: 0, y: 0, width: width, height: height)
        bubble.frame = NSRect(x: 0, y: 0, width: width, height: height)
        listView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        listView.rowStartIndex = startIndex
        listView.candidates = visibleCandidates
        listView.selectedIndex = safeIndex
        listView.lineHeight = lineHeight
        listView.horizontalPadding = horizontalPadding
        listView.verticalPadding = verticalPadding
        listView.numberColumnWidth = numberColumnWidth
        listView.separatorX = separatorX
        listView.arrowColumnLeading = arrowColumnLeading
        listView.arrowColumnWidth = arrowColumnWidth
        listView.contentColumnLeading = contentColumnLeading

        if let anchor, let screen = screenVisibleFrame(containing: anchor) {
            var topLeftX = anchor.x - (width * 0.42)
            var topLeftY = anchor.y - helperCandidatePanelYOffset
            if topLeftX + width > screen.maxX {
                topLeftX = screen.maxX - width - 8
            }
            if topLeftX < screen.minX {
                topLeftX = screen.minX + 8
            }
            if topLeftY - height < screen.minY + 8 {
                let flippedTopLeftY = anchor.y + height + helperCaretHeight + helperCandidateFlipGap
                topLeftY = min(screen.maxY - 8, flippedTopLeftY)
            }
            if topLeftY > screen.maxY - 8 {
                topLeftY = screen.maxY - 8
            }
            pinnedTopLeft = NSPoint(x: topLeftX, y: topLeftY)
        } else if pinnedTopLeft == nil {
            if let screen = screenVisibleFrame(containing: lastKnownCandidateAnchor) {
                pinnedTopLeft = NSPoint(x: screen.maxX - width - 24, y: screen.maxY - 24)
            }
        }
        if let pinnedTopLeft {
            window.setFrameTopLeftPoint(pinnedTopLeft)
        }
        bubble.needsDisplay = true
        listView.needsDisplay = true
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.needsDisplay = true
        window.displayIfNeeded()
        window.orderFrontRegardless()
    }

    func show(anchor: CGPoint?, candidateEntries: [CandidateEntry], selectedIndex: Int) {
        show(anchor: anchor, candidates: candidateEntries.map(\.text), selectedIndex: selectedIndex)
    }

    func hide() {
        pinnedTopLeft = nil
        window?.orderOut(nil)
    }
}
