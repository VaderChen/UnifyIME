import AppKit
import Carbon

/// MCP 子程序不重啟自己；只向登記的輸入法主程序要求正常結束。
enum IMERestart {
    struct Status: Codable {
        let pid: Int32
        let revision: Int
    }
    static let statusURL = fastChIMEDataDir.appendingPathComponent("ime_ready.json")
    private static var terminationObserver: NSObjectProtocol?
    static func publishReady() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            UserFrequencyStore.flush()
        }
        let state = Status(pid: getpid(), revision: PersonalVocabularyStore.loadedRevision)
        if let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: fastChIMEDataDir, withIntermediateDirectories: true)
            try? data.write(to: statusURL, options: .atomic)
        }
    }
    private static func status() -> Status? {
        guard let data = try? Data(contentsOf: statusURL) else { return nil }
        return try? JSONDecoder().decode(Status.self, from: data)
    }
    private static func property(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String
    }
    private static func pause() { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    static func restart(revision: Int) throws -> [String: Any] {
        guard try PersonalVocabularyStore.read().revision == revision else {
            throw PersonalVocabularyStore.failure("詞彙版本已改變，請先重新查詢 revision。")
        }
        let bundleID = "com.vader.inputmethod.UnifyIME"
        let app = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods/全一輸入法.app")
        guard let old = status(), old.pid != getpid(),
              let running = NSRunningApplication(processIdentifier: old.pid),
              running.bundleIdentifier == bundleID,
              running.bundleURL?.standardizedFileURL == app.standardizedFileURL else {
            throw PersonalVocabularyStore.failure("找不到可確認身分的輸入法主程序。請先安裝並啟動支援 MCP 重啟的版本。未終止任何程序。")
        }
        let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        var temporaryID: String?
        if let original, property(original, kTISPropertyBundleID) == bundleID {
            guard let temporary = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  TISSelectInputSource(temporary) == noErr else {
                throw PersonalVocabularyStore.failure("無法先切離輸入法，已取消重啟以保留組字。")
            }
            temporaryID = property(temporary, kTISPropertyInputSourceID)
            pause()
        }
        func restore() -> Bool {
            guard let temporaryID, let original else { return true }
            guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  property(current, kTISPropertyInputSourceID) == temporaryID else { return true }
            guard let id = property(original, kTISPropertyInputSourceID) else { return false }
            let sources = TISCreateInputSourceList([kTISPropertyInputSourceID as String: id] as CFDictionary, false)?.takeRetainedValue() as? [TISInputSource] ?? []
            return sources.first.map { TISSelectInputSource($0) == noErr } ?? false
        }
        var restored = false
        defer { if !restored { _ = restore() } }
        guard running.terminate() else { throw PersonalVocabularyStore.failure("輸入法拒絕正常結束，未強制終止。") }
        let deadline = Date().addingTimeInterval(8)
        while !running.isTerminated && Date() < deadline { pause() }
        guard running.isTerminated else { throw PersonalVocabularyStore.failure("等待結束逾時，未強制終止。請先完成目前輸入再重試。") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", "-gja", app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PersonalVocabularyStore.failure("無法重新啟動全一輸入法，請手動開啟。") }
        let readyDeadline = Date().addingTimeInterval(15)
        while Date() < readyDeadline {
            if let fresh = status(), fresh.pid != old.pid,
               let newProcess = NSRunningApplication(processIdentifier: fresh.pid),
               !newProcess.isTerminated, newProcess.bundleIdentifier == bundleID {
                restored = restore()
                guard fresh.revision == revision else { throw PersonalVocabularyStore.failure("程序已重啟，但套用的詞彙版本不同，請重新查詢。") }
                return ["restarted": true, "appliedRevision": fresh.revision, "inputSourceRestored": restored,
                        "message": restored ? "已重新啟動並套用個人詞彙。" : "詞彙已套用，但需手動切回全一輸入法。"]
            }
            pause()
        }
        throw PersonalVocabularyStore.failure("程序已啟動，但尚未收到載入完成狀態；未確認詞彙生效。")
    }
}
