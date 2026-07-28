import XCTest

/// The message-header participant menu used to offer draft/search/copy/split/
/// block but not VIP — the only way to promote a sender was the thread-list
/// context menu or Settings. These tests pin the pure rule the UI menu uses.
final class ParticipantMenuVIPTests: XCTestCase {

    private let own: Set<String> = ["me@example.com", "alias@work.com"]
    private let vips: Set<String> = ["friend@x.com", "ceo@brctherapeutics.com"]

    // MARK: - Bug reproduction: external sender must get Add VIP

    func testExternalNonVIPOffersAdd() {
        let action = ParticipantMenuVIP.action(
            email: "ghodgin@brctherapeutics.com",
            vipEmails: vips,
            ownEmails: own)
        XCTAssertEqual(action, .add(email: "ghodgin@brctherapeutics.com"))
        XCTAssertEqual(ParticipantMenuVIP.title(for: action!),
                       "Add ghodgin@brctherapeutics.com to VIPs")
        XCTAssertEqual(ParticipantMenuVIP.systemImage(for: action!), "star.circle")
    }

    func testExternalVIPOffersRemove() {
        let action = ParticipantMenuVIP.action(
            email: "ceo@brctherapeutics.com",
            vipEmails: vips,
            ownEmails: own)
        XCTAssertEqual(action, .remove(email: "ceo@brctherapeutics.com"))
        XCTAssertEqual(ParticipantMenuVIP.title(for: action!),
                       "Remove ceo@brctherapeutics.com from VIPs")
        XCTAssertEqual(ParticipantMenuVIP.systemImage(for: action!), "star.circle.fill")
    }

    // MARK: - Own accounts never offer VIP (matches split/block gating)

    func testOwnAccountOffersNothing() {
        XCTAssertNil(ParticipantMenuVIP.action(
            email: "me@example.com", vipEmails: vips, ownEmails: own))
        XCTAssertNil(ParticipantMenuVIP.action(
            email: "Me@Example.com", vipEmails: vips, ownEmails: own),
                     "own-account check is case-insensitive")
        XCTAssertNil(ParticipantMenuVIP.action(
            email: "alias@work.com", vipEmails: vips, ownEmails: own))
    }

    // MARK: - Normalization

    func testEmailIsLowercasedAndTrimmed() {
        let action = ParticipantMenuVIP.action(
            email: "  Friend@X.COM  ",
            vipEmails: vips,
            ownEmails: own)
        XCTAssertEqual(action, .remove(email: "friend@x.com"))
    }

    func testInvalidOrEmptyEmailOffersNothing() {
        XCTAssertNil(ParticipantMenuVIP.action(
            email: "", vipEmails: vips, ownEmails: own))
        XCTAssertNil(ParticipantMenuVIP.action(
            email: "not-an-email", vipEmails: vips, ownEmails: own))
        XCTAssertNil(ParticipantMenuVIP.action(
            email: "nodot@local", vipEmails: vips, ownEmails: own))
    }

    /// VIP membership is checked after lowercasing; mixed-case headers from
    /// Gmail must still match the lowercased store set.
    func testMixedCaseHeaderMatchesVIPSet() {
        XCTAssertEqual(
            ParticipantMenuVIP.action(
                email: "CEO@BRCTherapeutics.com",
                vipEmails: vips,
                ownEmails: own),
            .remove(email: "ceo@brctherapeutics.com"))
    }
}
