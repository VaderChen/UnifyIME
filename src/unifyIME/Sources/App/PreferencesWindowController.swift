import AppKit

final class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    private enum PreferencesSection: String, CaseIterable {
        case general = "輸入"
        case language = "選擇語言"
        case about = "關於"
#if DEBUG
        case debug = "DEBUG"
#endif
    }

#if DEBUG
    private static let debugMetricLabels = [
        "readingWalker.resolveWalk",
        "mixedMerge.analyze",
        "mixedMerge.cacheHit",
        "mixedMerge.mergeSpanCoverages",
        "mixedMerge.englishSpanScan",
        "unified.mergeSpanCoverages.total",
        "unified.mergeSpanCoverages.spanCoverages",
        "unified.mergeSpanCoverages.dp",
        "session.recomputeRawSpanMerge",
        "session.rankCandidates"
    ]
#endif

    static let shared = PreferencesWindowController()
    private var selectedSection: PreferencesSection = .general
    private var rootView: NSView?
    private var sidebarView: NSView?
    private var dividerView: NSView?
    private var sidebarRows: [PreferencesSection: NSView] = [:]
    private var sidebarLabels: [PreferencesSection: NSTextField] = [:]
    private var contentPanel: NSView?
    private var contentTitleLabel: NSTextField?
    private var contentScrollView: NSScrollView?
    private var contentBodyView: NSView?
    private var engineModePopup: NSPopUpButton?
    private var candidateCursorAlignmentPopup: NSPopUpButton?
    private var pauseRecognitionPopup: NSPopUpButton?
    private var languagePopups: [String: NSPopUpButton] = [:]
#if DEBUG
    private var profilingToggleButton: NSButton?
    private var perCharacterValueLabel: NSTextField?
    private var debugMetricValueLabels: [String: NSTextField] = [:]
    private var debugRefreshTimer: Timer?
#endif
    private let windowInset: CGFloat = 20
    private let sidebarPreferredWidth: CGFloat = 176
    private let dividerGap: CGFloat = 18
    private let titleHeight: CGFloat = 28
    private let titleBottomGap: CGFloat = 8
    private let contentHeaderHeight: CGFloat = 42

    private static func formattedBuildVersionString() -> String {
        let date: Date
        if let executableURL = Bundle.main.executableURL,
           let values = try? executableURL.resourceValues(forKeys: [.contentModificationDateKey]),
           let modified = values.contentModificationDate {
            date = modified
        } else {
            date = Date()
        }
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date) % 100
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let hour = calendar.component(.hour, from: date)
        let minute = calendar.component(.minute, from: date)
        return String(format: "1.%02d.%02d%02d build %02d%02d", year, month, day, hour, minute)
    }

    private init() {
        let contentRect = NSRect(x: 0, y: 0, width: 680, height: 625)
        let window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "全一輸入法偏好設定"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 680, height: 420)
        window.center()

        let rootView = NSView(frame: contentRect)
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rootView.autoresizingMask = [.width, .height]
        self.rootView = rootView

        let sidebar = NSView(frame: .zero)
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        sidebar.layer?.cornerRadius = 12
        rootView.addSubview(sidebar)
        self.sidebarView = sidebar

        let divider = NSView(frame: .zero)
        divider.wantsLayer = true
        divider.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.6).cgColor
        rootView.addSubview(divider)
        self.dividerView = divider

        let contentPanel = NSView(frame: .zero)
        contentPanel.wantsLayer = true
        contentPanel.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        rootView.addSubview(contentPanel)
        self.contentPanel = contentPanel

        let titleLabel = NSTextField(labelWithString: "偏好設定")
        titleLabel.frame = NSRect(x: 0, y: contentPanel.bounds.height - 42, width: contentPanel.bounds.width, height: 28)
        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .labelColor
        contentPanel.addSubview(titleLabel)
        contentTitleLabel = titleLabel

        let scrollView = NSScrollView(frame: .zero)
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.autoresizingMask = [.width, .height]

        let bodyView = NSView(frame: .zero)
        bodyView.wantsLayer = true
        bodyView.layer?.backgroundColor = NSColor.clear.cgColor
        scrollView.documentView = bodyView
        contentPanel.addSubview(scrollView)
        contentScrollView = scrollView
        contentBodyView = bodyView

        var sidebarButtons: [NSButton] = []
        for section in PreferencesSection.allCases {
            let isSelected = section == selectedSection
            let row = NSView(frame: NSRect(x: 10, y: 0, width: 0, height: 28))
            row.wantsLayer = true
            row.layer?.cornerRadius = 8
            row.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            row.identifier = NSUserInterfaceItemIdentifier(section.rawValue)

            let label = NSTextField(labelWithString: section.rawValue)
            label.frame = NSRect(x: 12, y: 4, width: row.bounds.width - 24, height: 20)
            label.font = .systemFont(ofSize: 14, weight: isSelected ? .semibold : .regular)
            label.textColor = isSelected ? .labelColor : .secondaryLabelColor
            row.addSubview(label)
            sidebar.addSubview(row)
            sidebarRows[section] = row
            sidebarLabels[section] = label

            let button = NSButton(frame: row.bounds)
            button.isBordered = false
            button.title = ""
            button.identifier = NSUserInterfaceItemIdentifier(section.rawValue)
            row.addSubview(button)
            sidebarButtons.append(button)
        }

        window.contentView = rootView

        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        for button in sidebarButtons {
            button.target = self
            button.action = #selector(handleSidebarSelection(_:))
        }
        layoutWindowContents()
        rebuildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        showWindow(nil)
        layoutWindowContents()
