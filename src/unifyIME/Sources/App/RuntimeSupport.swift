import AppKit
import Carbon
import InputMethodKit
import UserNotifications

private let processEnv = ProcessInfo.processInfo.environment

private func firstExistingURL(_ urls: [URL?]) -> URL? {
    let fm = FileManager.default
    for url in urls.compactMap({ $0 }) where fm.fileExists(atPath: url.path) {
        return url
    }
    return nil
}

private func resolvedWorkspaceRootURL() -> URL? {
    let fm = FileManager.default
    let envKeys = ["UNIFYIME_WORKSPACE_ROOT", "FASTCHIME_WORKSPACE_ROOT"]
    for key in envKeys {
        if let raw = processEnv[key], !raw.isEmpty {
            let url = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL
            if fm.fileExists(atPath: url.appendingPathComponent("src/unifyIME", isDirectory: true).path) {
                return url
            }
        }
    }

    var candidates: [URL] = []
    if let cwd = processEnv["PWD"], !cwd.isEmpty {
        candidates.append(URL(fileURLWithPath: cwd, isDirectory: true))
    }
    candidates.append(URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true))
    if let executableURL = Bundle.main.executableURL {
        candidates.append(executableURL.deletingLastPathComponent())
    }

    for start in candidates {
        var cursor = start.standardizedFileURL
        for _ in 0..<8 {
            if fm.fileExists(atPath: cursor.appendingPathComponent("src/unifyIME", isDirectory: true).path) {
                return cursor
            }
            let parent = cursor.deletingLastPathComponent()
            if parent.path == cursor.path { break }
            cursor = parent
        }
    }
    return nil
}

private func resolvedPythonScriptURL(named name: String) -> URL? {
    if let explicit = processEnv["UNIFYIME_\(name.uppercased())_PATH"] ?? processEnv["FASTCHIME_\(name.uppercased())_PATH"],
       !explicit.isEmpty {
        return URL(fileURLWithPath: explicit)
    }
    guard let workspaceRootURL else { return nil }
    let scriptURL = workspaceRootURL.appendingPathComponent("src/unifyIME/scripts/\(name).py")
    return FileManager.default.fileExists(atPath: scriptURL.path) ? scriptURL : nil
}

var gCurrentCandidateController: CandidateController?
let imeStateNotification = Notification.Name("com.vader.unifyime.state")
let workspaceRootURL = resolvedWorkspaceRootURL()
let isRuntimeTraceEnabled = false
let runtimeProfilingEnvDefault = processEnv["UNIFYIME_PROFILE"] == "1"
    || processEnv["FASTCHIME_PROFILE"] == "1"
let isDebugHelperMode = ProcessInfo.processInfo.environment["UNIFYIME_DEBUG_HELPER"] == "1"
    || ProcessInfo.processInfo.environment["FASTCHIME_DEBUG_HELPER"] == "1"
let helperCaretXOffset: CGFloat = 8
let visibleCandidateLimit = 20
let fastChIMEDataDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/UnifyIME", isDirectory: true)
let runtimeTempDir = fastChIMEDataDir.appendingPathComponent("temp", isDirectory: true)
let runtimeTraceURL = URL(fileURLWithPath: processEnv["UNIFYIME_RUNTIME_TRACE"]
    ?? processEnv["FASTCHIME_RUNTIME_TRACE"]
    ?? runtimeTempDir.appendingPathComponent("unifyime-runtime.log").path)
let userSelectionLogURL = fastChIMEDataDir.appendingPathComponent("user_selection_log.jsonl")
let regressionBacklogURL = fastChIMEDataDir.appendingPathComponent("regression_backlog.jsonl")
let defaultTrainingOutputDir = URL(fileURLWithPath: processEnv["UNIFYIME_TRAIN_OUTPUT_DIR"]
    ?? processEnv["FASTCHIME_TRAIN_OUTPUT_DIR"]
    ?? workspaceRootURL?.appendingPathComponent("artifacts/training/mlp_x20").path
    ?? fastChIMEDataDir.appendingPathComponent("training/mlp_x20").path,
    isDirectory: true)
