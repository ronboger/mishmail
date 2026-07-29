import XCTest

final class ComposePlacementTests: XCTestCase {
    private func message(threadId: String = "a:t1") -> Message {
        Message(
            id: "a:m1", accountId: "a", gmailId: "m1", threadId: threadId,
            fromHeader: "x@y.com", toHeader: "me@a.com", ccHeader: "",
            subject: "Hi", date: Date(), snippet: "", bodyText: "body",
            bodyHTML: nil, messageIdHeader: "<1>", referencesHeader: "",
            labelIds: "INBOX", isUnread: false, hasAttachment: false)
    }

    func testReplyToOpenThreadIsInline() {
        let msg = message()
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: false,
                selectedThreadId: msg.threadId, readingPaneHidden: false),
            .inline)
    }

    func testReplyWithHiddenPaneIsFloating() {
        let msg = message()
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: false,
                selectedThreadId: msg.threadId, readingPaneHidden: true),
            .floating)
    }

    func testForwardIsAlwaysFloating() {
        let msg = message()
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: true,
                selectedThreadId: msg.threadId, readingPaneHidden: false),
            .floating)
    }

    func testNewComposeIsFloating() {
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: nil, forward: false,
                selectedThreadId: "a:t1", readingPaneHidden: false),
            .floating)
    }

    func testEditDraftInOpenThreadIsInline() {
        var draft = message(threadId: "a:t2")
        draft.labelIds = "DRAFT"
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: nil, editDraft: draft, forward: false,
                selectedThreadId: "a:t2", readingPaneHidden: false),
            .inline)
    }

    func testOffThreadReplyIsFloating() {
        let msg = message(threadId: "a:other")
        XCTAssertEqual(
            ComposePlacement.preferred(
                replyTo: msg, forward: false,
                selectedThreadId: "a:t1", readingPaneHidden: false),
            .floating)
    }

    func testShowsInlineRequiresMatchingThread() {
        let msg = message()
        XCTAssertTrue(ComposePlacement.showsInline(
            inThread: msg.threadId, presentation: .inline,
            replyTo: msg, editDraft: nil))
        XCTAssertFalse(ComposePlacement.showsInline(
            inThread: "a:other", presentation: .inline,
            replyTo: msg, editDraft: nil))
        XCTAssertFalse(ComposePlacement.showsInline(
            inThread: msg.threadId, presentation: .floating,
            replyTo: msg, editDraft: nil))
    }

    func testInlineMetricsPinsCardToReadingPane() {
        // Host is the full window; pane is the trailing column.
        let host = CGRect(x: 100, y: 50, width: 1_200, height: 800)
        let pane = CGRect(x: 100 + 240 + 480, y: 50, width: 480, height: 800)
        let metrics = ComposePlacement.inlineMetrics(host: host, pane: pane)
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics!.leading, 240 + 480 + ComposePlacement.inlineSidePadding,
                       accuracy: 0.001)
        XCTAssertEqual(metrics!.width,
                       480 - ComposePlacement.inlineSidePadding * 2,
                       accuracy: 0.001)
    }

    func testInlineMetricsNilWhileFramesAreZero() {
        XCTAssertNil(ComposePlacement.inlineMetrics(host: .zero, pane: .zero))
        XCTAssertNil(ComposePlacement.inlineMetrics(
            host: CGRect(x: 0, y: 0, width: 800, height: 600),
            pane: .zero))
    }

    func testFallbackLeadingInsetByLayoutMode() {
        XCTAssertEqual(ComposePlacement.fallbackLeadingInset(layoutMode: .threadFocus),
                       ComposePlacement.inlineSidePadding)
        // Matches NavigationSplitView ideals: sidebar 240 + list 560.
        XCTAssertEqual(ComposePlacement.fallbackLeadingInset(layoutMode: .threePane),
                       240 + 560)
        XCTAssertEqual(ComposePlacement.fallbackLeadingInset(layoutMode: .compactDetail),
                       220)
    }

    func testInlineMetricsNeverExceedsPane() {
        // Short reading pane: width must stay inside the pane (no minWidth floor
        // that overflows into the list under a trailing-aligned overlay).
        let host = CGRect(x: 0, y: 0, width: 1_000, height: 700)
        let pane = CGRect(x: 800, y: 0, width: 200, height: 700)
        let metrics = ComposePlacement.inlineMetrics(host: host, pane: pane)
        XCTAssertNotNil(metrics)
        XCTAssertEqual(metrics!.width,
                       200 - ComposePlacement.inlineSidePadding * 2,
                       accuracy: 0.001)
        XCTAssertLessThanOrEqual(metrics!.width, pane.width)
    }

    func testFloatingWidthShrinksToHost() {
        let host = CGRect(x: 0, y: 0, width: 500, height: 700)
        let chrome = ComposePlacement.cardChrome(
            presentation: .floating, minimized: false,
            host: host, pane: .zero, layoutMode: .list)
        XCTAssertEqual(chrome.trailingPadding,
                       ComposePlacement.floatingTrailingPadding)
        XCTAssertLessThanOrEqual(
            chrome.width + chrome.trailingPadding, host.width + 0.001)
        XCTAssertLessThan(chrome.width,
                          ComposePlacement.preferredFloatingWidth)
    }

    func testFloatingKeepsPreferredOnWideHost() {
        let host = CGRect(x: 0, y: 0, width: 1_400, height: 900)
        let chrome = ComposePlacement.cardChrome(
            presentation: .floating, minimized: false,
            host: host, pane: .zero, layoutMode: .threePane)
        XCTAssertEqual(chrome.width,
                       ComposePlacement.preferredFloatingWidth,
                       accuracy: 0.001)
        XCTAssertEqual(chrome.leading, 0, accuracy: 0.001)
    }

    func testInlineCardFitsHostWhenLeadingLarge() {
        // Three-pane-ish: list+sidebar leave a 360pt pane on a 1_100 host.
        let host = CGRect(x: 0, y: 0, width: 1_100, height: 800)
        let pane = CGRect(x: 740, y: 0, width: 360, height: 800)
        let chrome = ComposePlacement.cardChrome(
            presentation: .inline, minimized: false,
            host: host, pane: pane, layoutMode: .threePane)
        XCTAssertGreaterThanOrEqual(chrome.leading, 0)
        XCTAssertLessThanOrEqual(
            chrome.leading + chrome.width + chrome.trailingPadding,
            host.width + 0.001)
        // Fully inside the reading pane (symmetric side padding).
        let cardMinX = host.minX + chrome.leading
        let cardMaxX = cardMinX + chrome.width
        XCTAssertGreaterThanOrEqual(cardMinX, pane.minX - 0.001)
        XCTAssertLessThanOrEqual(cardMaxX, pane.maxX + 0.001)
    }

    func testInlineFallbackClampsOnCompactHost() {
        // Metrics unavailable (zero pane): fallback leading + 620 must still
        // fit the host instead of sliding under the list.
        let host = CGRect(x: 0, y: 0, width: 900, height: 700)
        let chrome = ComposePlacement.cardChrome(
            presentation: .inline, minimized: false,
            host: host, pane: .zero, layoutMode: .compactDetail)
        XCTAssertLessThanOrEqual(
            chrome.leading + chrome.width + chrome.trailingPadding,
            host.width + 0.001)
        XCTAssertGreaterThan(chrome.width, 0)
    }

    func testMinimizedWidthClamps() {
        let host = CGRect(x: 0, y: 0, width: 280, height: 600)
        let chrome = ComposePlacement.cardChrome(
            presentation: .floating, minimized: true,
            host: host, pane: .zero, layoutMode: .list)
        XCTAssertLessThanOrEqual(
            chrome.width + chrome.trailingPadding, host.width + 0.001)
    }

    func testSymmetricInlineSideInsets() {
        let host = CGRect(x: 100, y: 50, width: 1_200, height: 800)
        let pane = CGRect(x: 100 + 240 + 560, y: 50, width: 400, height: 800)
        let chrome = ComposePlacement.cardChrome(
            presentation: .inline, minimized: false,
            host: host, pane: pane, layoutMode: .threePane)
        let side = ComposePlacement.inlineSidePadding
        let cardMinX = host.minX + chrome.leading
        let cardMaxX = cardMinX + chrome.width
        XCTAssertEqual(cardMinX - pane.minX, side, accuracy: 0.001)
        XCTAssertEqual(pane.maxX - cardMaxX, side, accuracy: 0.001)
        XCTAssertEqual(chrome.trailingPadding, side, accuracy: 0.001)
    }

    func testUnmeasuredHostKeepsPreferredFloatingWidth() {
        // First frame before PreferenceKeys fire: keep the historical 620 so
        // we don't flash a zero-width card; clamp kicks in once host is known.
        let chrome = ComposePlacement.cardChrome(
            presentation: .floating, minimized: false,
            host: .zero, pane: .zero, layoutMode: .list)
        XCTAssertEqual(chrome.width,
                       ComposePlacement.preferredFloatingWidth,
                       accuracy: 0.001)
    }

    func testMeasuredInlineChromeFillsHostExactly() {
        // Trailing-anchored overlay and leading-inset math agree only when
        // leading + width + trailing == host.width. Lock that contract so a
        // future change cannot reintroduce under-list overflow.
        let host = CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let pane = CGRect(x: 800, y: 0, width: 400, height: 800)
        let chrome = ComposePlacement.cardChrome(
            presentation: .inline, minimized: false,
            host: host, pane: pane, layoutMode: .threePane)
        XCTAssertEqual(
            chrome.leading + chrome.width + chrome.trailingPadding,
            host.width, accuracy: 0.001)
    }

    func testInlineReservedHeightIncludesCardAndPadding() {
        XCTAssertEqual(ComposePlacement.inlineReservedHeight,
                       ComposePlacement.inlineCardHeight
                        + ComposePlacement.inlineBottomPadding)
    }

    func testMeasuredInlineHeightKeepsThreadVisible() {
        let pane: CGFloat = 520
        let card = ComposePlacement.effectiveInlineCardHeight(paneHeight: pane)
        let reserve = ComposePlacement.inlineReservedHeight(paneHeight: pane)
        XCTAssertEqual(card, 388, accuracy: 0.001)
        XCTAssertEqual(reserve + ComposePlacement.minThreadVisibleHeight,
                       pane, accuracy: 0.001)
    }

    func testMeasuredInlineHeightIsMonotonicAndNeverExceedsPane() {
        var previous: CGFloat = -1
        for height in stride(from: CGFloat(80), through: 900, by: 1) {
            let card = ComposePlacement.effectiveInlineCardHeight(
                paneHeight: height)
            let reserve = ComposePlacement.inlineReservedHeight(
                paneHeight: height)
            XCTAssertGreaterThanOrEqual(card, previous)
            XCTAssertLessThanOrEqual(reserve, height)
            previous = card
        }
    }

    func testUnknownPaneDoesNotReserveBeforeMeasurement() {
        XCTAssertEqual(
            ComposePlacement.effectiveInlineCardHeight(paneHeight: 0),
            ComposePlacement.inlineCardHeight)
        XCTAssertEqual(
            ComposePlacement.inlineReservedHeight(paneHeight: 0), 0)
    }

    func testSplitComposeWidthClampsToUsableRange() {
        // Mid-size window: exactly half.
        XCTAssertEqual(ComposePlacement.splitComposeWidth(hostWidth: 1_200), 600)
        // Narrow window: never below a usable composer width.
        XCTAssertEqual(ComposePlacement.splitComposeWidth(hostWidth: 600),
                       ComposePlacement.minSplitComposeWidth)
        // Full-screen: capped so the draft keeps a readable measure.
        XCTAssertEqual(ComposePlacement.splitComposeWidth(hostWidth: 2_000),
                       ComposePlacement.maxSplitComposeWidth)
    }

    func testSplitPassesThroughResolvedPresentationRegardlessOfPane() {
        // Split ignores the reading-pane height (it owns the whole window) —
        // a tiny stale pane measurement must not demote it to floating.
        XCTAssertEqual(
            ComposePlacement.resolvedPresentation(.split, paneHeight: 50), .split)
        XCTAssertEqual(
            ComposePlacement.resolvedPresentation(.split, paneHeight: 0), .split)
    }

    func testShowsInlineIsFalseForSplit() {
        let msg = message()
        XCTAssertFalse(ComposePlacement.showsInline(
            inThread: msg.threadId, presentation: .split,
            replyTo: msg, editDraft: nil))
    }

    func testTinyPaneFloatsInsteadOfMountingZeroHeightInlineCompose() {
        XCTAssertEqual(
            ComposePlacement.resolvedPresentation(.inline, paneHeight: 100),
            .floating)
        XCTAssertEqual(
            ComposePlacement.resolvedPresentation(.inline, paneHeight: 400),
            .inline)
        XCTAssertEqual(
            ComposePlacement.resolvedPresentation(.floating, paneHeight: 100),
            .floating)
    }

    private func message(id: String, threadId: String = "a:t1",
                         date: Date = Date()) -> Message {
        Message(
            id: id, accountId: "a", gmailId: id, threadId: threadId,
            fromHeader: "x@y.com", toHeader: "me@a.com", ccHeader: "",
            subject: "Hi", date: date, snippet: "", bodyText: "body",
            bodyHTML: nil, messageIdHeader: "<\(id)>", referencesHeader: "",
            labelIds: "INBOX", isUnread: false, hasAttachment: false)
    }

    func testScrollTargetPrefersReplyParentWhenPresent() {
        let a = message(id: "a:m1")
        let b = message(id: "a:m2", date: Date().addingTimeInterval(60))
        let msgs = [a, b]
        XCTAssertEqual(
            ComposePlacement.scrollTargetId(replyTo: a, messages: msgs), a.id)
        XCTAssertEqual(
            ComposePlacement.scrollTargetId(replyTo: nil, messages: msgs), b.id)
    }

    func testScrollTargetFallsBackWhenReplyMissingFromList() {
        let a = message(id: "a:m1")
        let orphan = message(id: "a:gone")
        XCTAssertEqual(
            ComposePlacement.scrollTargetId(replyTo: orphan, messages: [a]), a.id)
    }

    func testThreadTopScrollIdIsStable() {
        XCTAssertEqual(ComposePlacement.threadTopScrollId, "thread.scroll.top")
    }
}