#if DEBUG
        refreshDebugUIIfNeeded()
#endif
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidResize(_ notification: Notification) {
        layoutWindowContents()
        rebuildContent()
    }

    func windowWillClose(_ notification: Notification) {
#if DEBUG
        stopDebugRefreshTimer()
#endif
    }

    @objc
    private func handleSidebarSelection(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let section = PreferencesSection(rawValue: raw) else { return }
        selectedSection = section
        rebuildSidebarSelection()
        rebuildContent()
    }

    @objc
    private func handleEngineModePopup(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title,
              let mode = CandidateEngineMode.allCases.first(where: { $0.title == title }) else { return }
        currentCandidateEngineMode = mode
        appendRuntimeTrace("preferences.engineMode value=\(mode.rawValue)")
    }

    @objc
    private func handlePauseRecognitionPopup(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title,
              let mode = PauseRecognitionMode.allCases.first(where: { $0.title == title }) else { return }
        currentPauseRecognitionMode = mode
        appendRuntimeTrace("preferences.pauseRecognition value=\(mode.rawValue)")
        showUserNotice(title: "全一輸入法", message: "停頓辨識已切換為\(mode.title)")
    }

    @objc
    private func handleCandidateCursorAlignmentPopup(_ sender: NSPopUpButton) {
        guard let title = sender.selectedItem?.title,
              let mode = CandidateCursorAlignment.allCases.first(where: { $0.title == title }) else { return }
        currentCandidateCursorAlignment = mode
        appendRuntimeTrace("preferences.candidateCursorAlignment value=\(mode.rawValue)")
    }

    @objc
    private func handleLanguagePopup(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue,
              let raw = sender.selectedItem?.representedObject as? String else { return }
        imeDefaults.set(raw, forKey: key)
        imeDefaults.synchronize()
        appendRuntimeTrace("preferences.language key=\(key) value=\(raw)")
    }

#if DEBUG
    @objc
    private func handleProfilingToggle(_ sender: NSButton) {
        isRuntimeProfilingEnabled = (sender.state == .on)
        refreshDebugMetrics()
    }