let retrainScriptURL = resolvedPythonScriptURL(named: "retrain_ranker")
let installModelScriptURL = resolvedPythonScriptURL(named: "install_ranker_model")
let stableRuntimeModelURL = firstExistingURL([
    (processEnv["UNIFYIME_STABLE_MODEL_PATH"] ?? processEnv["FASTCHIME_STABLE_MODEL_PATH"]).flatMap { raw in
        raw.isEmpty ? nil : URL(fileURLWithPath: raw)
    },
    workspaceRootURL?.appendingPathComponent("artifacts/models/CandidateRanker.mlmodel"),
    workspaceRootURL?.appendingPathComponent("src/unifyIME/artifacts/x10_iter2/CandidateRanker.mlmodel"),
    workspaceRootURL?.appendingPathComponent("src/unifyIME/artifacts/CandidateRanker.mlmodel")
])
let candidateWindowModeDefaultsKey = "UnifyIME.CandidateWindowMode"
let candidateEngineModeDefaultsKey = "UnifyIME.CandidateEngineMode"
let candidateCursorAlignmentDefaultsKey = "UnifyIME.CandidateCursorAlignment"
let pauseRecognitionModeDefaultsKey = "UnifyIME.PauseRecognitionMode"
let chineseLanguageDefaultsKey = "UnifyIME.Language.zh"
let englishLanguageDefaultsKey = "UnifyIME.Language.en"
let japaneseLanguageDefaultsKey = "UnifyIME.Language.ja"
let runtimeProfilingDefaultsKey = "UnifyIME.Debug.RuntimeProfilingEnabled"
let imeDefaults = UserDefaults(suiteName: Bundle.main.bundleIdentifier ?? "com.vader.inputmethod.UnifyIME") ?? .standard
let candidateEngineModeStateURL = fastChIMEDataDir.appendingPathComponent("candidate_engine_mode.txt")
var lastKnownCandidateAnchor: CGPoint?
let fallbackCandidateAdvanceX: CGFloat = 13
let candidatePanelXOffset: CGFloat = 6
let candidatePanelYOffset: CGFloat = 22
let helperCandidatePanelXOffset: CGFloat = 0
let helperCandidatePanelYOffset: CGFloat = 16
let helperCaretHeight: CGFloat = 18
let helperCandidateFlipGap: CGFloat = 10
let compactSelectionMarker = "[[SEL]]"
let runtimeBuildTag = "backspace-trace-20260325-1"
let qwertyLetterByKeyCode: [UInt16: String] = [
    0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g",
    6: "z", 7: "x", 8: "c", 9: "v", 11: "b", 12: "q",
    13: "w", 14: "e", 15: "r", 16: "y", 17: "t", 31: "o",
    32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
    41: ";", 45: "n", 46: "m"
]
let englishMergeTriggerSet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'-")
let maxMixedRawBufferLength = 120
let focusedTraceRawTokens: Set<String> = ["z8", "vu04", "z8vu04"]
private let runtimeProfileLock = NSLock()
private var runtimeProfilingEnabledState: Bool = {
    if let explicit = imeDefaults.object(forKey: runtimeProfilingDefaultsKey) as? Bool {
        return explicit
    }
    return runtimeProfilingEnvDefault
}()
private var runtimeProfileTotalsNs: [String: UInt64] = [:]
private var runtimeProfileSampleCounts: [String: Int] = [:]
private var runtimeProfileLastMs: [String: Double] = [:]
private var runtimePerCharacterTotalNs: UInt64 = 0
private var runtimePerCharacterUnitCount: Int = 0
private var runtimePerCharacterEventCount: Int = 0
private var runtimePerCharacterLastMs: Double = 0

struct RuntimeProfileMetricSnapshot {
    let label: String
    let averageMs: Double
    let sampleCount: Int
    let lastMs: Double
}

struct RuntimePerCharacterSnapshot {
    let averageMsPerCharacter: Double
    let characterCount: Int
    let eventCount: Int
    let lastMsPerCharacter: Double
}

enum UnifyIMEMenu {
    static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }
}

enum CandidateWindowMode: String {
    case basic
    case detailed

