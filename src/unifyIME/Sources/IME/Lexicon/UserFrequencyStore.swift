import Foundation

/// Per-language user frequency store.
/// Tracks how often the user selects each (reading → surface) pair.
/// Each language has its own TSV file under the app data directory.
/// English is skipped — call `record`/`boost` only for non-English targets.
enum UserFrequencyStore {
    private static let lock = NSLock()
    private static let persistenceLock = NSLock()
    /// languageID → (reading → [(surface, count)])
    private static var cache: [String: [String: [(surface: String, count: Int)]]] = [:]
    private static var dirty: Set<String> = []
    private static var revisions: [String: UInt64] = [:]
    private static var pendingFlush: DispatchWorkItem?

    // MARK: - Public API

    /// Record a user selection. Call after the user confirms a candidate.
    static func record(languageID: String, reading: String, surface: String) {
        guard shouldTrack(languageID) else { return }
        let key = reading.lowercased()
        lock.lock()
        var langMap = cache[languageID] ?? loadFromDisk(languageID: languageID)
        var entries = langMap[key] ?? []
        if let idx = entries.firstIndex(where: { $0.surface == surface }) {
            entries[idx].count += 1
        } else {
            entries.append((surface: surface, count: 1))
        }
        langMap[key] = entries
        cache[languageID] = langMap
        dirty.insert(languageID)
        revisions[languageID, default: 0] &+= 1
        scheduleFlushLocked()
        lock.unlock()
    }

    /// Return user frequency score for a candidate. Higher = user picks this more often.
    /// Returns 0 if no history.
    static func frequency(languageID: String, reading: String, surface: String) -> Int {
        guard shouldTrack(languageID) else { return 0 }
        return frequencyMap(languageID: languageID, reading: reading)[surface] ?? 0
    }

    /// Batch lookup: returns [surface: count] for a given reading. Single lock acquisition.
    static func frequencyMap(languageID: String, reading: String) -> [String: Int] {
        guard shouldTrack(languageID) else { return [:] }
        let key = reading.lowercased()
        lock.lock()
        let langMap = cache[languageID] ?? {
            let loaded = loadFromDisk(languageID: languageID)
            cache[languageID] = loaded
            return loaded
        }()
        lock.unlock()
        guard let entries = langMap[key] else { return [:] }
        return Dictionary(entries.map { ($0.surface, $0.count) }, uniquingKeysWith: max)
    }

    /// Reorder candidates by boosting user-preferred ones to the top.
    /// Candidates with user frequency are sorted by frequency (descending),
    /// followed by the rest in their original order.
    static func boost(languageID: String, reading: String, candidates: [String]) -> [String] {
        let freqMap = frequencyMap(languageID: languageID, reading: reading)
        guard !freqMap.isEmpty else { return candidates }
        let (boosted, rest) = candidates.reduce(into: ([(String, Int)](), [String]())) { result, c in
            if let freq = freqMap[c] {
                result.0.append((c, freq))
            } else {
                result.1.append(c)
            }
        }
        let sorted = boosted.sorted { $0.1 > $1.1 }.map(\.0)
        return sorted + rest
    }

    // MARK: - Internals

    private static let skipLanguageIDs: Set<String> = ["en", "english-ime"]

    private static func shouldTrack(_ languageID: String) -> Bool {
        !skipLanguageIDs.contains(languageID)
    }

    private static func fileURL(for languageID: String) -> URL {
        let safeName = languageID.replacingOccurrences(of: "/", with: "_")
        return fastChIMEDataDir.appendingPathComponent("user_freq_v2_\(safeName).tsv")
    }

    /// Load from disk. Must be called inside lock or when sole owner.
    private static func loadFromDisk(languageID: String) -> [String: [(surface: String, count: Int)]] {
        let url = fileURL(for: languageID)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var result: [String: [(surface: String, count: Int)]] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count >= 3 else { continue }
            let reading = String(parts[0])
            let surface = String(parts[1])
            let count = Int(parts[2]) ?? 0
            guard count > 0 else { continue }
            result[reading, default: []].append((surface: surface, count: count))
        }
        return result
    }

    private static func saveToDisk(languageID: String, data: [String: [(surface: String, count: Int)]]) throws {
        let url = fileURL(for: languageID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var lines: [String] = []
        for (reading, entries) in data.sorted(by: { $0.key < $1.key }) {
            for entry in entries.sorted(by: { $0.count > $1.count }) {
                lines.append("\(reading)\t\(entry.surface)\t\(entry.count)")
            }
        }
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// 必須持有 lock，包含延遲工作項目的取消與替換。
    private static func scheduleFlushLocked() {
        pendingFlush?.cancel()
        let item = DispatchWorkItem {
            flush()
        }
        pendingFlush = item
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5.0, execute: item)
    }

    static func flush() {
        // 序列化快照與寫入，避免較舊的 flush 最後完成、覆蓋較新的詞頻。
        persistenceLock.lock()
        defer { persistenceLock.unlock() }
        lock.lock()
        pendingFlush?.cancel()
        pendingFlush = nil
        let toFlush = dirty
        let snapshot = cache
        let savedRevisions = revisions
        lock.unlock()
        for langID in toFlush {
            guard let data = snapshot[langID] else { continue }
            do {
                try saveToDisk(languageID: langID, data: data)
                lock.lock()
                // 寫入期間仍允許選字；新記錄必須留待下一次保存。
                if revisions[langID] == savedRevisions[langID] {
                    dirty.remove(langID)
                }
                lock.unlock()
            } catch {
                // 保存失敗保留 dirty，後續 flush 可重試，不丟棄學習結果。
            }
        }
    }
}
