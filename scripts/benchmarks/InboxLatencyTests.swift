import AppKit
import XCTest

/// Copied into the UI-test target only by the remote latency workflow.
final class InboxLatencyTests: XCTestCase {
    func testMailboxLatency() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment = ["MISHMAIL_DEMO": "1", "MISHMAIL_UI_TEST": "1",
                                 "MISHMAIL_DEMO_AMPLIFY": "20"]
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO",
                               "-threadOpenStyle", "readingPane", "-readingPaneHidden", "NO", "-priorityMode", "off",
                               "-groupBy", "date", "-AppleShowScrollBars", "Always"]
        addTeardownBlock { app.terminate() }

        func row(_ id: String) -> XCUIElement {
            app.descendants(matching: .any).matching(identifier: "threadRow.you@example.com:\(id)").firstMatch
        }
        func untilVisible(_ element: XCUIElement) {
            XCTAssertTrue(element.waitForExistence(timeout: 15))
            XCTAssertTrue(element.frame.intersects(app.windows.firstMatch.frame), "Expected visible element: \(element.debugDescription)")
        }
        func time(_ operation: () throws -> Void) rethrows -> Double {
            let start = ProcessInfo.processInfo.systemUptime
            try operation()
            return (ProcessInfo.processInfo.systemUptime - start) * 1_000
        }
        func open(_ id: String, bodyContains text: String) -> (XCUIElement, Double) {
            let body = app.staticTexts.matching(NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@", text, text)).firstMatch
            let target = row(id)
            XCTAssertTrue(target.waitForExistence(timeout: 10))
            let window = app.windows.firstMatch
            let listPoint = window.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.5))
            // SwiftUI can initially anchor a long list below its first rows.
            // Position the fixture outside the timed interval.
            for _ in 0..<3 {
                let frame = target.frame
                if frame.height > 0, window.frame.insetBy(dx: 0, dy: 60).contains(CGPoint(x: frame.midX, y: frame.midY)) { break }
                listPoint.scroll(byDeltaX: 0, deltaY: 3500)
            }
            let duration = time {
                target.click()
                untilVisible(body)
            }
            return (body, duration)
        }

        // Each iteration starts a new process with a fresh, disposable DB.
        // Drop the first iteration on each build to warm the system caches.
        for trial in 0..<7 {
            app.terminate()
            let token = UUID().uuidString
            app.launchEnvironment["MAIL_BENCH_TRIAL"] = token
            let launchStart = ProcessInfo.processInfo.systemUptime
            let launch = time {
                app.launch()
                app.activate()
                XCTAssertTrue(row("t1").waitForExistence(timeout: 15))
                untilVisible(app.scrollViews.containing(.any, identifier: "threadRow.you@example.com:t1").firstMatch)
            }
            let (_, short) = open("t1", bodyContains: "Are the keyboard shortcuts final")
            app.typeKey(.escape, modifierFlags: [])
            let (body, long) = open("t2", bodyContains: "Scroll benchmark paragraph")
            let window = app.windows.firstMatch
            let visible = body.frame.intersection(window.frame.insetBy(dx: 30, dy: 80))
            XCTAssertFalse(visible.isEmpty)
            let location = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: visible.midX - window.frame.minX, dy: visible.midY - window.frame.minY))
            let origin = body.frame.minY
            // Scroll toward the rest of the message from the visible end.
            var delta: CGFloat = body.frame.maxY > window.frame.maxY ? -480 : 480
            var scroll = time {
                location.scroll(byDeltaX: 0, deltaY: delta)
                _ = body.frame
            }
            if abs(body.frame.minY - origin) < 1 {
                delta = -delta
                scroll = time {
                    location.scroll(byDeltaX: 0, deltaY: delta)
                    _ = body.frame
                }
            }
            XCTAssertGreaterThan(abs(body.frame.minY - origin), 1, "The message body must move")
            if trial > 0 {
                // XCTest's click and existence checks wait for quiescence.
                // Also report the in-app first draw and first viewport move,
                // which use the same monotonic clock without that wait.
                func native(_ key: String) -> Double? {
                    let board = NSPasteboard(name: .init("mishmail.benchmark.\(key)"))
                    let fields = board.string(forType: .string)?.split(separator: " ") ?? []
                    guard fields.count == 2, String(fields[0]) == token,
                          let seconds = Double(fields[1]) else { return nil }
                    return (seconds - (key == "inbox" ? launchStart : 0)) * 1000
                }
                for key in ["inbox", "short", "long", "scroll"] {
                    if let ms = native(key) { print("MAIL_NATIVE trial=\(trial) \(key)=\(ms)") }
                }
                print("MAIL_LATENCY trial=\(trial) inbox=\(launch) short=\(short) long=\(long) scroll=\(scroll)")
            }
        }
    }
}
