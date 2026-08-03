import CoreGraphics
import Foundation

/// Where the compose UI mounts relative to the mailbox chrome.
enum ComposePresentation: String, Equatable {
    /// Bottom-right floating card (Gmail/Notion dock).
    case floating
    /// Docked at the bottom of the reading pane so the thread stays visible.
    case inline
    /// Full-window side by side: the source conversation fills the left
    /// column, the draft the right. Entered from a thread-bound compose
    /// (reply / forward / reopened reply draft) via ⇧⌘↩ or the header button.
    case split
    /// Reading-pane fill: elevated compose card that claims an empty detail
    /// column (Superhuman-style primary surface, Gmail card chrome). Derived
    /// at layout time from floating when the pane has no conversation — never
    /// stored on `ComposeRequest` and never the preferred placement for an
    /// in-thread reply.
    case pane
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

    /// Resolve the on-screen presentation from a preferred placement plus
    /// live layout.
    ///
    /// - Inline demotes to floating when the pane is too short for a usable
    ///   dock + thread strip.
    /// - Floating promotes to pane fill when the reading pane is empty and
    ///   large enough to host a real writing surface (empty-pane autoexpand).
    /// - Replies stay `.inline` and never become `.pane` — the thread remains
    ///   the primary surface.
    /// - Split is never demoted by pane metrics (it owns the window).
    static func resolvedPresentation(
        _ preferred: ComposePresentation,
        paneHeight: CGFloat,
        readingPaneEmpty: Bool = false,
        paneWidth: CGFloat = 0
    ) -> ComposePresentation {
        switch preferred {
        case .split:
            return preferred
        case .inline:
            guard paneHeight > 1 else { return preferred }
            return effectiveInlineCardHeight(paneHeight: paneHeight) > 0
                ? preferred
                : .floating
        case .floating, .pane:
            // `.pane` is derived-only (never stored on ComposeRequest). If a
            // caller ever persisted it, demote when the pane is no longer empty.
            guard readingPaneEmpty,
                  shouldPaneFill(paneHeight: paneHeight, paneWidth: paneWidth)
            else { return .floating }
            return .pane
        }
    }

    /// Whether the detail column is mounted and idle (no open conversation).
    ///
    /// Pane fill only makes sense in three-pane layout: `.list` /
    /// `.threadFocus` have no detail column, and `.compactDetail` always has
    /// an open conversation. Do not rely on PreferenceKey frames alone —
    /// stale frames can linger after the detail column unmounts.
    static func readingPaneIsEmpty(
        layoutMode: MailLayoutMode,
        openedThreadId: String?
    ) -> Bool {
        layoutMode == .threePane && openedThreadId == nil
    }

    /// Whether an empty reading pane is large enough for pane-fill compose.
    static func shouldPaneFill(paneHeight: CGFloat, paneWidth: CGFloat) -> Bool {
        paneHeight >= minPaneFillHeight && paneWidth >= minPaneFillWidth
    }

    /// Smallest empty pane that still feels like a primary writing surface.
    static let minPaneFillHeight: CGFloat = 360
    /// Narrowest empty pane that keeps From/To/Subject usable (matches the
    /// split draft-column floor so the card is never thinner than side-by-side).
    static let minPaneFillWidth: CGFloat = minSplitComposeWidth
    /// Inset of the pane-fill card from the reading-pane edges — keeps the
    /// elevated card readable as compose chrome, not a full-bleed document.
    ///
    /// Top is applied by shortening card height (bottom-trailing overlay); the
    /// bottom EdgeInsets pad is `paneBottomPadding`. Host and pane bottoms
    /// must align for the top gutter to equal `paneTopPadding`.
    static let paneTopPadding: CGFloat = 12
    static let paneBottomPadding: CGFloat = 12
    static var paneSidePadding: CGFloat { inlineSidePadding }

    /// Card height when filling an empty reading pane (pane − top/bottom pad).
    static func effectivePaneCardHeight(paneHeight: CGFloat) -> CGFloat {
        guard paneHeight > 1 else { return preferredFloatingCardHeight }
        return max(0, paneHeight - paneTopPadding - paneBottomPadding)
    }

