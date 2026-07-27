import AppKit

/// Does the window's first responder mean "the user is typing"?
///
/// Mailbox single-key shortcuts (`g i`, `j`, `k`, `e`, …) must stand down
/// while a field owns the keyboard. The trap is that *read-only* text
/// controls become first responder too: SwiftUI renders
/// `Text(…).textSelection(.enabled)` as a **selectable, non-editable**
/// `NSTextField`, and a conversation is built out of them (subject, header
/// rows, plain-text bodies). A blanket `is NSTextField` / `is NSTextView`
/// test therefore reads "user is typing" the moment focus lands on selectable
/// text, and every Gmail-style key dies.
///
/// That bites hardest in full-window (Superhuman-style) conversations: the
/// conversation *is* the window, so there is no thread list left to hold
/// first responder, and any click to read or select text parks focus on
/// selectable text for good. `g i` then had no way back to the inbox.
///
/// Editability is the signal that actually means "these keys belong to the
/// text system". An editable `NSTextField` hands first responder to its field
/// editor — an editable `NSTextView` — so checking `isEditable` on both
/// classes still covers real typing in search, compose, and the label picker.
enum TextFocus {
    /// `true` only when `responder` is a text control the user can type into.
    static func isEditing(_ responder: NSResponder?) -> Bool {
        switch responder {
        case let textView as NSTextView: return textView.isEditable
        case let field as NSTextField: return field.isEditable
        default: return false
        }
    }
}
