import AppKit

final class TrainingProgressWindowController: NSWindowController {
    private final class ConvergenceChartView: NSView {
        var epochs: [[String: Any]] = [] {
            didSet { needsDisplay = true }
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()

            let inset: CGFloat = 12
            let plot = bounds.insetBy(dx: inset, dy: inset)
            guard plot.width > 40, plot.height > 40 else { return }

            let border = NSBezierPath(roundedRect: plot, xRadius: 8, yRadius: 8)
            NSColor.separatorColor.setStroke()
            border.lineWidth = 1
            border.stroke()

            guard !epochs.isEmpty else { return }

            var top1Points: [CGFloat] = []
            var mrrPoints: [CGFloat] = []
            var lossPoints: [CGFloat] = []
            for row in epochs {
                if let valid = row["valid"] as? [String: Any] {
                    top1Points.append(CGFloat(valid["top1"] as? Double ?? 0))
                    mrrPoints.append(CGFloat(valid["mrr"] as? Double ?? 0))
                    lossPoints.append(CGFloat(valid["loss"] as? Double ?? 0))
                }
            }
            guard !top1Points.isEmpty else { return }

            let maxLoss = max(lossPoints.max() ?? 1, 0.0001)
            drawSeries(values: top1Points, in: plot, maxValue: 1, color: .systemBlue)
            drawSeries(values: mrrPoints, in: plot, maxValue: 1, color: .systemGreen)
            drawSeries(values: lossPoints, in: plot, maxValue: maxLoss, color: .systemOrange, invert: true)

            let legend = [
                ("Top1", NSColor.systemBlue),
                ("MRR", NSColor.systemGreen),
                ("Loss", NSColor.systemOrange),
            ]
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            for (index, item) in legend.enumerated() {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: item.1,
                    .paragraphStyle: paragraph,
                ]
                let rect = NSRect(x: plot.minX + CGFloat(index) * 64, y: plot.minY + 4, width: 60, height: 14)
                item.0.draw(in: rect, withAttributes: attrs)
            }
        }

