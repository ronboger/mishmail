import XCTest

/// Regression: Gmail's `g i` must leave a full-window (Superhuman-style)
/// conversation and land back on the inbox list. The store already exits
/// `threadFocusMode` on every go-to; this covers the *event path* — the key
/// has to reach `MailStore.handleKey` while the conversation fills the window.
final class GoToMailboxUITests: XCTestCase {
    func testGoToInboxExitsFullWindowConversation() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "fullWindow"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()

        let demoThread = app.staticTexts
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()

        let exitFocus = app.buttons.matching(identifier: "exitFocusButton").firstMatch
        XCTAssertTrue(exitFocus.waitForExistence(timeout: 5),
                      "clicking a row in full-window style should fill the app")

        // The actual regression trigger: reading the message parks first
        // responder on the conversation's selectable (read-only) text. The key
        // monitor used to read that as "the user is typing" and stand every
        // single-key shortcut down.
        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))
        subject.click()

        app.typeKey("g", modifierFlags: [])
        app.typeKey("i", modifierFlags: [])

        let deadline = Date().addingTimeInterval(5)
        while exitFocus.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(exitFocus.exists,
                       "g i must exit the full-window conversation")
        XCTAssertTrue(demoThread.waitForExistence(timeout: 5),
                      "g i must land back on the inbox list")
    }
}
