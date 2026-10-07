import AppKit
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
    /// New mail / expanded quote: flex min; max hugs content so the "…"
    /// pill sits under the last line instead of the card bottom.
    static let noQuoteMin: CGFloat = 120

    /// Editor height for the laid-out text, as measured by the text view.
    /// Preferred over `contentHeight(body:)`, whose fixed line height and
    /// characters-per-line ignore the font scale and the real card width —
    /// at a larger font the estimate came out short and the last lines
    /// scrolled out of view inside a card that still had room.
    static func contentHeight(measuredTextHeight: CGFloat) -> CGFloat {
        editorPadding + measuredTextHeight.rounded(.up)
    }

    /// Height of the text as `textView` lays it out at its current width
    /// and font, or nil before the view has a real width.
    static func textHeight(of textView: NSTextView) -> CGFloat? {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              // Before the first real layout the container is 0 wide and
              // every character wraps onto its own line.
              textView.bounds.width > 1 else { return nil }
        lm.ensureLayout(for: tc)
        var used = lm.usedRect(for: tc)
        if lm.extraLineFragmentUsedRect.height > 0 {
            used = used.union(lm.extraLineFragmentUsedRect)
        }
        return used.maxY + textView.textContainerInset.height * 2
    }

    /// Estimated editor height for `body` (no floor/cap). Used only until
    /// the text view reports its first measurement.
    static func contentHeight(body: String) -> CGFloat {
        var visualLines: CGFloat = 0
        for line in body.components(separatedBy: "\n") {
            let len = max(line.count, 1)
            visualLines += CGFloat((len + charsPerLine - 1) / charsPerLine)
        }
        if visualLines < 1 { visualLines = 1 }
        return editorPadding + visualLines * lineHeight
    }

    /// `(minHeight, maxHeight)` for the body editor's SwiftUI frame.
    ///
    /// - No collapsed quote: min `noQuoteMin`, max content + slack (hug);
    ///   the editor's NSScrollView scrolls when the card is shorter.
    /// - Slash picker open: fixed low band so the match list keeps height.
    /// - Empty / short body + quote: min == max == `emptyFloor` (usable
    ///   surface, no first-keystroke snap).
    /// - Longer authored body + quote: max hugs content (capped); min stays
    ///   at `emptyFloor` so the fixed-height compose card can compress the
    ///   editor and keep the "…" pill + Send footer on-screen (NSTextView
    ///   scrolls internally).
    static func editorHeights(body: String,
                              hasCollapsedQuote: Bool,
                              slashActive: Bool,
                              collapsedQuoteCap: CGFloat = collapsedCap,
                              measuredTextHeight: CGFloat? = nil)
        -> (min: CGFloat, max: CGFloat) {
        let content = measuredTextHeight.map(contentHeight(measuredTextHeight:))
            ?? contentHeight(body: body)
        guard hasCollapsedQuote else {
            // Cap at content so an inlined quote's collapse pill hugs the
            // last line; floor at noQuoteMin so empty drafts keep a surface.
            let maxH = max(noQuoteMin, content + contentSlack)
            return (noQuoteMin, maxH)
        }
        if slashActive {
            return (slashFloor, slashCap)
        }
        // Max: content + slack, floored at emptyFloor and capped so long
        // drafts hug then scroll. Min: compressible down to emptyFloor so a
        // fixed card (addresses + long body) never clips the quote pill /
        // Send row; short drafts keep min == max == emptyFloor (no snap).
        let raw = content + contentSlack
        let h = min(max(raw, emptyFloor), collapsedQuoteCap)
        return (Swift.min(h, emptyFloor), h)
    }
}

