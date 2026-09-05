import AppKit
import Foundation

extension SessionCtl {
    override func menu() -> NSMenu! {
        let menu = NSMenu(title: "全一輸入法 Menu")
        menu.addItem(makeMenuItem("偏好設定", action: #selector(handlePreferencesMenu(_:))))
        return menu
    }

    private func makeMenuItem(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func makeCandidateWindowMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "候選視窗", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "候選視窗")
        submenu.addItem(makeCandidateWindowModeItem(.basic))
        submenu.addItem(makeCandidateWindowModeItem(.detailed))
        item.submenu = submenu
        return item
    }

    private func makeCandidateEngineMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "選字引擎", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "選字引擎")
        submenu.addItem(makeCandidateEngineModeItem(.aiPreferredTraditionalAssist, action: #selector(handleCandidateEngineAIPreferredMenu(_:))))
        submenu.addItem(makeCandidateEngineModeItem(.traditionalPreferredAIAssist, action: #selector(handleCandidateEngineTraditionalPreferredMenu(_:))))
        submenu.addItem(makeCandidateEngineModeItem(.aiDecides, action: #selector(handleCandidateEngineAIDecidesMenu(_:))))
        submenu.addItem(makeCandidateEngineModeItem(.traditionalOnly, action: #selector(handleCandidateEngineTraditionalOnlyMenu(_:))))
        item.submenu = submenu
        return item
    }

    private func makeCandidateEngineModeItem(_ mode: CandidateEngineMode, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: mode.title, action: action, keyEquivalent: "")
        item.target = self
        item.state = currentCandidateEngineMode == mode ? .on : .off
        return item
    }

    private func makeCandidateWindowModeItem(_ mode: CandidateWindowMode) -> NSMenuItem {
        let item = NSMenuItem(title: mode.title, action: #selector(handleCandidateWindowMenu(_:)), keyEquivalent: "")
        item.target = self
        item.state = currentCandidateWindowMode == mode ? .on : .off
        item.representedObject = mode.rawValue
        return item
    }

    @objc
    private func handleInputMethodStatusMenu(_ sender: Any?) {
        NSLog("Input method status menu selected")
    }

    @objc
    private func handleCandidateWindowMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              let raw = item.representedObject as? String,
              let mode = CandidateWindowMode(rawValue: raw) else {
            return
        }
        currentCandidateWindowMode = mode
        if mode == .basic {
            CompositionPanelController.shared.hide()
        } else {
            BasicCandidatePanelController.shared.hide()
        }
        refreshMarkedTextIfPossible()
        showUserNotice(title: "全一輸入法", message: "候選視窗已切換為\(mode.title)")
        NSLog("Candidate window mode changed to %@", mode.rawValue)
    }

    private func applyCandidateEngineMode(_ mode: CandidateEngineMode, sender: Any?) {
        currentCandidateEngineMode = mode
        appendRuntimeTrace("candidateEngineMode.menu value=\(mode.rawValue)")
        if let item = sender as? NSMenuItem, let menu = item.menu {
            for sibling in menu.items {
                sibling.state = (sibling === item) ? .on : .off
            }
        }
        refreshMarkedTextIfPossible()
        showUserNotice(title: "全一輸入法", message: "選字引擎已切換為\(mode.title)")
        NSLog("Candidate engine mode changed to %@", mode.rawValue)
    }

    @objc
    private func handleCandidateEngineAIPreferredMenu(_ sender: Any?) {
        applyCandidateEngineMode(.aiPreferredTraditionalAssist, sender: sender)
    }

    @objc
    private func handleCandidateEngineTraditionalPreferredMenu(_ sender: Any?) {
        applyCandidateEngineMode(.traditionalPreferredAIAssist, sender: sender)
    }

    @objc
    private func handleCandidateEngineAIDecidesMenu(_ sender: Any?) {
        applyCandidateEngineMode(.aiDecides, sender: sender)
    }

    @objc
    private func handleCandidateEngineTraditionalOnlyMenu(_ sender: Any?) {
        applyCandidateEngineMode(.traditionalOnly, sender: sender)
    }

    @objc
    private func handleRetrainMenu(_ sender: Any?) {
        guard let retrainScriptURL else {
            showUserNotice(title: "全一輸入法", message: "重新訓練未啟動：找不到 retrain script。")
            NSLog("Retrain menu missing script")
            return
        }
        guard FileManager.default.fileExists(atPath: defaultTrainingOutputDir.path) else {
            showUserNotice(title: "全一輸入法", message: "重新訓練未啟動：找不到目前訓練輸出。")
            NSLog("Retrain menu missing output dir=%@", defaultTrainingOutputDir.path)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            retrainScriptURL.path,
            "--continue-from", defaultTrainingOutputDir.path,
            "--install",
        ]
        process.currentDirectoryURL = workspaceRootURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        do {
            try process.run()
            showUserNotice(title: "全一輸入法", message: "已開始重新訓練，會沿用目前權重續跑。")
            NSLog("Retrain menu launched continue-from=%@", defaultTrainingOutputDir.path)
        } catch {
            showUserNotice(title: "全一輸入法", message: "重新訓練啟動失敗：\(error.localizedDescription)")
            NSLog("Retrain menu failed: %@", error.localizedDescription)
        }
    }

    @objc
    private func handleInstallWeightsMenu(_ sender: Any?) {
        guard let installModelScriptURL else {
            showUserNotice(title: "全一輸入法", message: "更新權重失敗：找不到 install script。")
            NSLog("Install weights menu missing script")
            return
        }
        let candidateSources = [
            defaultTrainingOutputDir.appendingPathComponent("CandidateRanker.mlpackage"),
            defaultTrainingOutputDir.appendingPathComponent("CandidateRanker.mlmodel"),
            stableRuntimeModelURL,
        ].compactMap { $0 }
        guard let source = candidateSources.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            showUserNotice(title: "全一輸入法", message: "更新權重失敗：找不到可安裝的模型檔。")
            NSLog("Install weights menu missing source model")
            return
        }
        showUserNotice(title: "全一輸入法", message: "正在更新權重…")

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            process.arguments = [installModelScriptURL.path, source.path]
            process.currentDirectoryURL = workspaceRootURL ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            do {
                try process.run()
                process.waitUntilExit()
                let payload = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let lines = payload.split(separator: "\n").map(String.init)
                let kv = Dictionary(uniqueKeysWithValues: lines.compactMap { line -> (String, String)? in
                    guard let index = line.firstIndex(of: "=") else { return nil }
                    let key = String(line[..<index])
                    let value = String(line[line.index(after: index)...])
                    return (key, value)
                })
                DispatchQueue.main.async {
                    if process.terminationStatus == 0 {
                        let status = kv["status"] ?? "installed"
                        let sourcePath = kv["source_model"] ?? source.path
                        if status == "already_latest" {
                            showUserNotice(title: "全一輸入法", message: "權重已是最新：\n\(sourcePath)")
                        } else {
                            showUserNotice(title: "全一輸入法", message: "更新權重成功：\n\(sourcePath)")
                        }
                    } else {
                        let text = payload.trimmingCharacters(in: .whitespacesAndNewlines)
                        showUserNotice(title: "全一輸入法", message: "更新權重失敗：\n\(text.isEmpty ? source.path : text)")
                    }
                }
                NSLog("Install weights menu finished source=%@ status=%d output=%@", source.path, process.terminationStatus, payload)
            } catch {
                DispatchQueue.main.async {
                    showUserNotice(title: "全一輸入法", message: "更新權重啟動失敗：\(error.localizedDescription)")
                }
                NSLog("Install weights menu failed source=%@ error=%@", source.path, error.localizedDescription)
            }
        }
    }

    @objc
    private func handleOpenLogsMenu(_ sender: Any?) {}

    @objc
    private func handlePreferencesMenu(_ sender: Any?) {
        appendRuntimeTrace("preferences.menu open")
        PreferencesWindowController.shared.show()
    }

    @objc
    private func handleAboutMenu(_ sender: Any?) {}

    @objc
    private func handleQuitMenu(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}
