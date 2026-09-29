import XCTest

/// The open reading pane refreshes in place when the store reloads
/// (its `ThreadContentRevision`); this merge keeps hydrated bodies while taking
/// fresh header rows — and drops rows gone from the DB (discarded drafts).
final class ThreadRefreshMergeTests: XCTestCase {

    private func msg(id: String, labels: String = "INBOX",
                     bodyText: String = "", bodyHTML: String? = nil) -> Message {
        Message(
            id: "a:\(id)", accountId: "a", gmailId: id,
            threadId: "a:t1", fromHeader: "Ron <a@x.com>", toHeader: "b@x.com",
            ccHeader: "", bccHeader: "", subject: "Re: hi",
            date: Date(timeIntervalSince1970: 1_783_372_500),
            snippet: "", bodyText: bodyText, bodyHTML: bodyHTML,
            messageIdHeader: "<\(id)@mail>", referencesHeader: "",
            labelIds: labels, isUnread: false, hasAttachment: false)
    }

    func testDiscardedDraftDisappears() {
        let current = [
            msg(id: "1", bodyText: "hello"),
            msg(id: "d1", labels: "DRAFT", bodyText: "draft body"),
        ]
        let fresh = [msg(id: "1")] // draft row deleted by sync
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged.map(\.gmailId), ["1"],
                       "discarded draft must leave the open thread on refresh")
    }

    func testHydratedBodySurvivesHeaderOnlyRefresh() {
        let current = [msg(id: "1", bodyText: "full body", bodyHTML: "<p>full</p>")]
        let fresh = [msg(id: "1")] // messageHeaders(inThread:) returns empty bodies
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged[0].bodyText, "full body")
        XCTAssertEqual(merged[0].bodyHTML, "<p>full</p>")
    }

    func testFreshLabelsWinOverStaleCurrent() {
        let current = [msg(id: "1", labels: "INBOX UNREAD", bodyText: "body")]
        let fresh = [msg(id: "1", labels: "INBOX")]
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged[0].labelIds, "INBOX",
                       "header fields must come from the fresh row")
        XCTAssertEqual(merged[0].bodyText, "body",
                       "while the hydrated body is spliced back in")
    }

    func testNewMessageArrivesHeaderOnly() {
        let current = [msg(id: "1", bodyText: "body")]
        let fresh = [msg(id: "1"), msg(id: "2")]
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged.map(\.gmailId), ["1", "2"])
        XCTAssertTrue(ThreadRefresh.needsBodyLoad(merged[1]))
    }

    func testFreshBodyPreferredWhenPresent() {
        let current = [msg(id: "1", bodyText: "old")]
        let fresh = [msg(id: "1", bodyText: "new")]
        let merged = ThreadRefresh.merge(current: current, fresh: fresh)
        XCTAssertEqual(merged[0].bodyText, "new")
    }

    // MARK: - Initial open / empty→full refresh anchor

    /// When a superseded initial load lands via refreshMessages on an empty
    /// pane, scroll/body-seed must match the .task open path.
    func testInitialScrolledMessageIdAnchorsNewestSent() {
        let older = msg(id: "1", bodyText: "hi")
        let newer = msg(id: "2", bodyText: "re")
        let draft = msg(id: "d1", labels: "DRAFT", bodyText: "draft")
        // Single card: no explicit scroll (default top).
        XCTAssertNil(ThreadRefresh.initialScrolledMessageId(in: [newer]))
        // Multi: newest non-draft.
        XCTAssertEqual(
            ThreadRefresh.initialScrolledMessageId(in: [older, newer, draft]),
            newer.id)
        // Draft-only multi falls back to last row.
        let d1 = msg(id: "d1", labels: "DRAFT", bodyText: "a")
        let d2 = msg(id: "d2", labels: "DRAFT", bodyText: "b")
        XCTAssertEqual(
            ThreadRefresh.initialScrolledMessageId(in: [d1, d2]),
            d2.id)
    }

    func testInitialBodyLoadSeedIdsCoversNewestSentAndDrafts() {
        let older = msg(id: "1", bodyText: "hi")
        let newer = msg(id: "2", bodyText: "re")
        let draft = msg(id: "d1", labels: "DRAFT", bodyText: "draft")
        XCTAssertEqual(
            ThreadRefresh.initialBodyLoadSeedIds(in: [older, newer, draft]),
            [newer.id, draft.id])
        // Single sent: seed that id only.
        XCTAssertEqual(
            ThreadRefresh.initialBodyLoadSeedIds(in: [newer]),
            [newer.id])
        // Draft-only: every draft id, no sent.
        XCTAssertEqual(
            ThreadRefresh.initialBodyLoadSeedIds(in: [draft]),
            [draft.id])
    }

    func testInitialBodyLoadSeedIdsSkipsDiscardedDraftTrash() {
        let sent = msg(id: "1", bodyText: "hi")
        let discarded = msg(id: "d1", labels: "DRAFT TRASH", bodyText: "gone")
        let live = msg(id: "d2", labels: "DRAFT", bodyText: "keep")
        XCTAssertEqual(
            ThreadRefresh.initialBodyLoadSeedIds(in: [sent, discarded, live]),
            [sent.id, live.id])
    }

    // MARK: - isDisplayEquivalent (refresh no-op check)

    func testDisplayEquivalentForIdenticalThreads() {
        let a = [msg(id: "1", bodyText: "body", bodyHTML: "<p>body</p>"), msg(id: "2")]
        XCTAssertTrue(ThreadRefresh.isDisplayEquivalent(a, a))
    }

    func testDisplayEquivalentDetectsHeaderChanges() {
        let current = [msg(id: "1", labels: "INBOX UNREAD", bodyText: "body")]
        let fresh = [msg(id: "1", labels: "INBOX", bodyText: "body")]
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent(current, fresh),
                       "label / read-state changes must refresh the pane")
        var unread = current[0]
        unread.isUnread = true
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent(current, [unread]))
    }

    func testDisplayEquivalentDetectsAddedRemovedAndReorderedMessages() {
        let one = msg(id: "1")
        let two = msg(id: "2")
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent([one], [one, two]))
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent([one, two], [two, one]))
    }

    func testDisplayEquivalentDetectsHydrationAndInlining() {
        let empty = [msg(id: "1")]
        let hydrated = [msg(id: "1", bodyText: "body", bodyHTML: "<p><img src=\"cid:x\"></p>")]
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent(empty, hydrated))
        let inlined = [msg(id: "1", bodyText: "body",
                           bodyHTML: "<p><img src=\"data:image/png;base64,AAAA\"></p>")]
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent(hydrated, inlined),
                       "cid → data: rewrite changes the body length")
    }

    func testDisplayEquivalentComparesDraftBodiesInFull() {
        // Same length, different text: only a draft body can change like this.
        let before = [msg(id: "d1", labels: "DRAFT", bodyText: "cat")]
        let after = [msg(id: "d1", labels: "DRAFT", bodyText: "dog")]
        XCTAssertFalse(ThreadRefresh.isDisplayEquivalent(before, after))
    }

    func testDisplayEquivalentTreatsSameLengthSentBodyAsUnchanged() {
        // Sent bodies are immutable per id; a same-length difference cannot
        // come from a refresh, so the cheap length check is exact there.
        let a = [msg(id: "1", bodyText: "cat")]
        let b = [msg(id: "1", bodyText: "dog")]
        XCTAssertTrue(ThreadRefresh.isDisplayEquivalent(a, b))
    }

    // MARK: - ThreadMessageRoles

    func testMessageRolesSplitsDraftsAndSent() {
        let messages = [
            msg(id: "1"),
            msg(id: "gone", labels: "DRAFT TRASH"),
            msg(id: "2"),
            msg(id: "d1", labels: "DRAFT"),
        ]
        let roles = ThreadMessageRoles(messages: messages)
        XCTAssertEqual(roles.liveDraftIds, ["a:d1"])
        XCTAssertEqual(roles.nonDraftIds, ["a:1", "a:gone", "a:2"],
                       "discarded DRAFT+TRASH keeps ordinary card chrome")
        XCTAssertEqual(roles.lastNonDraftId, "a:2",
                       "discarded drafts never become the default-expanded card")
        XCTAssertTrue(roles.isLiveDraft("a:d1"))
        XCTAssertFalse(roles.isLiveDraft("a:gone"))
        XCTAssertEqual(roles.liveDraftIds,
                       messages.filter { ForwardComposer.isLiveDraft($0.labelIds) }.map(\.id))
        XCTAssertEqual(roles.lastNonDraftId,
                       ForwardComposer.newestSentMessage(in: messages)?.id)
    }

    func testMessageRolesEmptyThread() {
        let roles = ThreadMessageRoles(messages: [])
        XCTAssertEqual(roles.liveDraftIds, [])
        XCTAssertEqual(roles.nonDraftIds, [])
        XCTAssertNil(roles.lastNonDraftId)
    }
}