    /// Historical floating card body height (ContentView chrome default).
    static let preferredFloatingCardHeight: CGFloat = 500
    /// Floor so a short host never collapses the floating card to nothing.
    static let minFloatingCardHeight: CGFloat = 260
    /// Small top gutter above the floating card inside the host.
    static let floatingTopGutter: CGFloat = 12

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

    /// Floating card height clamped to the host so the Send footer stays on-screen.
    /// Unmeasured / tall hosts keep `preferredFloatingCardHeight`; short hosts
    /// shrink to host − bottom pad − top gutter, never below `minFloatingCardHeight`.
    static func effectiveFloatingCardHeight(hostHeight: CGFloat) -> CGFloat {
        guard hostHeight > 1 else { return preferredFloatingCardHeight }
        let available = hostHeight - floatingBottomPadding - floatingTopGutter
        return min(preferredFloatingCardHeight,
                   max(minFloatingCardHeight, available))
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

    /// Stable scroll id for the reading-pane top (subject). Used when a
    /// single-message thread has no `scrollPosition` id yet so dismiss can
    /// restore "start of conversation" after a bottom reply scroll.
    static let threadTopScrollId = "thread.scroll.top"

    /// Message id to pin above inline compose (reply parent, else newest sent).
    static func scrollTargetId(replyTo: Message?,
                               messages: [Message]) -> String? {
        if let id = replyTo?.id,
           messages.contains(where: { $0.id == id }) {
            return id
        }
        return ForwardComposer.newestSentMessage(in: messages)?.id
            ?? messages.last?.id
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
    ///
    /// Width never exceeds the pane's inner width (after side padding). A
    /// previous `max(minWidth, …)` floor could make the card wider than the
    /// pane on short columns; the trailing-aligned overlay then hid the left
    /// edge under the thread list.
    static func inlineMetrics(host: CGRect, pane: CGRect,
                              sidePadding: CGFloat = inlineSidePadding) -> InlineMetrics? {
        guard host.width > 1, host.height > 1,
              pane.width > 1, pane.height > 1 else { return nil }
        let leading = max(0, pane.minX - host.minX) + sidePadding
        // Prefer the pane's own width so split-view chrome (sidebar/list)
        // never leaks under the card even if host includes them.
        let width = max(0, pane.width - sidePadding * 2)
        return InlineMetrics(leading: leading, width: width)
    }

    // MARK: Card chrome (single choke-point for on-screen fit)

    /// Preferred floating / unmeasured-inline card width (Notion/Gmail dock).
    static let preferredFloatingWidth: CGFloat = 620
    /// Minimized strip width before host clamp.
    static let preferredMinimizedWidth: CGFloat = 300
    /// Floating card trailing / bottom gutter from the window edge.
    static let floatingTrailingPadding: CGFloat = 16
    static let floatingBottomPadding: CGFloat = 16
    /// Split card width inside the draft column (column − both gutters).
    static var minSplitCardWidth: CGFloat { minSplitComposeWidth - splitPadding * 2 }

    /// Horizontal placement for the compose overlay card.
    struct CardChrome: Equatable {
        /// Leading inset from the host's leading edge (0 for floating/split).
        /// Used only as a pin-to-pane layout gutter — ContentView must mark
        /// that spacer `.allowsHitTesting(false)` so sidebar/list clicks pass
        /// through (pane-fill is nearly full height and would otherwise block
        /// the whole left columns).
        var leading: CGFloat
        /// Card width (already clamped to fit the host when measured).
        var width: CGFloat
        /// Trailing padding outside the card to the host's trailing edge.
        var trailingPadding: CGFloat
    }

    /// Resolve leading / width / trailing pad so the card stays fully on-screen.
    ///
    /// Callers pass the already-`resolvedPresentation` value (inline demoted
    /// to floating when the pane is too short). Height stays elsewhere.
    static func cardChrome(
        presentation: ComposePresentation,
        minimized: Bool,
        host: CGRect,
        pane: CGRect,
        layoutMode: MailLayoutMode
    ) -> CardChrome {
        let hostW = host.width
        let hostMeasured = hostW > 1

        if minimized {
            let trail = floatingTrailingPadding
            let width = clampWidth(preferredMinimizedWidth,
                                   maxAllowed: hostMeasured ? hostW - trail : nil)
            return CardChrome(leading: 0, width: width, trailingPadding: trail)
        }

        switch presentation {
        case .floating:
            let trail = floatingTrailingPadding
            let width = clampWidth(preferredFloatingWidth,
                                   maxAllowed: hostMeasured ? hostW - trail : nil)
            return CardChrome(leading: 0, width: width, trailingPadding: trail)

        case .inline, .pane:
            // Pane fill reuses the inline pin (reading-column gutters) so the
            // card reads as compose chrome inside the detail column, not a
            // full-bleed sheet.
            let side = presentation == .pane ? paneSidePadding : inlineSidePadding
            let measured = inlineMetrics(host: host, pane: pane, sidePadding: side)
            var leading = measured?.leading
                ?? fallbackLeadingInset(layoutMode: layoutMode)
            var width = measured?.width ?? preferredFloatingWidth
            if hostMeasured {
                // Fit inside the host: shrink width first, then pull leading in
                // if a stale/large fallback still overflows.
                let maxWidth = max(0, hostW - side - max(0, leading))
                width = min(width, maxWidth)
                if leading + width + side > hostW {
                    leading = max(0, hostW - width - side)
                }
                // When the pane is known, pin into it (symmetric 12pt gutters)
                // rather than trusting a fallback that can sit under the list.
                if pane.width > 1, pane.height > 1 {
                    let paneLeading = max(0, pane.minX - host.minX) + side
                    let paneInner = max(0, pane.width - side * 2)
                    leading = paneLeading
                    width = min(paneInner, max(0, hostW - leading - side))
                }
            }
            return CardChrome(leading: leading, width: max(0, width),
                              trailingPadding: side)

        case .split:
            let pad = splitPadding
            let colHost = hostMeasured ? hostW : preferredFloatingWidth * 2
            let col = splitComposeWidth(hostWidth: colHost)
            // Card sits in the right column with pad on both sides.
            // Clamp against both gutters so a narrow host never loses the
            // leading inset (overlay is trailing-anchored).
            var width = max(0, col - pad * 2)
            if hostMeasured {
                width = min(width, max(0, hostW - pad * 2))
            }
            let floor = minSplitCardWidth
            if width < floor, hostMeasured, hostW - pad * 2 >= floor {
                width = floor
            }
            return CardChrome(leading: 0, width: width, trailingPadding: pad)
        }
    }

    /// Preferred width, never exceeding `maxAllowed` when the host is known.
    /// May drop below `minUsableCardWidth` when the host is pathologically narrow.
    private static func clampWidth(_ preferred: CGFloat,
                                   maxAllowed: CGFloat?) -> CGFloat {
        guard let maxAllowed else { return preferred }
        return max(0, min(preferred, maxAllowed))
    }

    // MARK: Side-by-side (split) compose

    /// Narrowest draft column that still fits From/To/Subject plus toolbar.
    static let minSplitComposeWidth: CGFloat = 360
    /// Cap so a full-screen window doesn't stretch the draft past a
    /// comfortable writing measure; the conversation absorbs the rest.
    static let maxSplitComposeWidth: CGFloat = 640
    /// Gutter around the split draft card (matches the inline paddings).
    static let splitPadding: CGFloat = 12

    /// Draft column width in split view: half the window, clamped to a
    /// usable range. The conversation column takes whatever remains.
    static func splitComposeWidth(hostWidth: CGFloat) -> CGFloat {
        min(max(hostWidth * 0.5, minSplitComposeWidth), maxSplitComposeWidth)
    }

    /// Rough leading inset when PreferenceKey frames are not yet available.
    /// Matches `NavigationSplitView` ideal column widths in ContentView
    /// (sidebar 240, list 560) so a first-frame fallback does not place the
    /// card under the list.
    static func fallbackLeadingInset(layoutMode: MailLayoutMode) -> CGFloat {
        switch layoutMode {
        case .threadFocus: return inlineSidePadding
        case .threePane: return 240 + 560
        case .compactDetail, .list: return 220
        }
    }
}
