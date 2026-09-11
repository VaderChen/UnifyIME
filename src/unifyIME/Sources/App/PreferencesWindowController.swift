import AppKit
import WebKit

/// 偏好設定以本機網頁呈現；輸入法狀態仍由既有 Swift 設定介面管理。
final class PreferencesWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, WKScriptMessageHandlerWithReply {
    static let shared = PreferencesWindowController()
    private let webView: WKWebView
    private let pageURL: URL?
    private let readOnly: Bool
    private var selectedSection = "general"
    private var updateBusy = false
    private var updateStatus = ""
    private var updateProgress: Double?
#if DEBUG
    private var debugRefreshTimer: Timer?
    private static let debugMetricLabels = [
        "readingWalker.resolveWalk", "mixedMerge.analyze", "mixedMerge.cacheHit",
        "mixedMerge.mergeSpanCoverages", "mixedMerge.englishSpanScan",
        "unified.mergeSpanCoverages.total", "unified.mergeSpanCoverages.spanCoverages",
        "unified.mergeSpanCoverages.dp", "session.recomputeRawSpanMerge", "session.rankCandidates"
    ]
#endif

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        let bundled = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Preferences")
        let source = workspaceRootURL?.appendingPathComponent("src/unifyIME/Resources/Preferences/index.html")
        pageURL = [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        let window = PreferencesWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 540),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false
        )
        window.title = readOnly ? "全一輸入法偏好設定 · 唯讀預覽" : "全一輸入法偏好設定"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 740, height: 540)
        window.maxSize = NSSize(width: 740, height: 540)
        window.center()
        super.init(window: window)
        shouldCascadeWindows = false
        window.delegate = self
        window.contentView = webView
        webView.navigationDelegate = self
        configuration.userContentController.addScriptMessageHandler(
            PreferencesMessageProxy(owner: self), contentWorld: .page, name: "preferences"
        )
        if let pageURL {
            webView.loadFileURL(pageURL, allowingReadAccessTo: pageURL.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<html lang='zh-Hant'><body><h2>無法載入偏好設定</h2><p>找不到本機介面資源，請重新建置應用程式。</p></body></html>", baseURL: nil)
        }
    }

    private func updateAlert() -> NSAlert {
        let alert = NSAlert()
        if let url = Bundle.main.url(forResource: "Bopomofo", withExtension: "tiff"),
           let icon = NSImage(contentsOf: url) { alert.icon = icon }
        return alert
    }

    private func checkForUpdates() {
        guard !readOnly, !updateBusy else { return }
        updateBusy = true
        updateStatus = "正在檢查更新…"
        publishState()
        Task { @MainActor in
            defer { updateBusy = false; updateProgress = nil; publishState() }
            var preparedInstaller: URL?
            do {
                let current = Self.formattedBuildVersionString()
                guard let update = try await ReleaseUpdater.latest(current: current) else {
                    updateStatus = "目前已是最新版本"
                    return
                }
                updateStatus = "找到新版 \(update.version.display)"
                publishState()
                let alert = updateAlert()
                alert.messageText = "發現新版全一輸入法"
                alert.informativeText = "目前版本：\(current)\n最新版本：\(update.version.display)\n\n確認後將下載並安裝，完成時會重新啟動輸入法。請先送出尚未完成的文字；個人詞頻與偏好設定會保留。"
                alert.addButton(withTitle: "下載並安裝")
                alert.addButton(withTitle: "稍後")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    updateStatus = "已取消更新"
                    return
                }
                updateStatus = "正在下載並驗證更新…"
                publishState()
                let installer = try await ReleaseUpdater.prepare(update) { [weak self] fraction, status in
                    Task { @MainActor in
                        guard let self, self.updateBusy else { return }
                        self.updateProgress = fraction
                        self.updateStatus = status
                        self.publishState()
                    }
                }
                updateProgress = nil
                preparedInstaller = installer
                updateStatus = "正在啟動安裝程式…"
                publishState()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.arguments = ["--update"]
                configuration.activates = true
                configuration.createsNewApplicationInstance = true
                _ = try await NSWorkspace.shared.openApplication(at: installer, configuration: configuration)
                updateStatus = "安裝程式已啟動，完成後會重新載入輸入法"
            } catch {
                if let preparedInstaller { try? FileManager.default.removeItem(at: preparedInstaller.deletingLastPathComponent()) }
                updateStatus = "更新未完成，請重試"
                let alert = updateAlert()
                alert.messageText = "無法完成版本更新"
                alert.informativeText = error.localizedDescription
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        publishState()
#if DEBUG
        updateDebugTimer()
#endif
    }

    func windowDidBecomeKey(_ notification: Notification) { publishState() }
    func windowWillClose(_ notification: Notification) {
#if DEBUG
        debugRefreshTimer?.invalidate()
        debugRefreshTimer = nil
#endif
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // 只接受 app 內的同一份頁面；不允許網路、子框架或新視窗導航。
        let allowed = navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.standardizedFileURL == pageURL?.standardizedFileURL
        decisionHandler(allowed ? .allow : .cancel)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.request.url?.standardizedFileURL == pageURL?.standardizedFileURL,
              let body = message.body as? [String: Any], let type = body["type"] as? String else {
            replyHandler(nil, "不支援的訊息來源。")
            return
        }
        switch type {
        case "ready":
            replyHandler(snapshot(), nil)
        case "section":
            guard let section = body["section"] as? String, sections.contains(section) else {
                replyHandler(nil, "不支援的頁面。")
                return
            }
            selectedSection = section
#if DEBUG
            updateDebugTimer()
#endif
            replyHandler(snapshot(), nil)
        case "checkForUpdates":
            guard !readOnly else { replyHandler(nil, "唯讀預覽不會執行更新。"); return }
            checkForUpdates()
            replyHandler(snapshot(), nil)
        case "set":
            guard !readOnly else { replyHandler(nil, "唯讀預覽不會變更設定。"); return }
            guard let key = body["key"] as? String, let value = body["value"], applySetting(key: key, value: value) else {
                replyHandler(nil, "設定名稱或數值不正確。")
                return
            }
            replyHandler(snapshot(), nil)
        default:
            replyHandler(nil, "不支援的操作。")
        }
    }

    private var sections: [String] {
        let result = ["general", "language", "debug", "about"]
        return result
    }

    private func applySetting(key: String, value: Any) -> Bool {
        switch key {
        case "engine":
            guard let raw = value as? String, let mode = CandidateEngineMode(rawValue: raw), mode.isSupported else { return false }
            currentCandidateEngineMode = mode
        case "alignment":
            guard let raw = value as? String, let mode = CandidateCursorAlignment(rawValue: raw) else { return false }
            currentCandidateCursorAlignment = mode
        case "shiftLanguageToggle":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            shiftLanguageToggleEnabled = number.boolValue
        case "pause":
            guard let raw = value as? String, let mode = PauseRecognitionMode(rawValue: raw) else { return false }
            currentPauseRecognitionMode = mode
            showUserNotice(title: "全一輸入法", message: "停頓辨識已切換為\(mode.title)")
        case "chinese", "english":
            let languages: [String: (String, CompositionLanguageSetting)] = [
                "chinese": (chineseLanguageDefaultsKey, .bopomofo),
                "english": (englishLanguageDefaultsKey, .english)
            ]
            guard let item = languages[key], let raw = value as? String,
                  raw == CompositionLanguageSetting.disabled.rawValue || raw == item.1.rawValue else { return false }
            imeDefaults.set(raw, forKey: item.0)
            imeDefaults.synchronize()
#if DEBUG
        case "profiling":
            guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            isRuntimeProfilingEnabled = number.boolValue
#endif
        default:
            return false
        }
        appendRuntimeTrace("preferences.web key=\(key) value=\(value)")
        return true
    }

    private func snapshot() -> [String: Any] {
        func language(_ key: String, _ fallback: CompositionLanguageSetting) -> String {
            let raw = imeDefaults.string(forKey: key)
            return raw == CompositionLanguageSetting.disabled.rawValue ? CompositionLanguageSetting.disabled.rawValue : fallback.rawValue
        }
        let options: [String: [[String: Any]]] = [
            "engine": CandidateEngineMode.allCases.filter(\.isSupported).map {
                ["value": $0.rawValue, "title": $0.title, "group": "已支援"]
            } + CandidateEngineMode.allCases.filter { !$0.isSupported }.map {
                ["value": $0.rawValue, "title": $0.title, "group": "未支援", "disabled": true]
            },
            "alignment": CandidateCursorAlignment.allCases.map { ["value": $0.rawValue, "title": $0.title] },
            "pause": PauseRecognitionMode.allCases.map { ["value": $0.rawValue, "title": "\($0.title) · \(Int(($0.interval * 1000).rounded())) ms"] },
            "chinese": [["value": "disabled", "title": "不使用"], ["value": "bopomofo", "title": "注音輸入"]],
            "english": [["value": "disabled", "title": "不使用"], ["value": "english", "title": "標準輸入"]],
            "japanese": [["value": "disabled", "title": "不使用"]]
        ]
        var result: [String: Any] = [
            "sections": sections, "section": selectedSection, "readOnly": readOnly, "options": options, "disabledKeys": ["japanese"],
            "shiftLanguageToggle": shiftLanguageToggleEnabled,
            "values": ["engine": currentCandidateEngineMode.rawValue, "alignment": currentCandidateCursorAlignment.rawValue,
                       "pause": currentPauseRecognitionMode.rawValue, "chinese": language(chineseLanguageDefaultsKey, .bopomofo),
                       "english": language(englishLanguageDefaultsKey, .english), "japanese": CompositionLanguageSetting.disabled.rawValue],
            "version": Self.formattedBuildVersionString(),
            "updateBusy": updateBusy, "updateStatus": updateStatus,
            "updateProgress": updateProgress.map { $0 as Any } ?? NSNull()
        ]
#if DEBUG
        result["profiling"] = isRuntimeProfilingEnabled
        if let metric = runtimePerCharacterSnapshot() { result["perCharacterMs"] = metric.averageMsPerCharacter }
        result["metrics"] = runtimeProfileSnapshots(labels: Self.debugMetricLabels).map {
            ["label": $0.label, "averageMs": $0.averageMs, "samples": $0.sampleCount, "lastMs": $0.lastMs] as [String: Any]
        }
#endif
        return result
    }

    private func publishState() {
        guard webView.url?.standardizedFileURL == pageURL?.standardizedFileURL else { return }
        webView.callAsyncJavaScript("if (window.preferencesUI) window.preferencesUI.receive(state);",
                                   arguments: ["state": snapshot()], in: nil, in: .page) { _ in }
    }

#if DEBUG
    private func updateDebugTimer() {
        debugRefreshTimer?.invalidate()
        debugRefreshTimer = nil
        guard selectedSection == "debug", window?.isVisible == true else { return }
        debugRefreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.publishState() }
    }
#endif

    private static func formattedBuildVersionString() -> String {
        if let version = Bundle.main.object(forInfoDictionaryKey: "UnifyIMEBuildVersion") as? String,
           !version.isEmpty { return version }
        let date = Bundle.main.executableURL.flatMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate } ?? Date()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return String(format: "1.%02d.%02d%02d build %02d%02d", calendar.component(.year, from: date) % 100,
                      calendar.component(.month, from: date), calendar.component(.day, from: date),
                      calendar.component(.hour, from: date), calendar.component(.minute, from: date))
    }
}

private final class PreferencesMessageProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var owner: PreferencesWindowController?
    init(owner: PreferencesWindowController) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        guard let owner else { replyHandler(nil, "偏好設定已關閉。"); return }
        owner.userContentController(userContentController, didReceive: message, replyHandler: replyHandler)
    }
}

final class PreferencesPreviewAppDelegate: NSObject, NSApplicationDelegate {
    private var controller: PreferencesWindowController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = PreferencesWindowController(readOnly: true)
        self.controller = controller
        controller.show()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
