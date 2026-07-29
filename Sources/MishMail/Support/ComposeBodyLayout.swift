import CoreGraphics
import Foundation

/// Body-editor height for compose when the quoted original is collapsed.
///
/// Short replies used a fixed 180pt floor even for two-line drafts, so the
/// Gmail-style "…" pill sat in a large empty void under the text. Size the
/// editor to authored content once it exceeds a modest floor (and keep that
/// floor for empty / short drafts so the first keystroke doesn't snap the
/// frame). The card's trailing Spacer still absorbs leftover chrome below
/// the pill.
enum ComposeBodyLayout {
    /// 14pt body font + ~5pt line spacing.
    static let lineHeight: CGFloat = 19
    /// Top/bottom padding around the first/last line fragment in the editor.
    static let editorPadding: CGFloat = 16
    /// Card is ~620pt wide with ~14pt chrome; ~72 chars fit at 14pt.
    static let charsPerLine = 72
    /// Breathing room under the last line before the "…" pill (non-empty).
    static let contentSlack: CGFloat = 8
    /// Floor for empty *and* short drafts (≈4–5 lines). Also the empty-body
    /// writing surface — non-empty bodies stay at least this tall until
    /// content + slack exceeds it, so first keystroke / last delete never
    /// jump the frame (100 → 43 → 100).
    static let emptyFloor: CGFloat = 100
    /// Cap keeps footer + "…" on-screen for long drafts in a fixed card.
    static let collapsedCap: CGFloat = 320
    /// Slash-active floors/caps leave room for the match list.
    static let slashFloor: CGFloat = 72
    static let slashCap: CGFloat = 160
    /// New mail / expanded quote: flex min only (max is unbounded).
    static let noQuoteMin: CGFloat = 120

    /// Estimated editor height for `body` (no floor/cap).
    static func contentHeight(body: String) -> CGFloat {
        var visualLines: CGFloat = 0
        for line in body.components(separatedBy: "\n") {
            let len = max(line.count, 1)
            visualLines += CGFloat((len + charsPerLine - 1) / charsPerLine)
        }
        if visualLines < 1 { visualLines = 1 }
        return editorPadding + visualLines * lineHeight
    }

    static func isBodyEmpty(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `(minHeight, maxHeight)` for the body editor's SwiftUI frame.
    ///
    /// - No collapsed quote: min `noQuoteMin`, max unbounded (flex with card).
    /// - Slash picker open: fixed low band so the match list keeps height.
    /// - Empty / short body + quote: at least `emptyFloor` (usable surface,
    ///   no first-keystroke snap).
    /// - Longer authored body + quote: content height + slack, capped.
    static func editorHeights(body: String,
                              hasCollapsedQuote: Bool,
                              slashActive: Bool)
        -> (min: CGFloat, max: CGFloat) {
        guard hasCollapsedQuote else {
            return (noQuoteMin, .infinity)
        }
        if slashActive {
            return (slashFloor, slashCap)
        }
        let raw: CGFloat
        if isBodyEmpty(body) {
            raw = emptyFloor
        } else {
            raw = contentHeight(body: body) + contentSlack
        }
        // Floor at emptyFloor so empty ↔ one-char never jumps; hug once
        // content grows past the writing surface.
        let h = min(max(raw, emptyFloor), collapsedCap)
        return (h, h)
    }
}
