import Foundation
import Darwin

/// Agent 偏好與實際選字詞頻分開保存；跨程序鎖及 revision 防止覆蓋彼此修改。
enum PersonalVocabularyStore {
    struct Entry: Codable {
        var syllables: [String]
        var surface: String
        var priority: Int
        var reading: String { syllables.joined() }
    }
    struct Document: Codable {
        var revision = 0
        var entries: [Entry] = []
    }
    static let url = fastChIMEDataDir.appendingPathComponent("personal_vocabulary.json")
    private static let lock = NSLock()
    private(set) static var loadedRevision = 0
    private static var byReading: [String: [Entry]] = [:]

    static func failure(_ message: String) -> NSError {
        NSError(domain: "PersonalVocabulary", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
    static func read() throws -> Document {
        guard FileManager.default.fileExists(atPath: url.path) else { return Document() }
        let data = try Data(contentsOf: url)
        guard data.count <= 4_000_000 else { throw failure("個人詞彙檔過大。") }
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.revision >= 0, document.revision < Int.max - 1,
              document.entries.count <= 10_000 else { throw failure("個人詞彙檔格式錯誤。") }
        var keys = Set<String>()
        for entry in document.entries {
            try validate(entry)
            guard keys.insert(entry.reading + "\t" + entry.surface).inserted else { throw failure("個人詞彙檔有重複項目。") }
        }
        return document
    }
    static func update(revision: Int, entry: Entry, remove: Bool) throws -> Document {
        try batch(revision: revision, changes: [(entry, remove)], dryRun: false).document
    }
    static func batch(revision: Int, changes: [(entry: Entry, remove: Bool)], dryRun: Bool) throws -> (document: Document, before: Document) {
        guard (1...100).contains(changes.count) else { throw failure("每批需為 1–100 筆調整。") }
        var identities = Set<String>()
        for change in changes {
            try validate(change.entry)
            guard identities.insert(change.entry.reading + "\t" + change.entry.surface).inserted else {
                throw failure("同批不能重複修改同一詞彙。")
            }
        }
        try FileManager.default.createDirectory(at: fastChIMEDataDir, withIntermediateDirectories: true)
        let fd = open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw failure("無法取得個人詞彙鎖。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw failure("個人詞彙正在使用中。") }
        defer { flock(fd, LOCK_UN) }
        var document = try read()
        guard document.revision == revision else { throw failure("資料已更新，請重新查詢 revision 再修改。") }
        let before = document
        for change in changes {
            document.entries.removeAll { $0.reading == change.entry.reading && $0.surface == change.entry.surface }
            if !change.remove { document.entries.append(change.entry) }
        }
        guard document.entries.count <= 10_000 else { throw failure("個人詞彙上限為 10000 筆。") }
        if dryRun { return (document, before) }
        document.revision += 1
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        loadSnapshot()
        return (document, before)
    }
    static func validate(_ entry: Entry) throws {
        guard (1...8).contains(entry.syllables.count), entry.surface.count == entry.syllables.count,
              (-1000...1000).contains(entry.priority),
              entry.surface.unicodeScalars.allSatisfy({ (0x3400...0x9FFF).contains($0.value) || (0x20000...0x323AF).contains($0.value) }),
              entry.syllables.allSatisfy({ $0.range(of: "^[ㄅ-ㄩ]{1,3}[ˊˇˋ˙]?$", options: .regularExpression) != nil }) else {
            throw failure("需提供 1–8 個中文字、逐字注音音節，priority 範圍 -1000 至 1000。一聲不加調號，其餘聲調置於音節尾端。")
        }
    }
    /// 正式輸入法只在啟動時讀取；MCP 預覽可明確重新讀取檔案。
    static func loadSnapshot() {
        lock.lock(); defer { lock.unlock() }
        if let document = try? read() {
            byReading = Dictionary(grouping: document.entries, by: \.reading)
            loadedRevision = document.revision
        }
    }
    static func entries(reading: String) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return byReading[reading] ?? []
    }
    static func candidates(reading: String, base: [String]) -> [String] {
        let custom = entries(reading: reading)
        guard !custom.isEmpty else { return base }
        var seen = Set<String>()
        let merged = (base + custom.map(\.surface)).filter { seen.insert($0).inserted }
        return merged
    }

    static func bonus(language: String, reading: String, surface: String) -> Double {
        guard language == "zh-Hant" else { return 0 }
        return Double(entries(reading: reading).first { $0.surface == surface }?.priority ?? 0)
    }
}
