import XCTest

/// Regression: entering side-by-side compose (⇧⌘↩) must settle, not livelock.
/// 2026-07-21: toggling split from an inline reply pegged the main thread in an
/// endless SwiftUI re-render (99% CPU, unbounded memory) on the real mailbox
/// and the demo inbox alike. Element queries time out when that happens, so
/// this test fails fast under the bug.
final class SplitComposeUITests: XCTestCase {
    func testSplitComposeEntersAndExitsWithoutLivelock() {
        let app = XCUIApplication()
        app.launchEnvironment["MISHMAIL_DEMO"] = "1"
        app.launchEnvironment["MISHMAIL_UI_TEST"] = "1"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES",
                                "-NSQuitAlwaysKeepsWindows", "NO",
                                "-readingPaneHidden", "NO"]
        app.terminate()
        app.launch()
        addTeardownBlock { app.terminate() }

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))
        app.activate()

        let demoThread = app.staticTexts
            .matching(identifier: "threadRow.you@example.com:t1").firstMatch
        XCTAssertTrue(demoThread.waitForExistence(timeout: 10))
        demoThread.click()

        let subject = app.staticTexts.matching(identifier: "threadSubject").firstMatch
        XCTAssertTrue(subject.waitForExistence(timeout: 5))

        // Reply → inline (or floating in compact) composer.
        let reply = app.buttons.matching(NSPredicate(format: "label == 'Reply'")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        reply.click()
        let anyCompose = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier IN {'composeCard', 'composeInline'}")).firstMatch
        XCTAssertTrue(anyCompose.waitForExistence(timeout: 5))

        // ⇧⌘↩ → split. Under the livelock this query never resolves.
        app.typeKey("\r", modifierFlags: [.command, .shift])
        let splitCompose = app.descendants(matching: .any)
            .matching(identifier: "composeSplit").firstMatch
        XCTAssertTrue(splitCompose.waitForExistence(timeout: 8),
                      "split compose should mount and settle")
        let exitSplit = app.buttons.matching(identifier: "exitSplitButton").firstMatch
        XCTAssertTrue(exitSplit.waitForExistence(timeout: 5),
                      "split conversation column should show its exit control")

        // ⇧⌘↩ again → back to the previous placement, still responsive.
        app.typeKey("\r", modifierFlags: [.command, .shift])
        XCTAssertTrue(anyCompose.waitForExistence(timeout: 8),
                      "exiting split should restore the inline/floating composer")
    }
}
