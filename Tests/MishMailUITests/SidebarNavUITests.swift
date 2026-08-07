import XCTest

/// Regression: left-sidebar mailbox clicks must change the list.
///
/// Two failure modes have bitten macOS SwiftUI here:
/// 1. A permanent TapGesture on every List row steals List(selection:).
/// 2. Pin-to-pane compose gutters spanning the host can swallow hits on the
///    sidebar/list under an open compose card.
final class SidebarNavUITests: XCTestCase {
    func testSidebarMailboxClicksNavigateList() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        // Do not pass -sidebarHidden: AppStorage(Bool) does not coerce the
        // argument-domain NSString the way AppKit bool(forKey:) does. Reveal
        // with → like MishMailSmokeTests instead.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-threadOpenStyle", "readingPane"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()

        // Inbox has unstarred demo mail; Starred does not include t3.
        let unstarred = app.staticTexts
            .matching(identifier: "threadRow.you@example.com:t3").firstMatch
        XCTAssertTrue(unstarred.waitForExistence(timeout: 10),
                      "demo inbox should list unstarred CI thread")

        // Sidebar starts collapsed; → reveals it (and compose lives there).
        app.typeKey(XCUIKeyboardKey.rightArrow.rawValue, modifierFlags: [])

        let starred = app.descendants(matching: .any)
            .matching(identifier: "sidebar.starred").firstMatch
        XCTAssertTrue(starred.waitForExistence(timeout: 5),
                      "sidebar Starred row must appear after → reveals the sidebar")
        starred.click()

        let deadline = Date().addingTimeInterval(5)
        while unstarred.exists, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertFalse(unstarred.exists,
                       "clicking Starred must leave the unstarred demo thread")

        let starredThread = app.staticTexts
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        // On failure, embed the whole accessibility tree — this only runs on
        // CI, where there is no way to see the window.
        if !starredThread.waitForExistence(timeout: 5) {
            XCTFail("""
                Starred mailbox should still show the starred demo thread. \
                Accessibility tree at failure:
                \(app.debugDescription)
                """)
        }

        // Compose open must not block further sidebar navigation (gutter
        // hit-testing under pin-to-pane / empty-pane fill when present).
        let compose = app.buttons.matching(identifier: "composeButton").firstMatch
        XCTAssertTrue(compose.waitForExistence(timeout: 5))
        compose.click()
        XCTAssertTrue(app.descendants(matching: .any)
            .matching(identifier: "composeCard").firstMatch
            .waitForExistence(timeout: 5))

        let inbox = app.descendants(matching: .any)
            .matching(identifier: "sidebar.inbox").firstMatch
        XCTAssertTrue(inbox.waitForExistence(timeout: 5))
        inbox.click()

        XCTAssertTrue(unstarred.waitForExistence(timeout: 5),
                      "sidebar Inbox click must work while compose is open")
    }
}
