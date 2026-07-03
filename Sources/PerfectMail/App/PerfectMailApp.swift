import SwiftUI

@main
struct PerfectMailApp: App {
    @StateObject private var store = MailStore()
    @AppStorage("fontScale") private var fontScale = 1.0

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 560)
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