#endif

    private func rebuildSidebarSelection() {
        for section in PreferencesSection.allCases {
            let isSelected = (section == selectedSection)
            sidebarRows[section]?.layer?.backgroundColor = isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
            sidebarLabels[section]?.font = .systemFont(ofSize: 14, weight: isSelected ? .semibold : .regular)
            sidebarLabels[section]?.textColor = isSelected ? .labelColor : .secondaryLabelColor
        }
    }

    private func rebuildContent() {
        contentTitleLabel?.stringValue = selectedSection.rawValue
        guard let bodyView = contentBodyView else { return }
        let visibleHeight = contentScrollView?.contentView.bounds.height ?? bodyView.bounds.height
        let visibleWidth = contentScrollView?.contentView.bounds.width ?? bodyView.bounds.width
        bodyView.subviews.forEach { $0.removeFromSuperview() }
        bodyView.frame = NSRect(x: 0, y: 0, width: max(320, visibleWidth), height: visibleHeight)
        switch selectedSection {
        case .general:
            bodyView.frame.size.height = buildGeneralPage(in: bodyView, visibleHeight: visibleHeight)
        case .language:
            bodyView.frame.size.height = buildLanguagePage(in: bodyView, visibleHeight: visibleHeight)
        case .about:
            bodyView.frame.size.height = buildAboutPage(in: bodyView, visibleHeight: visibleHeight)
#if DEBUG
        case .debug:
            bodyView.frame.size.height = buildDebugPage(in: bodyView, visibleHeight: visibleHeight)
#endif
        }
#if DEBUG
        refreshDebugUIIfNeeded()
#endif
    }

    private func layoutWindowContents() {
        guard let window,
              let rootView,
              let sidebarView,
              let dividerView,
              let contentPanel,
              let titleLabel = contentTitleLabel,
              let scrollView = contentScrollView
        else { return }

        let bounds = NSRect(origin: .zero, size: window.contentLayoutRect.size)
        rootView.frame = bounds

        let usableHeight = max(240, bounds.height - windowInset * 2)
        let maxSidebarWidth = max(140, min(sidebarPreferredWidth, bounds.width * 0.3))
        let contentMinWidth: CGFloat = 320
        let sidebarWidth = min(maxSidebarWidth, max(140, bounds.width - contentMinWidth - windowInset * 2 - dividerGap * 2 - 1))

        sidebarView.frame = NSRect(x: windowInset, y: windowInset, width: sidebarWidth, height: usableHeight)
        dividerView.frame = NSRect(x: sidebarView.frame.maxX + dividerGap, y: windowInset, width: 1, height: usableHeight)

        let contentX = dividerView.frame.maxX + dividerGap
        contentPanel.frame = NSRect(
            x: contentX,
            y: windowInset,
            width: max(contentMinWidth, bounds.width - contentX - windowInset),
            height: usableHeight
        )

        titleLabel.frame = NSRect(
            x: 0,
            y: contentPanel.bounds.height - titleHeight - titleBottomGap,
            width: contentPanel.bounds.width,
            height: titleHeight
        )
        scrollView.frame = NSRect(
            x: 0,
            y: 0,
            width: contentPanel.bounds.width,
            height: max(120, contentPanel.bounds.height - contentHeaderHeight)
        )
        layoutSidebarRows()
    }

    private func layoutSidebarRows() {
        guard let sidebarView else { return }
        let rowHeight: CGFloat = 28
        let rowGap: CGFloat = 6
        let rowInset: CGFloat = 10
        let topOffset: CGFloat = 36

        for (index, section) in PreferencesSection.allCases.enumerated() {
            guard let row = sidebarRows[section],
                  let label = sidebarLabels[section],
                  let button = row.subviews.compactMap({ $0 as? NSButton }).first
            else { continue }
            let y = sidebarView.bounds.height - topOffset - rowHeight - CGFloat(index) * (rowHeight + rowGap)
            row.frame = NSRect(x: rowInset, y: y, width: sidebarView.bounds.width - rowInset * 2, height: rowHeight)
            label.frame = NSRect(x: 12, y: 4, width: row.bounds.width - 24, height: 20)
            button.frame = row.bounds
        }
    }

