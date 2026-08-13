import AppKit
import WebKit

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

    /// `true` when the first responder already owns ⌘A, so the mailbox
    /// select-all chord must stand down and let the responder chain answer.
    ///
    /// Deliberately wider than `isEditing`. Bare mailbox keys only have to
    /// yield to *typing*, but ⌘A is the standard "select all text" chord and
    /// every control that can hold a text selection answers it — including
    /// the selectable, non-editable `NSTextField`s SwiftUI makes from
    /// `Text(…).textSelection(.enabled)`, which `isEditing` reports as *not*
    /// typing on purpose (see above). Reusing `isEditing` here would steal
    /// ⌘A the moment focus lands in a conversation, breaking "select the
    /// whole message, copy it" — the only thing ⌘A means once you are
    /// reading rather than triaging.
    ///
    /// The thread list holds no selectable text and no web view, so ⌘A still
    /// reaches select-all-threads from the list, which is where it is aimed.
    static func ownsSelectAll(_ responder: NSResponder?) -> Bool {
        switch responder {
        case let textView as NSTextView: return textView.isSelectable
        case let field as NSTextField: return field.isSelectable
        default: break
        }
        // HTML bodies render into a `WKWebView`, and WebKit parks first
        // responder on a private view *inside* it — so match the whole
        // subtree, not just the web view itself.
        var view = responder as? NSView
        while let current = view {
            if current is WKWebView { return true }
            view = current.superview
        }
        return false
    }
}
