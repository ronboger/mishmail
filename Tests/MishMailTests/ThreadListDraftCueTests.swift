import XCTest

/// List "Draft," participant prefix must follow live-draft denorm, not the
/// historical label union (discarded DRAFT+TRASH still carries DRAFT).
final class ThreadListDraftCueTests: XCTestCase {

    func testNoMarkerWhenOnlyDiscardedDraftsRemain() {
        // Anna / Fund Expense after discard: inDrafts=false, union still has DRAFT.
        XCTAssertEqual(
            ThreadListDraftCue.showsMarker(
                inDrafts: false, messageCount: 18, participants: "me .. Anna"),
            .none,
            "discarded DRAFT+TRASH must not paint orange Draft in the list")
    }

    func testLiveDraftLeadsParticipantNames() {
        XCTAssertEqual(
            ThreadListDraftCue.showsMarker(
                inDrafts: true, messageCount: 5, participants: "me .. Anna"),
            .draftLeadingNames)
    }

    func testDraftOnlyThreadShowsBareMarker() {
        XCTAssertEqual(
            ThreadListDraftCue.showsMarker(
                inDrafts: true, messageCount: 1, participants: "me"),
            .draftOnly)
        XCTAssertEqual(
            ThreadListDraftCue.showsMarker(
                inDrafts: true, messageCount: 3, participants: ""),
            .draftOnly)
    }

    /// Derivation already sets inDrafts=false for DRAFT+TRASH-only leftovers;
    /// pin the full Fund Expense fixture so list cue and denorm stay aligned.
    func testDerivedInDraftsFalseMeansNoListCue() throws {
        let account = "ron@x.com"
        func msg(id: String, labels: String, daysAgo: Int) -> Message {
            Message(
                id: "\(account):\(id)", accountId: account, gmailId: id,
                threadId: "\(account):t1", fromHeader: "Ron <\(account)>",
                toHeader: "Anna <anna@x.com>", ccHeader: "", bccHeader: "",
                subject: "Fund Expense",
                date: Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400),
                snippet: "", bodyText: "body", bodyHTML: nil,
                messageIdHeader: "<\(id)@x>", referencesHeader: "",
                labelIds: labels, isUnread: false, hasAttachment: false)
        }
        let messages = [
            msg(id: "reply", labels: "INBOX UNREAD", daysAgo: 0),
            msg(id: "d1", labels: "DRAFT TRASH", daysAgo: 1),
            msg(id: "d2", labels: "DRAFT TRASH", daysAgo: 2),
            msg(id: "sent", labels: "SENT INBOX", daysAgo: 10),
        ].sorted { $0.date > $1.date } // newest-first for deriveThread
        let t = try XCTUnwrap(SyncEngine.deriveThread(
            threadKey: "\(account):t1", gmailThreadId: "t1",
            accountId: account, messages: messages, existing: nil))
        XCTAssertFalse(t.inDrafts)
        XCTAssertTrue(t.labels.contains("DRAFT"), "union still has DRAFT for search")
        XCTAssertEqual(
            ThreadListDraftCue.showsMarker(
                inDrafts: t.inDrafts,
                messageCount: t.messageCount,
                participants: t.participants),
            .none)
    }
}
