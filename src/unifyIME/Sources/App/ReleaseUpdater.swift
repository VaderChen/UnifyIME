import Foundation
import CryptoKit

/// 只接受本專案正式 Release；安裝由獨立安裝程式接手，避免輸入法替換自身。
enum ReleaseUpdater {
    struct Version: Comparable {
        let components: [Int]
        let display: String
        init?(_ text: String) {
            let normalized = text.hasPrefix("v") ? String(text.dropFirst()) : text
            let value = normalized.replacingOccurrences(of: "-build-", with: " build ")
            guard value.range(of: #"^1\.[0-9]{2}\.[0-9]{4} build [0-9]{4}$"#, options: .regularExpression) != nil else { return nil }
            components = value.components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap(Int.init)
            display = value
        }
        static func < (lhs: Self, rhs: Self) -> Bool { lhs.components.lexicographicallyPrecedes(rhs.components) }
    }
    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
        let digest: String?
    }
    struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    struct Update {
        let version: Version
        let asset: Asset
        let checksum: Asset?
    }
    static func failure(_ message: String) -> NSError {
        NSError(domain: "UnifyIMEUpdate", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("UnifyIME-Update", forHTTPHeaderField: "User-Agent")
        return request
    }
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw failure("無法取得更新，請檢查網路後再試；GitHub 也可能暫時限制查詢次數。")
        }
    }
    static func latest(current: String) async throws -> Update? {
        guard let installed = Version(current) else { throw failure("無法辨識目前 BUILD 版號，請重新安裝正式版本。") }
        var req = request(URL(string: "https://api.github.com/repos/VaderChen/UnifyIME/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: req)
        try validate(response)
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, let version = Version(release.tag_name) else {
            throw failure("最新 Release 沒有可辨識的正式 BUILD 版號。")
        }
        guard version > installed else { return nil }
#if arch(arm64)
        let arch = "arm64"
#else
        let arch = "x86_64"
#endif
        let filename = "UnifyIME-\(version.display.replacingOccurrences(of: " build ", with: "-build-"))-\(arch).dmg"
        guard let asset = release.assets.first(where: { $0.name == filename }), asset.size > 0,
              asset.size <= 512 * 1024 * 1024 else { throw failure("已找到新版，但尚未提供符合目前架構的安裝檔。") }
        return Update(version: version, asset: asset, checksum: release.assets.first { $0.name == filename + ".sha256" })
    }
    static func assetRequest(_ asset: Asset) throws -> URLRequest {
        let url = asset.browser_download_url
        guard url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/VaderChen/UnifyIME/releases/download/") else { throw failure("更新檔來源不正確。") }
        return request(url)
    }
    private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let expected: Int64
        let progress: @Sendable (Double?, String) -> Void
        private let lock = NSLock()
        private var lastPercent = -1
        private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
        private var downloaded: Result<(URL, URLResponse), Error>?
        func download(_ request: URLRequest) async throws -> (URL, URLResponse) {
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                session.downloadTask(with: request).resume()
            }
        }
        init(expected: Int64, progress: @escaping @Sendable (Double?, String) -> Void) {
            self.expected = expected
            self.progress = progress
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let fraction = min(1, max(0, Double(totalBytesWritten) / Double(max(1, expected))))
            let percent = Int(fraction * 100)
            lock.lock()
            let changed = percent != lastPercent
            lastPercent = percent
            lock.unlock()
            guard changed else { return }
            let received = ByteCountFormatter.string(fromByteCount: totalBytesWritten, countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: expected, countStyle: .file)
            progress(fraction, "下載中 \(percent)%（\(received)／\(total)）")
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            do {
                guard let response = downloadTask.response else { throw ReleaseUpdater.failure("下載未收到有效回應。") }
                // 委派返回後系統會刪除暫存檔，必須先搬到自己管理的路徑。
                let saved = FileManager.default.temporaryDirectory.appendingPathComponent("unifyime-download-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: location, to: saved)
                downloaded = .success((saved, response))
            } catch { downloaded = .failure(error) }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            defer { continuation = nil; session.finishTasksAndInvalidate() }
            if let error {
                if case .success(let value) = downloaded { try? FileManager.default.removeItem(at: value.0) }
                continuation?.resume(throwing: error)
            } else {
                continuation?.resume(with: downloaded ?? .failure(ReleaseUpdater.failure("下載未完成，請重新嘗試。")))
            }
        }
    }
    static func prepare(_ update: Update,
                        progress: @escaping @Sendable (Double?, String) -> Void = { _, _ in }) async throws -> URL {
        let expected: String
        if let digest = update.asset.digest, digest.hasPrefix("sha256:") {
            expected = String(digest.dropFirst(7)).lowercased()
        } else if let checksum = update.checksum, checksum.size < 4096 {
            let (data, response) = try await URLSession.shared.data(for: assetRequest(checksum))
            try validate(response)
            let fields = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[1] == update.asset.name else { throw failure("更新檔校驗資訊不正確。") }
            expected = String(fields[0]).lowercased()
        } else { throw failure("此版本缺少 SHA-256 校驗資訊，無法自動安裝。") }
        guard expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw failure("SHA-256 格式不正確。") }
        progress(0, "正在連線下載…")
        let delegate = DownloadDelegate(expected: update.asset.size, progress: progress)
        let (download, response) = try await delegate.download(assetRequest(update.asset))
        defer { try? FileManager.default.removeItem(at: download) }
        try validate(response)
        progress(nil, "下載完成，正在驗證並準備安裝…")
        return try await Task.detached {
            try prepareDownloaded(download, update: update, expected: expected)
        }.value
    }
    private static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw failure("更新檔驗證或準備失敗（\(URL(fileURLWithPath: executable).lastPathComponent)），尚未變更目前安裝。") }
        return data
    }
    private static func verifyApp(_ app: URL, identifier: String) throws {
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=identifier \"\(identifier)\" and anchor apple generic", app.path])
        _ = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
    }
    private static func prepareDownloaded(_ download: URL, update: Update, expected: String) throws -> URL {
        let fm = FileManager.default
        let size = try fm.attributesOfItem(atPath: download.path)[.size] as? NSNumber
        guard size?.int64Value == update.asset.size else { throw failure("下載檔案不完整，請重新嘗試。") }
        let handle = try FileHandle(forReadingFrom: download)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw failure("更新檔 SHA-256 不符，已停止安裝。") }
        let stage = fm.temporaryDirectory.appendingPathComponent("unifyime-update-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var handedOff = false
        defer { if !handedOff { try? fm.removeItem(at: stage) } }
        let image = stage.appendingPathComponent("update.dmg")
        try fm.copyItem(at: download, to: image)
        let mount = stage.appendingPathComponent("volume", isDirectory: true)
        try fm.createDirectory(at: mount, withIntermediateDirectories: false)
        _ = try run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", mount.path, image.path])
        var mounted = true
        defer { if mounted { _ = try? run("/usr/bin/hdiutil", ["detach", mount.path]) } }
        let source = mount.appendingPathComponent("安裝全一輸入法.app")
        let installer = stage.appendingPathComponent("安裝全一輸入法.app")
        _ = try run("/usr/bin/ditto", [source.path, installer.path])
        try verifyApp(installer, identifier: "com.vader.UnifyIME.Installer")
        let payload = installer.appendingPathComponent("Contents/Resources/全一輸入法.app")
        try verifyApp(payload, identifier: "com.vader.inputmethod.UnifyIME")
        guard let bundle = Bundle(url: payload),
              bundle.object(forInfoDictionaryKey: "UnifyIMEBuildVersion") as? String == update.version.display else {
            throw failure("安裝內容與 Release 版號不符，已停止安裝。")
        }
        if let minimum = bundle.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
            let parts = minimum.split(separator: ".").compactMap { Int($0) }
            guard !parts.isEmpty, ProcessInfo.processInfo.isOperatingSystemAtLeast(
                OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0,
                                       patchVersion: parts.count > 2 ? parts[2] : 0)) else {
                throw failure("新版需要 macOS \(minimum) 或更新版本。")
            }
        }
#if arch(arm64)
        let architecture = "arm64"
#else
        let architecture = "x86_64"
#endif
        _ = try run("/usr/bin/lipo", [payload.appendingPathComponent("Contents/MacOS/UnifyIME").path, "-verify_arch", architecture])
        _ = try run("/usr/bin/hdiutil", ["detach", mount.path])
        mounted = false
        try fm.removeItem(at: image)
        handedOff = true
        return installer
    }
}
