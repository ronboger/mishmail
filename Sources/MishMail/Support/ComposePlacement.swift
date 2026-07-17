import CoreGraphics
import Foundation

/// Where the compose UI mounts relative to the mailbox chrome.
enum ComposePresentation: String, Equatable {
    /// Bottom-right floating card (Gmail/Notion dock).
    case floating
    /// Docked at the bottom of the reading pane so the thread stays visible.
    case inline
}

/// Pure placement rules for compose — kept free of MailStore so tests can
/// cover reply-vs-forward without spinning up the app.
enum ComposePlacement {
    /// Prefer inline reply when the reading pane already shows this thread.
    /// New mail, forwards, and off-thread drafts stay floating.
    static func preferred(
        replyTo: Message?,
        editDraft: Message? = nil,
        forward: Bool,
        selectedThreadId: String?,
        readingPaneHidden: Bool
    ) -> ComposePresentation {
        if forward { return .floating }
        if readingPaneHidden { return .floating }
        let threadId = replyTo?.threadId ?? editDraft?.threadId
        guard let threadId, let selectedThreadId else { return .floating }
        return threadId == selectedThreadId ? .inline : .floating
    }

    /// Whether an open compose request should render in the given thread's
    /// reading pane (inline dock).
    static func showsInline(inThread threadId: String,
                            presentation: ComposePresentation,
                            replyTo: Message?,
                            editDraft: Message?) -> Bool {
        guard presentation == .inline else { return false }
        let composeThread = replyTo?.threadId ?? editDraft?.threadId
        return composeThread == threadId
    }

    /// Fall back to floating when the measured pane cannot show both the
    /// conversation and a usable inline composer.
    static func resolvedPresentation(_ preferred: ComposePresentation,
                                     paneHeight: CGFloat) -> ComposePresentation {
        guard preferred == .inline, paneHeight > 1 else { return preferred }
        return effectiveInlineCardHeight(paneHeight: paneHeight) > 0
            ? preferred
            : .floating
    }

    /// Preferred expanded inline compose card height (matches ContentView chrome).
    /// Tall enough for From/To/Subject + a usable body while the quote "…"
    /// pill and footer stay on-screen; reading-pane reserve tracks this.
    static let inlineCardHeight: CGFloat = 460
    /// Smallest comfortable composer, retained as a UX calibration constant.
    static let minComfortableInlineCardHeight: CGFloat = 320
    /// Conversation strip kept visible above a resized inline composer.
    static let minThreadVisibleHeight: CGFloat = 120
    /// Vertical padding under the inline card inside the host overlay.
    static let inlineBottomPadding: CGFloat = 12
    /// Horizontal inset from the reading-pane edges.
    static let inlineSidePadding: CGFloat = 12
    /// Scroll-safe area reserved under the thread so the last messages aren't
    /// covered by the overlay card (`card + bottom padding`).
    static var inlineReservedHeight: CGFloat {
        inlineCardHeight + inlineBottomPadding
    }

    /// Resize continuously with the pane instead of jumping between fixed
    /// height modes. A very short pane returns zero so the caller can float.
    static func effectiveInlineCardHeight(paneHeight: CGFloat) -> CGFloat {
        guard paneHeight > 1 else { return inlineCardHeight }
        let available = max(0, paneHeight - inlineBottomPadding)
        if available >= inlineCardHeight + minThreadVisibleHeight {
            return inlineCardHeight
        }
        guard available >= minThreadVisibleHeight else { return 0 }
        return available - minThreadVisibleHeight
    }

    /// Safe-area reserve matching the actual card. It remains zero until the
    /// pane is measured, avoiding a large first-frame inset that later snaps.
    static func inlineReservedHeight(paneHeight: CGFloat) -> CGFloat {
        guard paneHeight > 1 else { return 0 }
        let cardHeight = effectiveInlineCardHeight(paneHeight: paneHeight)
        guard cardHeight > 0 else { return 0 }
        return min(cardHeight + inlineBottomPadding, paneHeight)
    }

    /// Layout for pinning the inline card to the measured reading pane.
    /// Frames must share a coordinate space (typically `.global`).
    struct InlineMetrics: Equatable {
        /// Leading inset from the compose host's leading edge.
        var leading: CGFloat
        /// Card width inside the pane (after side padding).
        var width: CGFloat
    }

    /// Map host + reading-pane frames → leading inset and card width.
    /// Returns nil when either frame is still zero (layout not ready) so the
    /// caller can fall back to a layout-mode estimate.
    static func inlineMetrics(host: CGRect, pane: CGRect,
                              sidePadding: CGFloat = inlineSidePadding,
                              minWidth: CGFloat = 280) -> InlineMetrics? {
        guard host.width > 1, host.height > 1,
              pane.width > 1, pane.height > 1 else { return nil }
        let leading = max(0, pane.minX - host.minX) + sidePadding
        // Prefer the pane's own width so split-view chrome (sidebar/list)
        // never leaks under the card even if host includes them.
        let width = max(minWidth, pane.width - sidePadding * 2)
        return InlineMetrics(leading: leading, width: width)
    }

    /// Rough leading inset when PreferenceKey frames are not yet available.
    static func fallbackLeadingInset(layoutMode: MailLayoutMode) -> CGFloat {
        switch layoutMode {
        case .threadFocus: return inlineSidePadding
        case .threePane: return 240 + 480
        case .compactDetail, .list: return 220
        }
    }
}
