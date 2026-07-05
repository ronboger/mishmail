import SwiftUI

/// Flushes a pending undo-send before the app quits, so a queued message
/// can't be silently lost by quitting inside the 10-second window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: MailStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store, store.pendingSend != nil else { return .terminateNow }
        Task { @MainActor in
            await store.flushPendingSend()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

@main
struct PerfectMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = MailStore()
    @AppStorage("fontScale") private var fontScale = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .tint(.notionAccent)
                .frame(minWidth: 900, minHeight: 560)
                .onAppear { AppDelegate.store = store }
        }
        .commands {
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
