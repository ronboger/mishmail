import XCTest

final class MishMailSmokeTests: XCTestCase {
    func testDemoInboxOpensConversationComposeAndSettingsWithoutAuthError() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        let demoThread = app.staticTexts
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()

        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS[c] 'reauthorized'")).firstMatch.exists)

        let compactBack = app.buttons.matching(identifier: "compactBackButton").firstMatch
        XCTAssertTrue(compactBack.waitForExistence(timeout: 5))
        compactBack.click()
        XCTAssertTrue(demoThread.waitForExistence(timeout: 5))
        demoThread.click()
        XCTAssertTrue(subject.waitForExistence(timeout: 5))

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        XCTAssertTrue(demoThread.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label == 'Hide Reading Pane'")).firstMatch
            .waitForExistence(timeout: 5))
        demoThread.click()
        XCTAssertTrue(subject.waitForExistence(timeout: 5))

        let compose = app.buttons.matching(identifier: "composeButton").firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        compose.click()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "composeCard").firstMatch
            .waitForExistence(timeout: 5))

        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.windows.matching(
            NSPredicate(format: "title CONTAINS 'Settings'")).firstMatch
            .waitForExistence(timeout: 5))
    }
}
