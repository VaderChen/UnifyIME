import AppKit
import Carbon
import InputMethodKit
final class NativeProbeClient: NSObject, IMKTextInput {
 var inserted: [String] = []
 func insertText(_ text: Any?, replacementRange: NSRange) { inserted.append((text as? NSAttributedString)?.string ?? text as? String ?? "") }
 func setMarkedText(_ text: Any?, selectionRange: NSRange, replacementRange: NSRange) {}
 func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
 func markedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
 func attributedSubstring(from range: NSRange) -> NSAttributedString? { nil }
 func length() -> Int { inserted.joined().utf16.count }
 func characterIndex(for point: NSPoint, tracking mode: IMKLocationToOffsetMappingMode, inMarkedRange: UnsafeMutablePointer<ObjCBool>?) -> Int { 0 }
 func attributes(forCharacterIndex index: Int, lineHeightRectangle: UnsafeMutablePointer<NSRect>?) -> [AnyHashable: Any]? { [:] }
 func validAttributesForMarkedText() -> [Any]? { [] }
 func overrideKeyboard(withKeyboardNamed name: String?) {}
 func selectMode(_ identifier: String?) {}
 func supportsUnicode() -> Bool { true }
 func bundleIdentifier() -> String? { "local.fastchime.lifecycle-probe" }
 func windowLevel() -> CGWindowLevel { 0 }
 func supportsProperty(_ property: TSMDocumentPropertyTag) -> Bool { false }
 func uniqueClientIdentifierString() -> String? { "native-lifecycle-probe" }
 func string(from range: NSRange, actualRange: NSRangePointer?) -> String? { nil }
 func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
}