#if DEBUG
    private func refreshDebugUIIfNeeded() {
        if selectedSection == .debug {
            profilingToggleButton?.state = isRuntimeProfilingEnabled ? .on : .off
            refreshDebugMetrics()
            startDebugRefreshTimer()
        } else {
            stopDebugRefreshTimer()
        }
    }

    private func startDebugRefreshTimer() {
        guard debugRefreshTimer == nil else { return }
        debugRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshDebugMetrics()
        }
    }

    private func stopDebugRefreshTimer() {
        debugRefreshTimer?.invalidate()
        debugRefreshTimer = nil
    }

    private func refreshDebugMetrics() {
        if let perCharacterValueLabel {
            if let snapshot = runtimePerCharacterSnapshot() {
                perCharacterValueLabel.stringValue = String(format: "全局平均耗時：%.2f ms / 字", snapshot.averageMsPerCharacter)
            } else {
                perCharacterValueLabel.stringValue = isRuntimeProfilingEnabled ? "尚無樣本" : "已停用"
            }
        }
        let snapshots = runtimeProfileSnapshots(labels: Self.debugMetricLabels)
        var snapshotByLabel: [String: RuntimeProfileMetricSnapshot] = [:]
        for snapshot in snapshots {
            snapshotByLabel[snapshot.label] = snapshot
        }
        for label in Self.debugMetricLabels {
            guard let valueLabel = debugMetricValueLabels[label] else { continue }
            if let snapshot = snapshotByLabel[label] {
                valueLabel.stringValue = String(format: "%.3f ms avg (%d samples, last %.3f ms)", snapshot.averageMs, snapshot.sampleCount, snapshot.lastMs)
            } else {
                valueLabel.stringValue = isRuntimeProfilingEnabled ? "尚無樣本" : "已停用"
            }
        }
    }
