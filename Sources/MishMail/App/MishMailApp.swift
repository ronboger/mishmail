import SwiftUI

/// On quit: flush a pending undo-send (so mail isn't lost inside the 10s
/// window) and shut down database work before process teardown. Background
/// GRDB readers must finish before SQLCipher's atexit shutdown or we crash
/// in sqlcipher_page_hmac (use-after-free on a live reader connection).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: MailStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store else { return .terminateNow }
        Task { @MainActor in
            await store.prepareForTermination()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The standard macOS About panel, with a clickable "Support MishMail" line
/// added to the credits. MishMail is free; this is the only in-app nudge.
enum AboutPanel {
    /// GitHub Sponsors is the primary link; the README lists Ko-fi / ETH too.
    static let sponsorURL = URL(string: "https://github.com/sponsors/ronboger")!

    @MainActor
    static func show() {
        let credits = NSMutableAttributedString(
            string: "A native, local-first Gmail client for macOS.\n\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        let link = NSAttributedString(
            string: "Support MishMail",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .link: sponsorURL,
            ])
        credits.append(link)

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        credits.addAttribute(.paragraphStyle, value: paragraph,
                             range: NSRange(location: 0, length: credits.length))

        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}

@main
struct MishMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MailStore()
    @AppStorage("fontScale") private var fontScale = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(.notionAccent)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear {
                    AppDelegate.store = store
                    RemoteImagePolicy.migrateIfNeeded()
                    UpdateChecker.shared.startPeriodicChecks()
                }
        }
        .defaultSize(width: 1000, height: 640)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MishMail") { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                Button("Sync All") { Task { await store.syncAll() } }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Increase Text Size") { fontScale = min(1.6, fontScale + 0.1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Text Size") { fontScale = max(0.8, fontScale - 0.1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Text Size") { fontScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
