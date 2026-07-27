import AppKit
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
}
