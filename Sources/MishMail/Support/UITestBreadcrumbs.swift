import Foundation

/// Appends call-stack breadcrumbs to a file beside the UI-test database so an
/// XCUITest failure can show *who* triggered an action inside the app process
/// — no debugger reaches the CI runner, and accessibility-tree dumps truncate
/// values too aggressively to smuggle a stack through them.
///
/// Inert outside `MISHMAIL_UI_TEST=1`. The file lives in the same
/// `MishMailUITests` directory the Database wipes on every launch, so each
/// app launch starts a fresh log and the unsandboxed test runner can read it
/// through the app container.
enum UITestBreadcrumbs {
    static let fileName = "breadcrumbs.log"

    private static let url: URL? = {
        guard ProcessInfo.processInfo.environment["MISHMAIL_UI_TEST"] == "1",
              let root = try? FileManager.default.url(
                  for: .applicationSupportDirectory, in: .userDomainMask,
                  appropriateFor: nil, create: true)
        else { return nil }
        return root.appendingPathComponent("MishMailUITests")
            .appendingPathComponent(fileName)
    }()

    /// Record an event plus the frames that led to it. Cheap enough for the
    /// UI-test build; compiles to a guarded no-op read in production runs.
    static func record(_ event: String) {
        guard let url else { return }
        let stack = Thread.callStackSymbols.dropFirst(2).prefix(14)
            .joined(separator: "\n  ")
        let line = "=== \(event)\n  \(stack)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
