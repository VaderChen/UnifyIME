import Carbon
import Foundation

final class InputSourceHelper {
    static func allInstalledInputSources(includeAllInstalled: Bool = true) -> [TISInputSource] {
        TISCreateInputSourceList(nil, includeAllInstalled).takeRetainedValue() as! [TISInputSource]
    }

    static func inputSource(for sourceID: String) -> TISInputSource? {
        for source in allInstalledInputSources() {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
            if String(value) == sourceID { return source }
        }
        return nil
    }

    static func inputMode(for modeID: String) -> TISInputSource? {
        for source in allInstalledInputSources() {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputModeID) else { continue }
            let value = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue()
            if String(value) == modeID { return source }
        }
        return nil
    }

    static func inputSourceEnabled(for source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsEnabled) else { return false }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return value == kCFBooleanTrue
    }

    static func registerInputSource(at url: URL) -> Bool {
        TISRegisterInputSource(url as CFURL) == noErr
    }

    static func enable(inputSource: TISInputSource) -> Bool {
        TISEnableInputSource(inputSource) == noErr
    }

    static func select(inputSource: TISInputSource) -> Bool {
        TISSelectInputSource(inputSource) == noErr
    }

    static func inputSourceSelected(for source: TISInputSource) -> Bool {
        guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelected) else {
            return false
        }
        let value = Unmanaged<CFBoolean>.fromOpaque(ptr).takeUnretainedValue()
        return value == kCFBooleanTrue
    }

    static func waitUntilInputSourceEnabled(_ sourceID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputSource(for: sourceID), inputSourceEnabled(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputSource(for: sourceID) else { return false }
        return inputSourceEnabled(for: source)
    }

    static func waitUntilInputSourceSelected(_ sourceID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputSource(for: sourceID), inputSourceSelected(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputSource(for: sourceID) else { return false }
        return inputSourceSelected(for: source)
    }

    static func waitUntilInputModeEnabled(_ modeID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputMode(for: modeID), inputSourceEnabled(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputMode(for: modeID) else { return false }
        return inputSourceEnabled(for: source)
    }

    static func waitUntilInputModeSelected(_ modeID: String, retries: Int = 20, delay: TimeInterval = 0.25) -> Bool {
        for _ in 0..<max(1, retries) {
            if let source = inputMode(for: modeID), inputSourceSelected(for: source) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(delay))
        }
        guard let source = inputMode(for: modeID) else { return false }
        return inputSourceSelected(for: source)
    }
}