#endif

    private func buildGeneralPage(in bodyView: NSView, visibleHeight: CGFloat) -> CGFloat {
        let contentHeight = max(visibleHeight, 360)
        let cardHeight: CGFloat = 332
        let topInset: CGFloat = 8
        let card = NSView(frame: NSRect(x: 0, y: contentHeight - (cardHeight + topInset), width: bodyView.bounds.width, height: cardHeight))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 14
        bodyView.addSubview(card)

        let title = NSTextField(labelWithString: "選字引擎")
        let sectionTitleHeight: CGFloat = 22
        let sectionSubtitleHeight: CGFloat = 18
        let popupHeight: CGFloat = 30
        let leadingInset: CGFloat = 20
        let contentWidth = card.bounds.width - 40
        let blockGapAfterPopup: CGFloat = 22
        let titleToSubtitleGap: CGFloat = 24
        let subtitleToPopupGap: CGFloat = 38
        var currentTitleY = card.bounds.height - 38

        title.frame = NSRect(x: leadingInset, y: currentTitleY, width: 240, height: 24)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        card.addSubview(title)

        let subtitle = NSTextField(labelWithString: "控制候選字排序時，AI 與傳統規則的權重分配。")
        subtitle.frame = NSRect(x: leadingInset, y: currentTitleY - titleToSubtitleGap, width: contentWidth, height: sectionSubtitleHeight)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        card.addSubview(subtitle)

        let fullPopupWidth = contentWidth
        let popup = NSPopUpButton(frame: NSRect(x: leadingInset, y: currentTitleY - subtitleToPopupGap - (popupHeight - sectionSubtitleHeight), width: fullPopupWidth, height: popupHeight), pullsDown: false)
        popup.addItems(withTitles: CandidateEngineMode.allCases.map(\.title))
        if let idx = CandidateEngineMode.allCases.firstIndex(of: currentCandidateEngineMode) {
            popup.selectItem(at: idx)
        }
        popup.target = self
        popup.action = #selector(handleEngineModePopup(_:))
        card.addSubview(popup)
        engineModePopup = popup

        let cursorTitle = NSTextField(labelWithString: "選字游標")
        currentTitleY = popup.frame.minY - blockGapAfterPopup - sectionTitleHeight
        cursorTitle.frame = NSRect(x: leadingInset, y: currentTitleY, width: 240, height: sectionTitleHeight)
        cursorTitle.font = .systemFont(ofSize: 15, weight: .medium)
        cursorTitle.textColor = .labelColor
        card.addSubview(cursorTitle)

        let cursorSubtitle = NSTextField(labelWithString: "決定候選焦點以游標左側或右側的字為主。")
        cursorSubtitle.frame = NSRect(x: leadingInset, y: currentTitleY - titleToSubtitleGap, width: contentWidth, height: sectionSubtitleHeight)
        cursorSubtitle.font = .systemFont(ofSize: 12)
        cursorSubtitle.textColor = .secondaryLabelColor
        card.addSubview(cursorSubtitle)

        let cursorPopup = NSPopUpButton(frame: NSRect(x: leadingInset, y: currentTitleY - subtitleToPopupGap - (popupHeight - sectionSubtitleHeight), width: fullPopupWidth, height: popupHeight), pullsDown: false)
        cursorPopup.addItems(withTitles: CandidateCursorAlignment.allCases.map(\.title))
        if let idx = CandidateCursorAlignment.allCases.firstIndex(of: currentCandidateCursorAlignment) {
            cursorPopup.selectItem(at: idx)
        }
        cursorPopup.target = self
        cursorPopup.action = #selector(handleCandidateCursorAlignmentPopup(_:))
        card.addSubview(cursorPopup)
        candidateCursorAlignmentPopup = cursorPopup

        let pauseTitle = NSTextField(labelWithString: "停頓辨識")
        currentTitleY = cursorPopup.frame.minY - blockGapAfterPopup - sectionTitleHeight
        pauseTitle.frame = NSRect(x: leadingInset, y: currentTitleY, width: 240, height: sectionTitleHeight)
        pauseTitle.font = .systemFont(ofSize: 15, weight: .medium)
        pauseTitle.textColor = .labelColor
        card.addSubview(pauseTitle)

        let pauseSubtitle = NSTextField(labelWithString: "連續輸入停下多久後，才整段重播辨識。預設 0.15 秒。")
        pauseSubtitle.frame = NSRect(x: leadingInset, y: currentTitleY - titleToSubtitleGap, width: contentWidth, height: sectionSubtitleHeight)
        pauseSubtitle.font = .systemFont(ofSize: 12)
        pauseSubtitle.textColor = .secondaryLabelColor
        card.addSubview(pauseSubtitle)

        let pausePopup = NSPopUpButton(frame: NSRect(x: leadingInset, y: currentTitleY - subtitleToPopupGap - (popupHeight - sectionSubtitleHeight), width: fullPopupWidth, height: popupHeight), pullsDown: false)
        pausePopup.addItems(withTitles: PauseRecognitionMode.allCases.map(\.title))
        if let idx = PauseRecognitionMode.allCases.firstIndex(of: currentPauseRecognitionMode) {
            pausePopup.selectItem(at: idx)
        }
        pausePopup.target = self
        pausePopup.action = #selector(handlePauseRecognitionPopup(_:))
        card.addSubview(pausePopup)
        pauseRecognitionPopup = pausePopup
        return contentHeight
    }

    private func buildLanguagePage(in bodyView: NSView, visibleHeight: CGFloat) -> CGFloat {
        let contentHeight = max(visibleHeight, 260)
        let cardHeight: CGFloat = 176
        let topInset: CGFloat = 8
        let card = NSView(frame: NSRect(x: 0, y: contentHeight - (cardHeight + topInset), width: bodyView.bounds.width, height: cardHeight))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 14
        bodyView.addSubview(card)

        let title = NSTextField(labelWithString: "輸入語言")
        title.frame = NSRect(x: 20, y: card.bounds.height - 38, width: 240, height: 24)
        title.font = .systemFont(ofSize: 17, weight: .semibold)
        title.textColor = .labelColor
        card.addSubview(title)

        let subtitle = NSTextField(labelWithString: "設定中英日三種語言的輸入模式。")
        subtitle.frame = NSRect(x: 20, y: card.bounds.height - 62, width: card.bounds.width - 40, height: 18)
        subtitle.font = .systemFont(ofSize: 12)
        subtitle.textColor = .secondaryLabelColor
        card.addSubview(subtitle)

        let items: [(label: String, key: String, options: [(String, CompositionLanguageSetting)], fallback: CompositionLanguageSetting)] = [
            ("中", chineseLanguageDefaultsKey, [("不使用", .disabled), ("注音輸入", .bopomofo)], .bopomofo),
            ("英", englishLanguageDefaultsKey, [("不使用", .disabled), ("標準輸入", .english)], .english),
            ("日", japaneseLanguageDefaultsKey, [("不使用", .disabled), ("拼音輸入", .japanese)], .disabled),
        ]
        let rowHeight: CGFloat = 28
        let rowGap: CGFloat = 10
        let startY = card.bounds.height - 100
        for (index, item) in items.enumerated() {
            let y = startY - CGFloat(index) * (rowHeight + rowGap)

            let label = NSTextField(labelWithString: item.label)
            label.frame = NSRect(x: 20, y: y + 4, width: 28, height: 20)
            label.font = .systemFont(ofSize: 14, weight: .medium)
            label.textColor = .labelColor
            card.addSubview(label)

            let popup = NSPopUpButton(frame: NSRect(x: 64, y: y, width: card.bounds.width - 84, height: 30), pullsDown: false)
            popup.identifier = NSUserInterfaceItemIdentifier(item.key)
            for option in item.options {
                popup.addItem(withTitle: option.0)
                popup.lastItem?.representedObject = option.1.rawValue
            }
            let currentRaw = imeDefaults.string(forKey: item.key) ?? item.fallback.rawValue
            if let idx = item.options.firstIndex(where: { $0.1.rawValue == currentRaw }) {
                popup.selectItem(at: idx)
            } else {
                popup.selectItem(at: 0)
            }
            popup.target = self
            popup.action = #selector(handleLanguagePopup(_:))
            card.addSubview(popup)
            languagePopups[item.key] = popup
        }

        return contentHeight
    }

    private func buildAboutPage(in bodyView: NSView, visibleHeight: CGFloat) -> CGFloat {
        let contentHeight = max(visibleHeight, 220)
        let card = NSView(frame: NSRect(x: 0, y: contentHeight - 160, width: bodyView.bounds.width, height: 148))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 14
        bodyView.addSubview(card)

        let eyebrow = NSTextField(labelWithString: "版本資訊")
        eyebrow.frame = NSRect(x: 20, y: card.bounds.height - 34, width: 120, height: 16)
        eyebrow.font = .systemFont(ofSize: 11, weight: .medium)
        eyebrow.textColor = .secondaryLabelColor
        card.addSubview(eyebrow)

        let title = NSTextField(labelWithString: "全一輸入法")
        title.frame = NSRect(x: 20, y: card.bounds.height - 66, width: 240, height: 28)
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.textColor = .labelColor
        card.addSubview(title)

        let versionLabel = NSTextField(labelWithString: Self.formattedBuildVersionString())
        versionLabel.frame = NSRect(x: 20, y: card.bounds.height - 100, width: card.bounds.width - 40, height: 22)
        versionLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .medium)
        versionLabel.textColor = .controlAccentColor
        card.addSubview(versionLabel)

        let note = NSTextField(labelWithString: "版本格式：1.YY.MMDD build HHmm")
        note.frame = NSRect(x: 20, y: 18, width: card.bounds.width - 40, height: 18)
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        card.addSubview(note)
        return contentHeight
    }