    var title: String {
        switch self {
        case .basic: return "基本版"
        case .detailed: return "詳細版"
        }
    }
}

enum CandidateEngineMode: String, CaseIterable {
    case aiPreferredTraditionalAssist
    case traditionalPreferredAIAssist
    case aiDecides
    case traditionalOnly

    var title: String {
        switch self {
        case .aiPreferredTraditionalAssist: return "AI 優先+傳統輔助"
        case .traditionalPreferredAIAssist: return "傳統優先+AI 輔助"
        case .aiDecides: return "AI 先決"
        case .traditionalOnly: return "傳統模式"
        }
    }
}

enum CandidateCursorAlignment: String, CaseIterable {
    case left
    case right

    var title: String {
        switch self {
        case .left: return "靠左"
        case .right: return "靠右"
        }
    }
}

enum PauseRecognitionMode: String, CaseIterable {
    case verySlow
    case slow
    case normal
    case fast
    case veryFast

    var title: String {
        switch self {
        case .verySlow: return "超慢"
        case .slow: return "慢"
        case .normal: return "預設"
        case .fast: return "快"
        case .veryFast: return "很快"
        }
    }

    var interval: TimeInterval {
        switch self {
        case .verySlow: return 0.6
        case .slow: return 0.4
        case .normal: return 0.15
        case .fast: return 0.1
        case .veryFast: return 0.08
        }
    }
}

var currentCandidateWindowMode: CandidateWindowMode {
    get {
        let raw = imeDefaults.string(forKey: candidateWindowModeDefaultsKey)
        return CandidateWindowMode(rawValue: raw ?? "") ?? .basic
    }
    set {
        imeDefaults.set(newValue.rawValue, forKey: candidateWindowModeDefaultsKey)
        imeDefaults.synchronize()
    }
}

var currentPauseRecognitionMode: PauseRecognitionMode {
    get {
        let raw = imeDefaults.string(forKey: pauseRecognitionModeDefaultsKey)
        return PauseRecognitionMode(rawValue: raw ?? "") ?? .normal
    }
    set {
        imeDefaults.set(newValue.rawValue, forKey: pauseRecognitionModeDefaultsKey)
        imeDefaults.synchronize()
    }
}

var currentCandidateCursorAlignment: CandidateCursorAlignment {
    get {
        let raw = imeDefaults.string(forKey: candidateCursorAlignmentDefaultsKey)
        return CandidateCursorAlignment(rawValue: raw ?? "") ?? .left
    }
    set {
        imeDefaults.set(newValue.rawValue, forKey: candidateCursorAlignmentDefaultsKey)
        imeDefaults.synchronize()
    }
}

var isRuntimeProfilingEnabled: Bool {
    get {
        runtimeProfileLock.lock()
        let value = runtimeProfilingEnabledState
        runtimeProfileLock.unlock()
        return value
    }
    set {
        runtimeProfileLock.lock()
        runtimeProfilingEnabledState = newValue
        if !newValue {
            runtimeProfileTotalsNs.removeAll()
            runtimeProfileSampleCounts.removeAll()
            runtimeProfileLastMs.removeAll()
            runtimePerCharacterTotalNs = 0
            runtimePerCharacterUnitCount = 0
            runtimePerCharacterEventCount = 0
            runtimePerCharacterLastMs = 0
        }
        runtimeProfileLock.unlock()
        imeDefaults.set(newValue, forKey: runtimeProfilingDefaultsKey)
        imeDefaults.synchronize()
        appendRuntimeTrace("profiling.enabled value=\(newValue)")
    }
}

