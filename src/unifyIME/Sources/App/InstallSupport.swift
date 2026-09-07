import Foundation

private func declaredInputModeIDs(in bundle: Bundle) -> [String] {
    guard let component = bundle.object(forInfoDictionaryKey: "ComponentInputModeDict") as? [String: Any],
          let modeList = component["tsInputModeListKey"] as? [String: Any] else {
        return []
    }
    return modeList.keys.sorted()
}

func installInputMethod() -> Int32 {
    guard let bundleID = Bundle.main.bundleIdentifier else {
        NSLog("Missing bundle identifier.")
        return 1
    }
    let bundleURL = Bundle.main.bundleURL
    let modeIDs = declaredInputModeIDs(in: Bundle.main)
    guard let primaryModeID = modeIDs.first else {
        NSLog("No input mode declared in %@.", bundleURL.path)
        return 1
    }

    if InputSourceHelper.inputMode(for: primaryModeID) == nil {
        NSLog("Registering input source %@ at %@", bundleID, bundleURL.absoluteString)
        guard InputSourceHelper.registerInputSource(at: bundleURL) else {
            NSLog("Cannot register input source %@.", bundleID)
            return 1
        }
    }

    for modeID in modeIDs {
        guard let source = InputSourceHelper.inputMode(for: modeID) else {
            NSLog("Cannot find input mode %@ after registration.", modeID)
            return 1
        }
        NSLog("Enabling input mode %@.", modeID)
        guard InputSourceHelper.enable(inputSource: source) else {
            NSLog("Cannot enable input mode %@.", modeID)
            return 1
        }
        guard InputSourceHelper.waitUntilInputModeEnabled(modeID) else {
            NSLog("Input mode %@ still not enabled.", modeID)
            return 2
        }
    }

    guard let primaryMode = InputSourceHelper.inputMode(for: primaryModeID) else {
        NSLog("Cannot find primary input mode %@.", primaryModeID)
        return 1
    }
    NSLog("Selecting input mode %@.", primaryModeID)
    guard InputSourceHelper.select(inputSource: primaryMode) else {
        NSLog("Cannot select input mode %@.", primaryModeID)
        return 1
    }
    let selected = InputSourceHelper.waitUntilInputModeSelected(primaryModeID)
    NSLog(selected ? "Input mode %@ enabled and selected." : "Input mode %@ enabled but not selected.", primaryModeID)
    return selected ? 0 : 2
}
