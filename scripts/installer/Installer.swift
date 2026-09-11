import AppKit
import Carbon

// 安裝僅作用於目前使用者，不需要管理員權限。
enum Installation {
    static let appName = "全一輸入法.app"
    static let registrar = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "UnifyIMEInstaller", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(URL(fileURLWithPath: executable).lastPathComponent) 執行失敗：\n\(output)"])
        }
        return output
    }

    static func payload() throws -> URL {
        guard let resource = Bundle.main.resourceURL else {
            throw NSError(domain: "UnifyIMEInstaller", code: 1, userInfo: [NSLocalizedDescriptionKey: "找不到安裝資源。"])
        }
        let source = resource.appendingPathComponent(appName)
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", source.path])
        guard FileManager.default.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/UnifyIME").path) else {
            throw NSError(domain: "UnifyIMEInstaller", code: 2, userInfo: [NSLocalizedDescriptionKey: "安裝檔不完整，請重新下載。"])
        }
        return source
    }

    static func launch(_ app: URL) throws {
        var lastError: Error?
        for _ in 0..<3 {
            do {
                try run("/usr/bin/open", ["-gja", app.path])
                try run("/usr/bin/open", ["-na", app.path, "--args", "basicSelWindow"])
                return
            } catch {
                lastError = error
                Thread.sleep(forTimeInterval: 1)
            }
        }
        throw lastError!
    }

    // 安裝工作在背景執行；TIS 切換交回主執行緒。
    private static func refreshInputSessionBeforeUpdate() -> (() -> Void)? {
        DispatchQueue.main.sync {
            guard let original = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                  let bundle = TISGetInputSourceProperty(original, kTISPropertyBundleID),
                  Unmanaged<CFString>.fromOpaque(bundle).takeUnretainedValue() as String == "com.vader.inputmethod.UnifyIME",
                  let originalID = TISGetInputSourceProperty(original, kTISPropertyInputSourceID),
                  let temporary = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let temporaryID = TISGetInputSourceProperty(temporary, kTISPropertyInputSourceID) else { return nil }
            let sourceID = Unmanaged<CFString>.fromOpaque(originalID).takeUnretainedValue() as String
            let temporarySourceID = Unmanaged<CFString>.fromOpaque(temporaryID).takeUnretainedValue() as String
            guard TISSelectInputSource(temporary) == noErr else { return nil }
            return {
                DispatchQueue.main.sync {
                    // 使用者若在更新期間選了其他來源，不覆蓋其選擇。
                    guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
                          let currentID = TISGetInputSourceProperty(current, kTISPropertyInputSourceID),
                          Unmanaged<CFString>.fromOpaque(currentID).takeUnretainedValue() as String == temporarySourceID else { return }
                    let filter = [kTISPropertyInputSourceID as String: sourceID] as CFDictionary
                    let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource] ?? []
                    if let refreshed = sources.first { _ = TISSelectInputSource(refreshed) }
                }
            }
        }
    }

    static func install() throws {
        let fm = FileManager.default
        let source = try payload()
        let directory = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Input Methods", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(appName)
        let stage = directory.appendingPathComponent(".unifyime-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        let incoming = stage.appendingPathComponent(appName)
        let backup = stage.appendingPathComponent("舊版.app.bak")
        var keepBackup = false
        defer { if !keepBackup { try? fm.removeItem(at: stage) } }
        try run("/usr/bin/ditto", [source.path, incoming.path])
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", incoming.path])
        let restoreInputSession = refreshInputSessionBeforeUpdate()
        defer { restoreInputSession?() }
        let existed = fm.fileExists(atPath: destination.path)
        if existed { try fm.moveItem(at: destination, to: backup) }
        do {
            try fm.moveItem(at: incoming, to: destination)
            try run(registrar, ["-f", destination.path])
            _ = try? run("/usr/bin/killall", ["UnifyIME"])
            try launch(destination)
        } catch {
            let installError = error
            do {
                _ = try? run("/usr/bin/killall", ["UnifyIME"])
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
                if existed {
                    try fm.moveItem(at: backup, to: destination)
                    _ = try? run(registrar, ["-f", destination.path])
                    try? launch(destination)
                }
            } catch {
                keepBackup = true
                throw NSError(domain: "UnifyIMEInstaller", code: 3, userInfo: [NSLocalizedDescriptionKey: "安裝失敗，舊版備份保留於：\(backup.path)\n\(installError.localizedDescription)\n還原失敗：\(error.localizedDescription)"])
            }
            throw installError
        }
    }
}

final class InstallerDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var installing = true
    // 舊版更新器未傳遞參數；已安裝的使用者也採用更新完成流程。
    private let automaticUpdate: Bool = {
        if CommandLine.arguments.contains("--update") { return true }
        let installed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods/全一輸入法.app/Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: installed) else { return false }
        return info["CFBundleIdentifier"] as? String == "com.vader.inputmethod.UnifyIME"
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 170),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "安裝全一輸入法"
        window.center()
        let label = NSTextField(wrappingLabelWithString: "正在安裝全一輸入法…\n更新時會自動備份並重新啟動輸入法。")
        label.frame = NSRect(x: 30, y: 75, width: 380, height: 60)
        let spinner = NSProgressIndicator(frame: NSRect(x: 30, y: 35, width: 380, height: 20))
        spinner.style = .bar
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        window.contentView?.addSubview(label)
        window.contentView?.addSubview(spinner)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try Installation.install() }
            DispatchQueue.main.async { self.finish(result) }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        installing = false
        if automaticUpdate, case .success = result {
            NSApp.terminate(nil)
            return
        }
        let alert = NSAlert()
        switch result {
        case .success:
            alert.messageText = "全一輸入法安裝完成"
            alert.informativeText = "首次使用：請在 macOS「鍵盤」設定的輸入來源中加入「全一輸入法」。若清單尚未出現，請登出後重新登入。\n\n更新使用者可直接切換回全一輸入法。"
            alert.addButton(withTitle: "開啟鍵盤設定")
            alert.addButton(withTitle: "完成")
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "未完成安裝"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "關閉")
        }
        let response = alert.runModal()
        if case .success = result, response == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        installing ? .terminateCancel : .terminateNow
    }
}

@main
struct InstallerMain {
    static func main() {
        if CommandLine.arguments.contains("--verify-payload") {
            do { print(try Installation.payload().path) }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            return
        }
        let app = NSApplication.shared
        let delegate = InstallerDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}
