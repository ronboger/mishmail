import AppKit

/// Publishes call-stack breadcrumbs so an XCUITest failure can show *who*
/// triggered an action inside the app process — no debugger reaches the CI
/// runner, and accessibility-tree dumps truncate values too aggressively to
/// smuggle a stack through them.
///
/// Transport is a named pasteboard: both the app and the xctrunner are
/// sandboxed with separate containers (a shared file is unreachable), but
/// pasteboards cross that boundary. Inert outside `MISHMAIL_UI_TEST=1`.
enum UITestBreadcrumbs {
    static let pasteboardName = NSPasteboard.Name(
        "dev.ronboger.mishmail.uitest.breadcrumbs")

    private static let enabled =
        ProcessInfo.processInfo.environment["MISHMAIL_UI_TEST"] == "1"
    /// Whole-launch log, republished on every record so the reader always
    /// sees the full sequence for the current app process.
    private static var buffer =
        "app pid \(ProcessInfo.processInfo.processIdentifier)\n"

    static func record(_ event: String) {
        guard enabled else { return }
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(14)
            .joined(separator: "\n  ")
        buffer += "=== \(event)\n  \(stack)\n"
        let pasteboard = NSPasteboard(name: pasteboardName)
        pasteboard.clearContents()
        pasteboard.setString(buffer, forType: .string)
    }
}
