import XCTest

/// `open.ready` measured 176–209 ms on the delete-advance path, with cache
/// *hits* costing the same as misses — so the cost was never the payload
/// lookup, it was the `await` round-trip: the continuation resumes on
/// MainActor, which is busy for ~180 ms with the SwiftUI work the delete just
/// kicked off. This main-actor mirror lets the pane paint from an already
/// known payload in the same frame, with no hop at all.
final class ThreadDetailMirrorTests: XCTestCase {
    func testReturnsPayloadWhenRevisionAndSuppressionMatch() {
        var mirror = ThreadDetailMirror(capacity: 3)
        let revision = ThreadContentRevision(epoch: 0, local: 0)
        mirror.store(payload(["m1"]), for: "t1", revision: revision, suppressing: [])

        let hit = mirror.payload(for: "t1", revision: revision, suppressing: [])

        XCTAssertEqual(hit?.messages.map(\.id), ["m1"])
    }

    func testMissesWhenTheThreadsRevisionMoved() {
        var mirror = ThreadDetailMirror(capacity: 3)
        mirror.store(payload(["m1"]), for: "t1",
                     revision: ThreadContentRevision(epoch: 0, local: 0),
                     suppressing: [])

        let hit = mirror.payload(
            for: "t1",
            revision: ThreadContentRevision(epoch: 0, local: 1),
            suppressing: [])

        XCTAssertNil(hit)
    }

    /// Suppression is applied on the way out of the repository, so a mirrored
    /// payload built under a different suppression set is not reusable.
    func testMissesWhenSuppressionChanged() {
        var mirror = ThreadDetailMirror(capacity: 3)
        let revision = ThreadContentRevision(epoch: 0, local: 0)
        mirror.store(payload(["m1"]), for: "t1", revision: revision, suppressing: [])

        let hit = mirror.payload(for: "t1", revision: revision, suppressing: ["d1"])

        XCTAssertNil(hit)
    }

    func testMissesForAnUnknownThread() {
        let mirror = ThreadDetailMirror(capacity: 3)

        XCTAssertNil(mirror.payload(
            for: "nope",
            revision: ThreadContentRevision(epoch: 0, local: 0),
            suppressing: []))
    }

    func testEvictsLeastRecentlyUsedBeyondCapacity() {
        var mirror = ThreadDetailMirror(capacity: 2)
        let revision = ThreadContentRevision(epoch: 0, local: 0)
        mirror.store(payload(["a"]), for: "t1", revision: revision, suppressing: [])
        mirror.store(payload(["b"]), for: "t2", revision: revision, suppressing: [])
        mirror.store(payload(["c"]), for: "t3", revision: revision, suppressing: [])

        XCTAssertNil(mirror.payload(for: "t1", revision: revision, suppressing: []))
        XCTAssertNotNil(mirror.payload(for: "t2", revision: revision, suppressing: []))
        XCTAssertNotNil(mirror.payload(for: "t3", revision: revision, suppressing: []))
    }

    private func payload(_ ids: [String]) -> ThreadDetailPayload {
        ThreadDetailPayload(
            messages: ids.map {
                Message(
                    id: $0, accountId: "me@example.com", gmailId: $0,
                    threadId: "t1", fromHeader: "a@example.com",
                    toHeader: "me@example.com", ccHeader: "", subject: "S",
                    date: Date(), snippet: "", bodyText: "body", bodyHTML: nil,
                    messageIdHeader: "<\($0)>", referencesHeader: "",
                    labelIds: "INBOX", isUnread: false, hasAttachment: false)
            },
            attachmentsByMessageId: [:],
            bodyPrepByMessageId: [:])
    }
}
