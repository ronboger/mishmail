import XCTest

final class DatabaseLocationTests: XCTestCase {
    func testUITestsUseASeparateApplicationSupportDirectory() {
        let root = URL(fileURLWithPath: "/tmp/Application Support", isDirectory: true)
        XCTAssertEqual(
            AppDatabase.storageDirectory(root: root, isUITest: true).lastPathComponent,
            "MishMailUITests")
        XCTAssertEqual(
            AppDatabase.storageDirectory(root: root, isUITest: false).lastPathComponent,
            "MishMail")
    }
}
