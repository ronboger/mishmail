import AppKit
import WebKit
import XCTest

/// Regression: `g i` (and every other Gmail single-key shortcut) died inside a
/// full-window conversation because the key monitor treated *any* text control
/// holding first responder as "the user is typing". SwiftUI renders
/// `Text(…).textSelection(.enabled)` as a selectable, non-editable
/// `NSTextField`, and a conversation is made of them — so reading an email was
/// enough to disarm the shortcuts.
final class TextFocusTests: XCTestCase {
    func testSelectableButReadOnlyTextDoesNotCountAsEditing() {
        // How SwiftUI backs `Text(...).textSelection(.enabled)`.
        let label = NSTextField(labelWithString: "Subject line")
        label.isSelectable = true
        XCTAssertFalse(label.isEditable, "precondition: a label is not editable")
        XCTAssertFalse(TextFocus.isEditing(label),
                       "selectable conversation text must not disarm shortcuts")
    }

    func testReadOnlyTextViewDoesNotCountAsEditing() {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        XCTAssertFalse(TextFocus.isEditing(textView),
                       "read-only text views must not disarm shortcuts")
    }

    func testEditableFieldStillCountsAsEditing() {
        // Sidebar search / label-picker query / compose headers.
        let field = NSTextField(string: "")
        XCTAssertTrue(field.isEditable, "precondition: a plain field is editable")
        XCTAssertTrue(TextFocus.isEditing(field))
    }

    func testEditableTextViewStillCountsAsEditing() {
        // Compose body, template editor — and the field editor an editable
        // NSTextField installs when it takes first responder.
        let textView = NSTextView(frame: .zero)
        textView.isEditable = true
        XCTAssertTrue(TextFocus.isEditing(textView))
    }

    func testNonTextResponderIsNeverEditing() {
        XCTAssertFalse(TextFocus.isEditing(nil))
        XCTAssertFalse(TextFocus.isEditing(NSView(frame: .zero)))
        XCTAssertFalse(TextFocus.isEditing(NSWindow()))
    }

    // MARK: - ⌘A ownership

    /// Regression: ⌘A select-all-threads must not fire while focus sits on
    /// text the user can select. `isEditing` is the wrong test here — it is
    /// deliberately false for the selectable, read-only labels a conversation
    /// is built from, so ⌘A would have stolen "select the whole message".
    func testSelectableButReadOnlyTextOwnsSelectAll() {
        let label = NSTextField(labelWithString: "Subject line")
        label.isSelectable = true
        XCTAssertFalse(TextFocus.isEditing(label),
                       "precondition: selectable read-only text is not editing")
        XCTAssertTrue(TextFocus.ownsSelectAll(label),
                      "⌘A in selectable conversation text must select the text")
    }

    func testSelectableTextViewOwnsSelectAll() {
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        XCTAssertTrue(TextFocus.ownsSelectAll(textView))
    }

    func testEditableFieldOwnsSelectAll() {
        // Search, compose headers, label-picker query.
        XCTAssertTrue(TextFocus.ownsSelectAll(NSTextField(string: "")))
    }

    /// The HTML body renderer. WebKit answers ⌘A itself, so the chord must
    /// reach it instead of checking every thread in the list.
    func testWebViewOwnsSelectAll() {
        XCTAssertTrue(TextFocus.ownsSelectAll(WKWebView(frame: .zero)))
    }

    /// WebKit parks first responder on a private view *inside* the web view,
    /// so matching only the `WKWebView` itself would miss the real case.
    func testViewInsideAWebViewOwnsSelectAll() {
        let webView = WKWebView(frame: .zero)
        let inner = NSView(frame: .zero)
        webView.addSubview(inner)
        XCTAssertTrue(TextFocus.ownsSelectAll(inner))
    }

    /// The thread list: no selectable text, no web view — ⌘A belongs to
    /// select-all-threads.
    func testPlainViewHierarchyDoesNotOwnSelectAll() {
        let parent = NSView(frame: .zero)
        let child = NSView(frame: .zero)
        parent.addSubview(child)
        XCTAssertFalse(TextFocus.ownsSelectAll(child))
        XCTAssertFalse(TextFocus.ownsSelectAll(nil))
        XCTAssertFalse(TextFocus.ownsSelectAll(NSWindow()))
    }

    /// A plain label is not selectable, so it never claims the chord.
    func testNonSelectableLabelDoesNotOwnSelectAll() {
        let label = NSTextField(labelWithString: "Sender")
        XCTAssertFalse(label.isSelectable, "precondition: labels start read-only")
        XCTAssertFalse(TextFocus.ownsSelectAll(label))
    }
}