        private func drawSeries(values: [CGFloat], in rect: NSRect, maxValue: CGFloat, color: NSColor, invert: Bool = false) {
            guard values.count >= 2 else { return }
            let path = NSBezierPath()
            path.lineWidth = 2
            for (index, value) in values.enumerated() {
                let x = rect.minX + (rect.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)))
                let normalized = maxValue > 0 ? min(max(value / maxValue, 0), 1) : 0
                let yRatio = invert ? normalized : (1 - normalized)
                let y = rect.minY + rect.height * yRatio
                let point = NSPoint(x: x, y: y)
                if index == 0 {
                    path.move(to: point)
                } else {
                    path.line(to: point)
                }
            }
            color.setStroke()
            path.stroke()
        }
    }

    private let outputDir: URL
    private let summaryLabel = NSTextField(labelWithString: "等待訓練進度…")
    private let progressBar = NSProgressIndicator(frame: .zero)
    private let chartView = ConvergenceChartView(frame: .zero)
    private let textView = NSTextView(frame: .zero)
    private let pauseButton = NSButton(title: "暫停", target: nil, action: nil)
    private let stopButton = NSButton(title: "停止", target: nil, action: nil)
    private var timer: Timer?

    init(outputDir: URL) {
        self.outputDir = outputDir

        let rect = NSRect(x: 0, y: 0, width: 620, height: 520)
        let window = NSWindow(
            contentRect: rect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "全一輸入法 Training"
        window.isReleasedWhenClosed = false
        window.level = .floating

        let content = NSView(frame: rect)
        content.autoresizingMask = [.width, .height]

        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 100
        progressBar.controlSize = .regular
        progressBar.frame = NSRect(x: 20, y: 18, width: 580, height: 16)
        content.addSubview(progressBar)

        summaryLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        summaryLabel.frame = NSRect(x: 20, y: 42, width: 360, height: 22)
        content.addSubview(summaryLabel)

        pauseButton.frame = NSRect(x: 412, y: 38, width: 88, height: 28)
        pauseButton.bezelStyle = .rounded
        content.addSubview(pauseButton)

        stopButton.frame = NSRect(x: 512, y: 38, width: 88, height: 28)
        stopButton.bezelStyle = .rounded
        content.addSubview(stopButton)

        chartView.frame = NSRect(x: 20, y: 76, width: 580, height: 180)
        chartView.wantsLayer = true
        chartView.layer?.cornerRadius = 10
        chartView.layer?.borderWidth = 1
        chartView.layer?.borderColor = NSColor.separatorColor.cgColor
        content.addSubview(chartView)

        let scrollView = NSScrollView(frame: NSRect(x: 20, y: 270, width: 580, height: 220))
        scrollView.hasVerticalScroller = true
        scrollView.scrollerStyle = .overlay
        scrollView.autoresizingMask = [.width, .height]

        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.string = "等待訓練進度…"
        scrollView.documentView = textView
        content.addSubview(scrollView)
        window.contentView = content

        super.init(window: window)
        pauseButton.target = self
        pauseButton.action = #selector(handlePause(_:))
        stopButton.target = self
        stopButton.action = #selector(handleStop(_:))
        window.setFrameOrigin(NSPoint(x: 80, y: 520))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        refresh()
        window?.orderFrontRegardless()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let progress = readJSON(named: "training_progress.json")
        let partial = readJSON(named: "metrics.partial.json")
        let final = readJSON(named: "metrics.json")
        let progressPercent: Double = {
            guard let progress else { return 0 }
            let trained = progress["trained_estimators"] as? Int ?? 0
            let target = progress["target_estimators"] as? Int ?? 0
            return progress["progress_percent"] as? Double ?? (target > 0 ? (Double(trained) / Double(target)) * 100.0 : 0.0)
        }()
        let trainingInProgress = progress != nil && progressPercent < 100
        let status = (progress?["status"] as? String) ?? (partial?["status"] as? String) ?? (final?["status"] as? String) ?? (trainingInProgress ? "running" : "idle")

        var lines: [String] = []
        lines.append("輸出目錄：")
        lines.append(outputDir.path)
        lines.append("")

        if let progress {
            let trained = progress["trained_estimators"] as? Int ?? 0
            let target = progress["target_estimators"] as? Int ?? 0
            let percent = progressPercent
            let batch = progress["batch_size"] as? Int ?? 0
            let bestEpoch = progress["best_epoch"] as? Int ?? 0
            let validTop1 = progress["last_valid_top1"] as? Double ?? 0
            let validMRR = progress["last_valid_mrr"] as? Double ?? 0
            let device = progress["device"] as? String
            let phase = progress["phase"] as? String ?? ""
            let phaseMessage = progress["phase_message"] as? String ?? ""
            summaryLabel.stringValue = String(format: "訓練中：%06.2f%%  (%d / %d)", percent, trained, target)
            progressBar.doubleValue = percent
            lines.append(String(format: "進度：%d / %d (%06.2f%%)", trained, target, percent))
            lines.append("batch：\(batch)")
            if let device, !device.isEmpty {
                lines.append("裝置：\(device)")
            }
            if !phase.isEmpty {
                lines.append("階段：\(phase)")
            }
            if !phaseMessage.isEmpty {
                lines.append("說明：\(phaseMessage)")
            }
            lines.append("狀態：\(status)")
            lines.append(String(format: "目前 valid top1：%.4f", validTop1))
            lines.append(String(format: "目前 valid MRR：%.4f", validMRR))
            lines.append("最佳 epoch：\(bestEpoch)")
            lines.append("")
        }

        if let partial {
            lines.append("中間指標：")
            appendMetricBlock(from: partial, into: &lines)
            if let epochs = partial["epochs"] as? [[String: Any]] {
                chartView.epochs = epochs
            }
        }

        if let final, !trainingInProgress {
            lines.append("")
            lines.append("已完成：")
            appendMetricBlock(from: final, into: &lines)
            if status == "paused" {
                summaryLabel.stringValue = "訓練已暫停"
            } else if status == "stopped" {
                summaryLabel.stringValue = "訓練已停止"
            } else {
                summaryLabel.stringValue = "訓練完成"
                progressBar.doubleValue = 100
            }
            if let epochs = final["epochs"] as? [[String: Any]] {
                chartView.epochs = epochs
            }
            if status != "running" {
                timer?.invalidate()
                timer = nil
            }
        }

        if partial == nil && final == nil {
            summaryLabel.stringValue = "等待訓練進度…"
            progressBar.doubleValue = 0
        }

        let canControl = status == "running" || trainingInProgress
        pauseButton.isEnabled = canControl
        stopButton.isEnabled = canControl

        textView.string = lines.joined(separator: "\n")
    }

    private func appendMetricBlock(from payload: [String: Any], into lines: inout [String]) {
        if let backend = payload["backend_effective"] as? String {
            lines.append("backend：\(backend)")
        }
        if let bestEpoch = payload["best_epoch"] {
            lines.append("best epoch：\(bestEpoch)")
        }
        if let valid = payload["valid"] as? [String: Any] {
            let top1 = valid["top1"] as? Double ?? 0
            let mrr = valid["mrr"] as? Double ?? 0
            let loss = valid["loss"] as? Double ?? 0
            lines.append(String(format: "valid loss：%.4f", loss))
            lines.append(String(format: "valid top1：%.4f", top1))
            lines.append(String(format: "valid MRR：%.4f", mrr))
        }
        if let test = payload["test"] as? [String: Any] {
            let top1 = test["top1"] as? Double ?? 0
            let mrr = test["mrr"] as? Double ?? 0
            let loss = test["loss"] as? Double ?? 0
            lines.append(String(format: "test loss：%.4f", loss))
            lines.append(String(format: "test top1：%.4f", top1))
            lines.append(String(format: "test MRR：%.4f", mrr))
        }
    }

    private func readJSON(named name: String) -> [String: Any]? {
        let url = outputDir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    @objc
    private func handlePause(_ sender: Any?) {
        writeControl(action: "pause")
        summaryLabel.stringValue = "已送出暫停請求，等待儲存中…"
        pauseButton.isEnabled = false
        stopButton.isEnabled = false
    }

    @objc
    private func handleStop(_ sender: Any?) {
        writeControl(action: "stop")
        summaryLabel.stringValue = "已送出停止請求，等待儲存中…"
        pauseButton.isEnabled = false
        stopButton.isEnabled = false
        timer?.invalidate()
        timer = nil
        window?.performClose(nil)
    }

    private func writeControl(action: String) {
        let url = outputDir.appendingPathComponent("training_control.json")
        let payload: [String: Any] = [
            "action": action,
            "requested_at": ISO8601DateFormatter().string(from: Date()),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) else {
            return
        }
        try? data.write(to: url)
    }
}
