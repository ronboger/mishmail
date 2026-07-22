import XCTest

final class DatabaseKeyPolicyTests: XCTestCase {
    func testDemoBuildAvoidsKeychainBackedDatabaseKey() {
        XCTAssertTrue(AppDatabase.usesFixtureDatabaseKey(
            environment: ["MISHMAIL_DEMO": "1"]
        ))
    }

    func testUITestAvoidsKeychainBackedDatabaseKey() {
        XCTAssertTrue(AppDatabase.usesFixtureDatabaseKey(
            environment: ["MISHMAIL_UI_TEST": "1"]
        ))
    }

    func testRealInboxRequiresKeychainBackedDatabaseKey() {
        XCTAssertFalse(AppDatabase.usesFixtureDatabaseKey(environment: [:]))
        XCTAssertFalse(AppDatabase.usesFixtureDatabaseKey(
            environment: ["MISHMAIL_DEMO": "0", "MISHMAIL_UI_TEST": "0"]
        ))
    }
}
