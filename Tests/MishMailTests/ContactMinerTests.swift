import XCTest

final class ContactMinerTests: XCTestCase {
    private func msg(rowid: Int64,
                     from: String = "",
                     to: String = "",
                     cc: String = "",
                     labels: String = "INBOX") -> ContactMiner.MessageHeaders {
        ContactMiner.MessageHeaders(rowid: rowid, fromHeader: from,
                                    toHeader: to, ccHeader: cc, labelIds: labels)
    }

    private func contact(_ email: String, name: String = "", weight: Int = 1) -> ContactMiner.Contact {
        ContactMiner.Contact(name: name, email: email, weight: weight)
    }

    func testSuggestionsMatchEmailAndName() {
        let list = [
            contact("alice@x.com", name: "Alice"),
            contact("bob@y.com", name: "Bobby"),
            contact("carol@z.com"),
        ]
        let byEmail = ContactMiner.suggestions(from: list, matching: "bob")
        XCTAssertEqual(byEmail.map(\.email), ["bob@y.com"])
        let byName = ContactMiner.suggestions(from: list, matching: "ALI")
        XCTAssertEqual(byName.map(\.email), ["alice@x.com"])
        let limited = ContactMiner.suggestions(from: list, matching: "a", limit: 1)
        XCTAssertEqual(limited.count, 1)
        XCTAssertTrue(ContactMiner.suggestions(from: list, matching: "  ").isEmpty)
    }

    /// Production mining lowercases emails (`ContactMiner.merge`); suggestions
    /// only lowercases the query and compares email as stored. Document that
    /// contract so mixed-case rows are not silently expected to match.
    func testSuggestionsAssumeLowercasedEmails() {
        let minedStyle = contact("alice@x.com", name: "Alice")
        XCTAssertEqual(
            ContactMiner.suggestions(from: [minedStyle], matching: "Alice@X.COM").map(\.email),
            ["alice@x.com"])
        // If a contact ever bypassed mining and kept uppercase, email match fails
        // (name match still works). Lock the email half of the assumption.
        let mixed = contact("Alice@X.COM", name: "")
        XCTAssertTrue(
            ContactMiner.suggestions(from: [mixed], matching: "alice@x.com").isEmpty,
            "email side is case-sensitive; only mined lowercased emails match")
    }

    func testIncrementalMergeAddsToPriorWeights() {
        var weights: ContactMiner.WeightMap = [:]
        let own: Set<String> = ["me@x.com"]

        let firstMax = ContactMiner.merge(
            messages: [
                msg(rowid: 1, from: "Alice <alice@x.com>", labels: "INBOX"),
                msg(rowid: 2, from: "Bob <bob@x.com>", to: "me@x.com", labels: "INBOX"),
            ],
            into: &weights,
            excluding: own)
        XCTAssertEqual(firstMax, 2)
        XCTAssertEqual(weights["alice@x.com"]?.weight, 1)
        XCTAssertEqual(weights["bob@x.com"]?.weight, 1)

        let secondMax = ContactMiner.merge(
            messages: [
                msg(rowid: 3, from: "Alice <alice@x.com>", labels: "INBOX"),
                msg(rowid: 4, to: "Carol <carol@x.com>", labels: "SENT"),
            ],
            into: &weights,
            excluding: own)
        XCTAssertEqual(secondMax, 4)
        // Alice appeared twice as non-sent → weight 2
        XCTAssertEqual(weights["alice@x.com"]?.weight, 2)
        XCTAssertEqual(weights["bob@x.com"]?.weight, 1)
        // Sent to Carol → +5
        XCTAssertEqual(weights["carol@x.com"]?.weight, 5)
        XCTAssertEqual(weights["carol@x.com"]?.name, "Carol")
    }

    func testFullRebuildOnMissingMarkSemantics() {
        // Empty weights + empty message set is what a "full" pass starts with
        // when the high-water mark is 0 / missing — ranked list is empty.
        var weights: ContactMiner.WeightMap = [:]
        let max = ContactMiner.merge(messages: [], into: &weights, excluding: [])
        XCTAssertEqual(max, 0)
        XCTAssertTrue(ContactMiner.ranked(from: weights).isEmpty)

        // A full scan over all messages rebuilds from scratch.
        let full = [
            msg(rowid: 10, from: "Zed <zed@x.com>"),
            msg(rowid: 11, from: "Ann <ann@x.com>", labels: "SENT"),
            msg(rowid: 12, to: "Ann <ann@x.com>", labels: "SENT"),
        ]
        let fullMax = ContactMiner.merge(messages: full, into: &weights, excluding: ["me@x.com"])
        XCTAssertEqual(fullMax, 12)
        let ranked = ContactMiner.ranked(from: weights)
        XCTAssertEqual(ranked.map(\.email), ["ann@x.com", "zed@x.com"])
        XCTAssertEqual(ranked[0].weight, 10) // two SENT headers mentioning Ann
        XCTAssertEqual(ranked[1].weight, 1)
    }

    func testSentMailWeightingPreserved() {
        var weights: ContactMiner.WeightMap = [:]
        ContactMiner.merge(
            messages: [
                msg(rowid: 1, from: "News <news@list.com>", labels: "INBOX CATEGORY_PROMOTIONS"),
                msg(rowid: 2, to: "Friend <friend@x.com>", labels: "SENT"),
            ],
            into: &weights,
            excluding: ["me@x.com"])
        XCTAssertEqual(weights["news@list.com"]?.weight, 1)
        XCTAssertEqual(weights["friend@x.com"]?.weight, 5)

        // Longer display name wins when the same address reappears.
        ContactMiner.merge(
            messages: [
                msg(rowid: 3, from: "F <friend@x.com>", labels: "INBOX"),
                msg(rowid: 4, from: "Friendly Person <friend@x.com>", labels: "INBOX"),
            ],
            into: &weights,
            excluding: ["me@x.com"])
        XCTAssertEqual(weights["friend@x.com"]?.name, "Friendly Person")
        XCTAssertEqual(weights["friend@x.com"]?.weight, 7) // 5 + 1 + 1
    }

    func testOwnAddressesExcluded() {
        var weights: ContactMiner.WeightMap = [:]
        ContactMiner.merge(
            messages: [
                msg(rowid: 1,
                    from: "Me <me@x.com>",
                    to: "Other <other@x.com>",
                    cc: "Also Me <work@x.com>",
                    labels: "SENT"),
            ],
            into: &weights,
            excluding: ["me@x.com", "work@x.com"])
        XCTAssertNil(weights["me@x.com"])
        XCTAssertNil(weights["work@x.com"])
        XCTAssertEqual(weights["other@x.com"]?.weight, 5)
        XCTAssertEqual(weights.count, 1)
    }

    func testNameEqualsEmailStoredAsEmpty() {
        var weights: ContactMiner.WeightMap = [:]
        ContactMiner.merge(
            messages: [msg(rowid: 1, from: "bare@x.com")],
            into: &weights,
            excluding: [])
        let ranked = ContactMiner.ranked(from: weights)
        XCTAssertEqual(ranked.count, 1)
        XCTAssertEqual(ranked[0].email, "bare@x.com")
        XCTAssertEqual(ranked[0].name, "")
    }

    func testEmptyAndJunkHeadersSkipped() {
        var weights: ContactMiner.WeightMap = [:]
        ContactMiner.merge(
            messages: [
                msg(rowid: 1, from: "", to: "not-an-email", cc: "spaces in@x.com"),
            ],
            into: &weights,
            excluding: [])
        XCTAssertTrue(weights.isEmpty)
    }
}
