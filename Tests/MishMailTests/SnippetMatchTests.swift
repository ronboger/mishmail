import XCTest

final class SnippetMatchTests: XCTestCase {

    private func snip(_ name: String, accounts: [String] = []) -> Snippet {
        var s = Snippet(id: nil, name: name, body: "body of \(name)", movesToBcc: false)
        s.accountIds = accounts
        return s
    }

    // MARK: - Ranking

    func testExactMatchRanksAbovePrefixAndContains() {
        let all = [snip("ball"), snip("bball"), snip("mybball")]
        let ranked = SnippetMatch.ranked(all, query: "bball", accountId: "")
        XCTAssertEqual(ranked.map(\.name), ["bball", "mybball"])
        // "ball" does not contain "bball"
        XCTAssertFalse(ranked.contains { $0.name == "ball" })
    }

    func testPrefixBeatsMidSubstring() {
        let all = [snip("followup"), snip("bball"), snip("xbbally")]
        let ranked = SnippetMatch.ranked(all, query: "bb", accountId: "")
        XCTAssertEqual(ranked.first?.name, "bball")
        XCTAssertEqual(ranked.map(\.name), ["bball", "xbbally"])
        XCTAssertFalse(ranked.contains { $0.name == "followup" })
    }

    func testEmptyQueryReturnsAllAvailableInInputOrder() {
        let all = [snip("z"), snip("a")]
        let ranked = SnippetMatch.ranked(all, query: "", accountId: "")
        XCTAssertEqual(ranked.map(\.name), ["z", "a"])
    }

    func testCaseInsensitive() {
        let all = [snip("BBall"), snip("followup")]
        let ranked = SnippetMatch.ranked(all, query: "bball", accountId: "")
        XCTAssertEqual(ranked.map(\.name), ["BBall"])
    }

    // MARK: - Account scope

    func testUnscopedAvailableEverywhere() {
        let s = snip("cal")
        XCTAssertTrue(s.isAvailable(for: "a@x.com"))
        XCTAssertTrue(s.isAvailable(for: "b@y.com"))
        XCTAssertTrue(s.isAvailable(for: ""))
    }

    func testScopedOnlyOnListedAccounts() {
        let s = snip("work", accounts: ["me@work.com", "other@work.com"])
        XCTAssertTrue(s.isAvailable(for: "me@work.com"))
        XCTAssertTrue(s.isAvailable(for: "ME@WORK.COM"))
        XCTAssertFalse(s.isAvailable(for: "personal@gmail.com"))
    }

    func testRankedFiltersByAccount() {
        let all = [
            snip("global"),
            snip("work-only", accounts: ["w@x.com"]),
            snip("home-only", accounts: ["h@y.com"]),
        ]
        let atWork = SnippetMatch.ranked(all, query: "", accountId: "w@x.com")
        XCTAssertEqual(Set(atWork.map(\.name)), ["global", "work-only"])

        let typed = SnippetMatch.ranked(all, query: "work", accountId: "h@y.com")
        XCTAssertTrue(typed.isEmpty, "work-only must not appear on home account")
    }

    func testAccountIdsRoundTripJSON() {
        var s = snip("x")
        s.accountIds = ["a@b.com", " c@d.com "]
        XCTAssertEqual(s.accountIds, ["a@b.com", "c@d.com"])
        s.accountIds = []
        XCTAssertNil(s.accountIdsJSON)
        XCTAssertTrue(s.isAvailable(for: "anyone@x.com"))
    }

    func testPartitionLiveVsRemovedAccounts() {
        let s = snip("work", accounts: ["live@x.com", "gone@y.com", "LIVE@x.com"])
        // Setter keeps both case variants if written separately; among() uses
        // the cleaned accountIds list.
        let part = s.accountIds(among: ["live@x.com", "other@z.com"])
        XCTAssertTrue(part.live.map { $0.lowercased() }.contains("live@x.com"))
        XCTAssertTrue(part.removed.map { $0.lowercased() }.contains("gone@y.com"))
        // Fully orphaned → invisible in every compose (no live mailbox match).
        let orphan = snip("hidden", accounts: ["gone@y.com"])
        XCTAssertFalse(orphan.isAvailable(for: "live@x.com"))
        XCTAssertEqual(orphan.accountIds(among: ["live@x.com"]).removed, ["gone@y.com"])
        XCTAssertTrue(orphan.accountIds(among: ["live@x.com"]).live.isEmpty)
    }

    func testEmptyFromAccountIdKeepsScopedVisible() {
        // Compose fills From before send; empty id must not hide scoped snippets.
        let s = snip("work", accounts: ["me@work.com"])
        XCTAssertTrue(s.isAvailable(for: ""))
        XCTAssertTrue(s.isAvailable(for: "   "))
    }
}