#if DEBUG
    private func buildDebugPage(in bodyView: NSView, visibleHeight: CGFloat) -> CGFloat {
        let contentHeight = max(visibleHeight, 460)
        let sectionGap: CGFloat = 4

        let profilingCard = NSView(frame: NSRect(x: 0, y: contentHeight - 144, width: bodyView.bounds.width, height: 136))
        profilingCard.wantsLayer = true
        profilingCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        profilingCard.layer?.cornerRadius = 14
        bodyView.addSubview(profilingCard)

        let title = NSTextField(labelWithString: "Runtime Profiling")
        title.frame = NSRect(x: 20, y: profilingCard.bounds.height - 34, width: 260, height: 22)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        profilingCard.addSubview(title)

        let subtitle = NSTextField(labelWithString: "切換 UNIFYIME_PROFILE 的 runtime 行為，並重置平均耗時統計。")
        subtitle.frame = NSRect(x: 20, y: profilingCard.bounds.height - 56, width: profilingCard.bounds.width - 40, height: 16)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        profilingCard.addSubview(subtitle)

        let toggle = NSButton(checkboxWithTitle: "啟用 profiling", target: self, action: #selector(handleProfilingToggle(_:)))
        toggle.frame = NSRect(x: 20, y: 50, width: 220, height: 22)
        toggle.state = isRuntimeProfilingEnabled ? .on : .off
        profilingCard.addSubview(toggle)
        profilingToggleButton = toggle

        let globalValue = NSTextField(labelWithString: "尚無樣本")
        globalValue.frame = NSRect(x: 20, y: 16, width: profilingCard.bounds.width - 40, height: 20)
        globalValue.font = .systemFont(ofSize: 13, weight: .medium)
        globalValue.textColor = .labelColor
        profilingCard.addSubview(globalValue)
        perCharacterValueLabel = globalValue

        let metricRowHeight: CGFloat = 32
        let metricsCardHeight = 38 + CGFloat(Self.debugMetricLabels.count) * metricRowHeight
        let metricsCardY = profilingCard.frame.minY - sectionGap - metricsCardHeight
        let metricsCard = NSView(frame: NSRect(x: 0, y: metricsCardY, width: bodyView.bounds.width, height: metricsCardHeight))
        metricsCard.wantsLayer = true
        metricsCard.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        metricsCard.layer?.cornerRadius = 14
        bodyView.addSubview(metricsCard)

        let metricsTitle = NSTextField(labelWithString: "重要耗時平均")
        metricsTitle.frame = NSRect(x: 20, y: metricsCard.bounds.height - 34, width: 240, height: 22)
        metricsTitle.font = .systemFont(ofSize: 16, weight: .semibold)
        metricsCard.addSubview(metricsTitle)

        debugMetricValueLabels.removeAll()
        let startY = metricsCard.bounds.height - 62
        for (index, metricLabel) in Self.debugMetricLabels.enumerated() {
            let y = startY - CGFloat(index) * metricRowHeight
            let nameLabel = NSTextField(labelWithString: metricLabel)
            nameLabel.frame = NSRect(x: 20, y: y + 12, width: metricsCard.bounds.width - 40, height: 14)
            nameLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
            nameLabel.textColor = .secondaryLabelColor
            metricsCard.addSubview(nameLabel)

            let valueLabel = NSTextField(labelWithString: "尚無樣本")
            valueLabel.frame = NSRect(x: 20, y: y - 2, width: metricsCard.bounds.width - 40, height: 16)
            valueLabel.font = .systemFont(ofSize: 12, weight: .medium)
            valueLabel.textColor = .labelColor
            metricsCard.addSubview(valueLabel)
            debugMetricValueLabels[metricLabel] = valueLabel
        }

        refreshDebugMetrics()
        return contentHeight
    }
#endif
}

final class TrainingProgressAppDelegate: NSObject, NSApplicationDelegate {
    private let outputDir: URL
    private var controller: TrainingProgressWindowController?

    init(outputDir: URL) {
        self.outputDir = outputDir
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = TrainingProgressWindowController(outputDir: outputDir)
        self.controller = controller
        controller.start()
    }
}
