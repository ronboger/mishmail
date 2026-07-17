import XCTest

final class MishMailSmokeTests: XCTestCase {
    func testDemoInboxOpensConversationComposeAndSettingsWithoutAuthError() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO",
                                // This test exercises the pane/compact layout;
                                // full-window open is covered by SplitComposeUITests.
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 1080,
                          "The default launch width must exercise compact detail navigation")
        app.activate()
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

        // Regression: the first keyboard selection in compact mode used to
        // replace the list with an empty "Select a conversation" pane because
        // openedThreadId had not yet been primed by a click.
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
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

        // Deleting the open conversation must swap directly to its neighbor.
        // The reading pane must never briefly render its empty-selection view.
        let previousSubject = subject.label
        let trash = app.buttons.matching(
            NSPredicate(format: "label == 'Trash'")).firstMatch
        XCTAssertTrue(trash.waitForExistence(timeout: 5))
        trash.click()
        XCTAssertFalse(app.staticTexts["Select a conversation"].exists)
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        XCTAssertNotEqual(subject.label, previousSubject)

        // Compose lives in the sidebar, which starts hidden — → reveals it.
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])
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
