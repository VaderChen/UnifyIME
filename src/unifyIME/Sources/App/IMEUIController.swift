import AppKit
import InputMethodKit

protocol CandidateSelectionHandler: AnyObject {
    func didChooseCandidate(index: Int)
}

final class IMEUIController: NSObject, CandidateControllerDelegate {
    static let shared = IMEUIController()
    private let legacyCandidateControllerEnabled = false

    weak var selectionHandler: CandidateSelectionHandler?
    weak var activeClient: IMKTextInput?

    private var composingText = ""
    private var candidateEntries: [CandidateEntry] = []
    private var focusedReading: String?
    private(set) var selectedCandidateIndex = 0

    private var candidates: [String] {
        candidateEntries.map(\.text)
    }

    func activate(client: Any!, selectionHandler: CandidateSelectionHandler) {
        self.activeClient = client as? IMKTextInput
        self.selectionHandler = selectionHandler
        guard legacyCandidateControllerEnabled else { return }
    }

    func deactivate() {
        activeClient = nil
        selectionHandler = nil
        clear()
    }

    func clear() {
        composingText = ""
        candidateEntries = []
        focusedReading = nil
        selectedCandidateIndex = 0
        guard legacyCandidateControllerEnabled else { return }
        gCurrentCandidateController?.delegate = nil
        // Diagnostics: keep legacy candidate controller from being force-hidden here
        // while tracing who dismisses the basic candidate window unexpectedly.
        // gCurrentCandidateController?.visible = false
    }

    func update(composingText: String, candidateEntries: [CandidateEntry], selectedIndex: Int, focusedReading: String?, anchor: CGPoint?) {
        self.composingText = composingText
        self.candidateEntries = candidateEntries
        self.focusedReading = focusedReading
        self.selectedCandidateIndex = max(0, min(selectedIndex, max(candidateEntries.count - 1, 0)))
        guard legacyCandidateControllerEnabled else { return }
        guard !candidateEntries.isEmpty else {
            // Diagnostics: suspend legacy force-hide path.
            // gCurrentCandidateController?.visible = false
            return
        }
        if gCurrentCandidateController == nil {
            gCurrentCandidateController = CandidateController.preferred
            gCurrentCandidateController?.delegate = self
        }
        gCurrentCandidateController?.delegate = self
        gCurrentCandidateController?.selectedCandidateIndex = UInt(self.selectedCandidateIndex)
        if let controller = gCurrentCandidateController, let anchor {
            controller.windowTopLeftPoint = NSPoint(x: anchor.x, y: anchor.y + 22)
            controller.visible = true
        } else {
            // Diagnostics: suspend legacy force-hide path.
            // gCurrentCandidateController?.visible = false
        }
    }

    func highlightPrevious() -> Bool {
        guard legacyCandidateControllerEnabled else { return false }
        guard !candidates.isEmpty else { return false }
        if selectedCandidateIndex > 0 {
            selectedCandidateIndex -= 1
            return true
        }
        return false
    }

    func highlightNext() -> Bool {
        guard legacyCandidateControllerEnabled else { return false }
        guard !candidates.isEmpty else { return false }
        if selectedCandidateIndex + 1 < candidates.count {
            selectedCandidateIndex += 1
            return true
        }
        return false
    }

    func candidateCountForController(_ controller: CandidateController) -> UInt {
        guard legacyCandidateControllerEnabled else { return 0 }
        return UInt(candidates.count)
    }

    func candidateController(_ controller: CandidateController, candidateAtIndex index: UInt) -> String {
        guard legacyCandidateControllerEnabled else { return "" }
        guard candidates.indices.contains(Int(index)) else { return "" }
        return candidates[Int(index)]
    }

    func candidateController(_ controller: CandidateController, readingAtIndex index: UInt) -> String? {
        guard legacyCandidateControllerEnabled else { return nil }
        return focusedReading
    }

    func candidateController(_ controller: CandidateController, requestExplanationFor candidate: String, reading: String) -> String? {
        guard legacyCandidateControllerEnabled else { return nil }
        return nil
    }

    func candidateController(_ controller: CandidateController, didSelectCandidateAtIndex index: UInt) {
        guard legacyCandidateControllerEnabled else { return }
        selectedCandidateIndex = Int(index)
        selectionHandler?.didChooseCandidate(index: Int(index))
    }
}
