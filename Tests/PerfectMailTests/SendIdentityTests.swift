import XCTest

final class SendIdentityTests: XCTestCase {

    private let gmail = "ronboger@gmail.com"
    private let custom = "ron@ronboger.com"
    private let work = "ron@retron.vc"

    private var identities: [SendIdentity] {
        [
            SendIdentity(email: gmail, displayName: "Ron", accountId: gmail,
                         isPrimary: true, isDefault: true),
            SendIdentity(email: custom, displayName: "Ron Boger", accountId: gmail,
                         isPrimary: false, isDefault: false),
            // Same address also linked as its own OAuth mailbox.
            SendIdentity(email: custom, displayName: "Ron", accountId: custom,
                         isPrimary: true, isDefault: true),
            SendIdentity(email: work, displayName: "Ron @ Retron", accountId: work,
                         isPrimary: true, isDefault: true),
        ]
    }

    func testReplyFromOnlyOffersOwningMailboxIdentities() {
        let replyOptions = SendIdentityResolver.available(
            all: identities, forMailbox: gmail)
        XCTAssertEqual(Set(replyOptions.map(\.email)), Set([gmail, custom]))
        XCTAssertTrue(replyOptions.allSatisfy { $0.accountId == gmail })
        // The separate OAuth account for custom must not appear on a gmail reply.
        XCTAssertFalse(replyOptions.contains { $0.accountId == custom && $0.isPrimary })
    }

    func testNewComposeOffersEveryIdentity() {
        let all = SendIdentityResolver.available(all: identities, forMailbox: nil)
        XCTAssertEqual(all.count, identities.count)
    }

    func testPreferredPicksDefaultThenPrimary() {
        let preferred = SendIdentityResolver.preferred(identities, in: gmail)
        XCTAssertEqual(preferred?.email, gmail)
        XCTAssertTrue(preferred?.isDefault == true)
    }

    func testIdentityLookupPrefersMailboxContext() {
        // Without mailbox context, either custom identity is acceptable;
        // with gmail context, the send-as row wins (API mailbox = gmail).
        let viaGmail = SendIdentityResolver.identity(
            email: custom, inMailbox: gmail, from: identities)
        XCTAssertEqual(viaGmail?.accountId, gmail)
        XCTAssertFalse(viaGmail?.isPrimary ?? true)

        let viaOwn = SendIdentityResolver.identity(
            email: custom, inMailbox: custom, from: identities)
        XCTAssertEqual(viaOwn?.accountId, custom)
        XCTAssertTrue(viaOwn?.isPrimary == true)
    }

    func testAccountIdResolutionUsesMailboxContext() {
        let api = SendIdentityResolver.accountId(
            for: custom, inMailbox: gmail, identities: identities, fallback: "x")
        XCTAssertEqual(api, gmail)
    }

    func testIdentitiesFromSendAsDropsUnverifiedAliases() {
        let rows: [GSendAs] = [
            GSendAs(sendAsEmail: gmail, displayName: "Ron", isPrimary: true,
                    isDefault: true, verificationStatus: "accepted", treatAsAlias: nil),
            GSendAs(sendAsEmail: custom, displayName: "Ron Boger", isPrimary: false,
                    isDefault: false, verificationStatus: "accepted", treatAsAlias: true),
            GSendAs(sendAsEmail: "pending@x.com", displayName: nil, isPrimary: false,
                    isDefault: false, verificationStatus: "pending", treatAsAlias: true),
        ]
        let built = SendIdentityResolver.identities(
            accountId: gmail, senderName: "Ron Boger", sendAs: rows)
        XCTAssertEqual(Set(built.map { $0.email.lowercased() }),
                       Set([gmail, custom].map { $0.lowercased() }))
        XCTAssertFalse(built.contains { $0.email == "pending@x.com" })
    }

    func testIdentitiesFallbackToPrimaryWhenSendAsEmpty() {
        let built = SendIdentityResolver.identities(
            accountId: gmail, senderName: "Ron", sendAs: [])
        XCTAssertEqual(built.count, 1)
        XCTAssertEqual(built[0].email, gmail)
        XCTAssertTrue(built[0].isPrimary)
        XCTAssertTrue(built[0].isDefault)
        XCTAssertEqual(built[0].fromHeader, "Ron <\(gmail)>")
    }

    func testMenuTitleDisambiguatesDuplicateEmails() {
        let title = SendIdentityResolver.menuTitle(
            identities.first { $0.email == custom && $0.accountId == gmail }!,
            all: identities)
        XCTAssertTrue(title.contains("via \(gmail)"), title)
    }

    func testApiAccountIdPinsRepliesToMessageMailbox() {
        // User requested a different OAuth account as From — must still send
        // through the mailbox that owns the thread.
        let api = SendIdentityResolver.apiAccountId(
            requested: custom, replyAccountId: gmail, draftAccountId: nil)
        XCTAssertEqual(api, gmail)

        // Draft edit pins to the draft's mailbox.
        XCTAssertEqual(
            SendIdentityResolver.apiAccountId(
                requested: work, replyAccountId: nil, draftAccountId: gmail),
            gmail)

        // Brand-new mail: honor the requested account.
        XCTAssertEqual(
            SendIdentityResolver.apiAccountId(
                requested: custom, replyAccountId: nil, draftAccountId: nil),
            custom)
    }
}