var cachedCandidateEngineMode: CandidateEngineMode?
var currentCandidateEngineMode: CandidateEngineMode {
    get {
        if let cachedCandidateEngineMode {
            return cachedCandidateEngineMode
        }
        if let raw = try? String(contentsOf: candidateEngineModeStateURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let resolved = CandidateEngineMode(rawValue: raw) {
            cachedCandidateEngineMode = resolved
            return resolved
        }
        let raw = imeDefaults.string(forKey: candidateEngineModeDefaultsKey)
        let resolved = CandidateEngineMode(rawValue: raw ?? "") ?? .aiPreferredTraditionalAssist
        cachedCandidateEngineMode = resolved
        return resolved
    }
    set {
        cachedCandidateEngineMode = newValue
        imeDefaults.set(newValue.rawValue, forKey: candidateEngineModeDefaultsKey)
        imeDefaults.synchronize()
        try? FileManager.default.createDirectory(at: candidateEngineModeStateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (newValue.rawValue + "\n").write(to: candidateEngineModeStateURL, atomically: true, encoding: .utf8)
        appendRuntimeTrace("candidateEngineMode.set value=\(newValue.rawValue)")
    }
}

extension CandidateController {
    static let horizontal = HorizontalCandidateController()
    static let vertical = VerticalCandidateController()
    static let preferred = VerticalCandidateController()
}

func imeDebugLog(_ message: String) {
    guard isRuntimeTraceEnabled else { return }
    NSLog("%@", message)
}

func appendRuntimeTrace(_ line: String) {
    guard isRuntimeTraceEnabled else { return }
    let text = "[\(ISO8601DateFormatter().string(from: Date()))] \(line)\n"
    guard let data = text.data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(at: runtimeTraceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: runtimeTraceURL.path),
       let handle = try? FileHandle(forWritingTo: runtimeTraceURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: runtimeTraceURL)
    }
}

func appendFocusedTrace(_ line: String) {
    guard isRuntimeTraceEnabled else { return }
    let text = "[\(ISO8601DateFormatter().string(from: Date()))] [focus] \(line)\n"
    guard let data = text.data(using: .utf8) else { return }
    try? FileManager.default.createDirectory(at: runtimeTraceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    if FileManager.default.fileExists(atPath: runtimeTraceURL.path),
       let handle = try? FileHandle(forWritingTo: runtimeTraceURL) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
        try? handle.close()
    } else {
        try? data.write(to: runtimeTraceURL)
    }
}

@discardableResult
func profileRuntime<T>(_ label: String, details: @autoclosure () -> String = "", _ work: () -> T) -> T {
    guard isRuntimeProfilingEnabled else { return work() }
    let startedAt = DispatchTime.now().uptimeNanoseconds
    let result = work()
    let elapsedNs = DispatchTime.now().uptimeNanoseconds - startedAt
    let elapsedMs = Double(elapsedNs) / 1_000_000.0
    runtimeProfileLock.lock()
    runtimeProfileTotalsNs[label, default: 0] += elapsedNs
    runtimeProfileSampleCounts[label, default: 0] += 1
    runtimeProfileLastMs[label] = elapsedMs
    runtimeProfileLock.unlock()
    let suffix = details()
    appendRuntimeTrace(String(format: "profile %@ elapsed_ms=%.3f%@", label, elapsedMs, suffix.isEmpty ? "" : " \(suffix)"))
    return result
}

func runtimeProfileSnapshots(labels: [String]? = nil) -> [RuntimeProfileMetricSnapshot] {
    runtimeProfileLock.lock()
    let resolvedLabels = labels ?? Array(runtimeProfileSampleCounts.keys).sorted()
    let snapshots = resolvedLabels.compactMap { label -> RuntimeProfileMetricSnapshot? in
        guard let sampleCount = runtimeProfileSampleCounts[label], sampleCount > 0 else { return nil }
        let totalNs = runtimeProfileTotalsNs[label] ?? 0
        let averageMs = Double(totalNs) / Double(sampleCount) / 1_000_000.0
        let lastMs = runtimeProfileLastMs[label] ?? 0
        return RuntimeProfileMetricSnapshot(
            label: label,
            averageMs: averageMs,
            sampleCount: sampleCount,
            lastMs: lastMs
        )
    }
    runtimeProfileLock.unlock()
    return snapshots
}

func recordRuntimePerCharacterProcessing(elapsedNs: UInt64, characterCount: Int) {
    guard isRuntimeProfilingEnabled, characterCount > 0 else { return }
    runtimeProfileLock.lock()
    runtimePerCharacterTotalNs += elapsedNs
    runtimePerCharacterUnitCount += characterCount
    runtimePerCharacterEventCount += 1
    runtimePerCharacterLastMs = Double(elapsedNs) / Double(characterCount) / 1_000_000.0
    runtimeProfileLock.unlock()
}

func runtimePerCharacterSnapshot() -> RuntimePerCharacterSnapshot? {
    runtimeProfileLock.lock()
    guard runtimePerCharacterUnitCount > 0 else {
        runtimeProfileLock.unlock()
        return nil
    }
    let snapshot = RuntimePerCharacterSnapshot(
        averageMsPerCharacter: Double(runtimePerCharacterTotalNs) / Double(runtimePerCharacterUnitCount) / 1_000_000.0,
        characterCount: runtimePerCharacterUnitCount,
        eventCount: runtimePerCharacterEventCount,
        lastMsPerCharacter: runtimePerCharacterLastMs
    )
    runtimeProfileLock.unlock()
    return snapshot
}

func appendJSONL(_ object: [String: Any], to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: []) else { return }
    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
    try? handle.write(contentsOf: Data("\n".utf8))
}

