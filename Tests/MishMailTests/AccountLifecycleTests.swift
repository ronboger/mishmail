import XCTest

final class AccountLifecycleTests: XCTestCase {

    func testReauthRequiredForInvalidGrantAndMissingToken() {
        XCTAssertTrue(AccountLifecycle.isReauthRequired(OAuthError.invalidGrant))
        XCTAssertTrue(AccountLifecycle.isReauthRequired(GmailError.noRefreshToken("a@x.com")))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(OAuthError.cancelled))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(GmailError.historyExpired))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(GmailError.partialFetch(failedCount: 2)))
        XCTAssertFalse(AccountLifecycle.isReauthRequired(URLError(.timedOut)))
    }

    func testDemoConnectBlockedOnlyForFixtureKey() {
        XCTAssertTrue(AccountLifecycle.blocksDemoConnect(usesFixtureDatabaseKey: true))
        XCTAssertFalse(AccountLifecycle.blocksDemoConnect(usesFixtureDatabaseKey: false))
        XCTAssertTrue(AccountLifecycle.demoConnectBlockedMessage.contains("DEMO=0"))
    }

    func testSignInInsertsNewAccount() {
        let account = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: nil)
        XCTAssertEqual(account.id, "a@x.com")
        XCTAssertEqual(account.displayName, "Ada")
        XCTAssertEqual(account.senderName, "Ada")
        XCTAssertNil(account.historyId)
        XCTAssertNil(account.lastSyncAt)
    }

    func testReauthPreservesHistoryAndFillsEmptySenderName() {
        var existing = Account(
            id: "a@x.com", displayName: "a@x.com",
            historyId: "99", lastSyncAt: Date(timeIntervalSince1970: 50),
            senderName: "")
        let updated = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: existing)
        XCTAssertEqual(updated.historyId, "99")
        XCTAssertEqual(updated.lastSyncAt, existing.lastSyncAt)
        XCTAssertEqual(updated.displayName, "Ada",
                       "email-as-display-name is replaced by the profile name")
        XCTAssertEqual(updated.senderName, "Ada")

        existing.displayName = "Personal"
        existing.senderName = "Kept"
        let nicknamed = AccountLifecycle.accountAfterSignIn(
            email: "a@x.com", name: "Ada", existing: existing)
        XCTAssertEqual(nicknamed.displayName, "Personal")
        XCTAssertEqual(nicknamed.senderName, "Kept")
    }
}
