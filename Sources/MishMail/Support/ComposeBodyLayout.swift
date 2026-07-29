import CoreGraphics
import Foundation

/// Body-editor height for compose when the quoted original is collapsed.
///
/// Short replies used a fixed 180pt floor even for two-line drafts, so the
/// Gmail-style "…" pill sat in a large empty void under the text. Size the
/// editor to authored content (modest empty-body floor, content+slack when
/// typing) so the pill sits just under the last line; the card's trailing
/// Spacer still absorbs leftover chrome below the pill.
enum ComposeBodyLayout {
    /// 14pt body font + ~5pt line spacing.
    static let lineHeight: CGFloat = 19
    /// Top/bottom padding around the first/last line fragment in the editor.
    static let editorPadding: CGFloat = 16
    /// Card is ~620pt wide with ~14pt chrome; ~72 chars fit at 14pt.
    static let charsPerLine = 72
    /// Breathing room under the last line before the "…" pill.
    static let contentSlack: CGFloat = 8
    /// Empty reply still needs a real writing surface (≈4–5 lines).
    static let emptyFloor: CGFloat = 100
    /// Defensive floor for non-empty bodies (at least ~one line + padding).
    static let nonEmptyFloor: CGFloat = 40
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
    /// - Empty body + quote: fixed `emptyFloor` writing surface.
    /// - Authored body + quote: content height + slack, capped (hugs text so
    ///   "…" sits under the last line instead of mid-void).
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
        if isBodyEmpty(body) {
            return (emptyFloor, emptyFloor)
        }
        let h = min(max(contentHeight(body: body) + contentSlack, nonEmptyFloor),
                    collapsedCap)
        return (h, h)
    }
}