func showUserNotice(title: String, message: String) {
    TransientNoticeWindowController.shared.show(title: title, message: message, duration: nil)
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound]) { _, _ in
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = message
        content.sound = nil
        let request = UNNotificationRequest(
            identifier: "UnifyIME-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }
}

func publishIMEState(_ text: String, anchor: CGPoint? = nil, showCandidates: Bool = true) {
    var userInfo: [String: Any] = ["text": text, "showCandidates": showCandidates]
    if let anchor {
        userInfo["anchorX"] = anchor.x
        userInfo["anchorY"] = anchor.y
    }
    DistributedNotificationCenter.default().postNotificationName(
        imeStateNotification,
        object: nil,
        userInfo: userInfo,
        deliverImmediately: true
    )
}

func screenVisibleFrame(containing point: CGPoint?) -> NSRect? {
    if let point,
       let screen = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }) {
        return screen.visibleFrame
    }
    return NSScreen.main?.visibleFrame
}

func publishIMEProbe(route: String, input: String, composing: String, candidateEntries: [CandidateEntry], selectedIndex: Int, focusInfo: String? = nil, anchor: CGPoint? = nil) {
    let safeIndex = min(selectedIndex, max(candidateEntries.count - 1, 0))
    let candidateDump = candidateEntries.isEmpty
        ? "（空）"
        : candidateEntries.enumerated().map { idx, entry in
            let marker = idx == safeIndex ? ">" : " "
            return "\(marker)\(idx + 1). \(entry.text)"
        }.joined(separator: "\n")
    if isDebugHelperMode {
        let focusBlock = focusInfo.map { "\n\n焦點：\n\($0)" } ?? ""
        publishIMEState("路徑：\n\(route)\n\n原始輸入：\n\(input)\n\n組字：\n\(composing.isEmpty ? "（空）" : composing)\(focusBlock)\n\n候選：\n\(candidateDump)", anchor: anchor)
    } else {
        publishIMEState("組字：\n\(composing.isEmpty ? "（空）" : composing)\n\n候選：\n\(candidateDump)", anchor: anchor)
    }
}

func publishBasicCandidateView(composing: String, candidateEntries: [CandidateEntry], selectedIndex: Int, anchor: CGPoint?, isVisible: Bool) {
    let safeIndex = min(selectedIndex, max(candidateEntries.count - 1, 0))
    let candidateDump = candidateEntries.isEmpty
        ? "（空）"
        : candidateEntries.enumerated().map { idx, entry in
            let prefix = idx == safeIndex ? compactSelectionMarker : ""
            return "\(prefix)\(idx + 1). \(entry.text)"
        }.joined(separator: "\n")
    publishIMEState(candidateDump, anchor: anchor, showCandidates: isVisible)
}

func publishDetailedProbeIfNeeded(route: String, input: String, composing: String, candidateEntries: [CandidateEntry], selectedIndex: Int, focusInfo: String? = nil, anchor: CGPoint? = nil) {
    guard currentCandidateWindowMode == .detailed else { return }
    publishIMEProbe(route: route, input: input, composing: composing, candidateEntries: candidateEntries, selectedIndex: selectedIndex, focusInfo: focusInfo, anchor: anchor)
}
