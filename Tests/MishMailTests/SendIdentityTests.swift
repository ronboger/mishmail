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
        XCTAssertTrue(title.hasPrefix(custom), title)
    }

    func testMenuTitleSkipsTautologicalVia() {
        // Primary of ron@ronboger.com must not read "(via ron@ronboger.com)".
        let title = SendIdentityResolver.menuTitle(
            identities.first { $0.email == custom && $0.accountId == custom }!,
            all: identities)
        XCTAssertTrue(title.hasPrefix(custom), title)
        XCTAssertFalse(title.contains("via"), title)
    }

    func testMenuTitleDropsSharedDisplayName() {
        // One person, many domains: name is noise. Lead with the address.
        let sameName: [SendIdentity] = [
            SendIdentity(email: "ronb@berkeley.edu", displayName: "Ron Boger",
                         accountId: "ronb@berkeley.edu", isPrimary: true, isDefault: true),
            SendIdentity(email: custom, displayName: "Ron Boger",
                         accountId: custom, isPrimary: true, isDefault: true),
            SendIdentity(email: custom, displayName: "Ron Boger",
                         accountId: gmail, isPrimary: false, isDefault: false),
        ]
        XCTAssertEqual(
            SendIdentityResolver.menuTitle(sameName[0], all: sameName),
            "ronb@berkeley.edu")
        XCTAssertEqual(
            SendIdentityResolver.menuTitle(sameName[1], all: sameName),
            custom)
        XCTAssertEqual(
            SendIdentityResolver.menuTitle(sameName[2], all: sameName),
            "\(custom) (via \(gmail))")
    }

    func testMenuTitleKeepsNameWhenNamesDiffer() {
        let title = SendIdentityResolver.menuTitle(
            identities.first { $0.email == work }!,
            all: identities)
        XCTAssertEqual(title, "\(work) — Ron @ Retron")
    }

    func testSortedForMenuGroupsByDomainThenPrefersPrimary() {
        let berkeley = SendIdentity(
            email: "ronb@berkeley.edu", displayName: "Ron Boger",
            accountId: "ronb@berkeley.edu", isPrimary: true, isDefault: true)
        let viaGmail = identities.first { $0.email == custom && $0.accountId == gmail }!
        let primaryCustom = identities.first { $0.email == custom && $0.accountId == custom }!
        let sorted = SendIdentityResolver.sortedForMenu(
            [viaGmail, berkeley, primaryCustom])
        XCTAssertEqual(sorted.map(\.email),
                       ["ronb@berkeley.edu", custom, custom])
        XCTAssertEqual(sorted[1].accountId, custom, "primary before via")
        XCTAssertEqual(sorted[2].accountId, gmail)
    }

    func testApiAccountIdPinsRepliesToMessageMailbox() {
        // User requested a different OAuth account as From — must still send
        // through the mailbox that owns the thread.
        let api = SendIdentityResolver.apiAccountId(
            requested: custom, replyAccountId: gmail, draftAccountId: nil)
        XCTAssertEqual(api, gmail)

        // Reply draft: thread mailbox still wins over a later From pick.
        XCTAssertEqual(
            SendIdentityResolver.apiAccountId(
                requested: work, replyAccountId: gmail, draftAccountId: gmail),
            gmail)
    }

    func testApiAccountIdHonorsNewComposeFromAfterAutosave() {
        // The /bball-style bug: first autosave lands on the default mailbox,
        // user then picks berkeley, send must follow the pick — not the draft.
        XCTAssertEqual(
            SendIdentityResolver.apiAccountId(
                requested: work, replyAccountId: nil, draftAccountId: gmail),
            work)
        XCTAssertEqual(
            SendIdentityResolver.apiAccountId(
                requested: custom, replyAccountId: nil, draftAccountId: nil),
            custom)
        // Empty requested falls back to the draft mailbox (From not chosen yet).
        XCTAssertEqual(
            SendIdentityResolver.apiAccountId(
                requested: "", replyAccountId: nil, draftAccountId: gmail),
            gmail)
    }

    func testFixedMailboxLocksThreadedRestoreButNotNewMailRestore() {
        // Undo of a reply: still locked to the message mailbox.
        XCTAssertEqual(
            SendIdentityResolver.fixedMailboxAccountId(
                restoreAccountId: gmail, restoreIsThreaded: true,
                draftAccountId: nil, originalAccountId: nil),
            gmail)
        // Undo of brand-new compose: full From choice again.
        XCTAssertNil(
            SendIdentityResolver.fixedMailboxAccountId(
                restoreAccountId: gmail, restoreIsThreaded: false,
                draftAccountId: nil, originalAccountId: nil))
        // Live draft / reply still lock.
        XCTAssertEqual(
            SendIdentityResolver.fixedMailboxAccountId(
                restoreAccountId: nil, restoreIsThreaded: false,
                draftAccountId: gmail, originalAccountId: nil),
            gmail)
        XCTAssertEqual(
            SendIdentityResolver.fixedMailboxAccountId(
                restoreAccountId: nil, restoreIsThreaded: false,
                draftAccountId: nil, originalAccountId: custom),
            custom)
    }
}
