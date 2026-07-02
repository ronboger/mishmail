import SwiftUI

@main
struct PerfectMailApp: App {
    @StateObject private var store = MailStore()

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
        }
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
