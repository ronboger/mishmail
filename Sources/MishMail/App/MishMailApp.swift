import SwiftUI

/// On quit: flush a pending undo-send (so mail isn't lost inside the 10s
/// window) and shut down database work before process teardown. Background
/// GRDB readers must finish before SQLCipher's atexit shutdown or we crash
/// in sqlcipher_page_hmac (use-after-free on a live reader connection).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var store: MailStore?
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Apply a forced Light/Dark theme before the first window draws so a
        // non-system choice doesn't flash the system appearance at launch.
        AppTheme.apply(.current)
        // Compile the remote-image content rule once so the first message open
        // never pays the WKContentRuleList async hop.
        HTMLRemoteImageBlocker.prepareAtLaunch()
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main)
        source.setEventHandler {
            HTMLWebViewPool.drain()
        }
        source.resume()
        memoryPressureSource = source
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store = Self.store else { return .terminateNow }
        // The updater quits via `NSApp.terminate` from inside a main-actor
        // task, after awaiting this same shutdown. Answering `.terminateLater`
        // there deadlocks: AppKit spins a nested event loop inside `terminate`
        // waiting for the reply, but a nested loop can't re-enter the main
        // dispatch queue while the updater's callout is still on the stack, so
        // the replying Task below never runs. When the shutdown has already
        // run to completion there is nothing left to wait for — quit
        // synchronously.
        guard !store.hasCompletedTermination else { return .terminateNow }
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

/// One shared, persisted scale ladder for Settings and the text-size commands.
/// Keeping the values discrete avoids floating-point drift after repeated Cmd +
/// or Cmd − presses and lets Settings always select a real option.
enum AppFontScale {
    struct Option: Identifiable {
        let value: Double
        let title: String
        var id: Double { value }
    }

    static let options: [Option] = [
        .init(value: 0.8, title: "Smallest"),
        .init(value: 0.9, title: "Small"),
        .init(value: 1.0, title: "Default"),
        .init(value: 1.15, title: "Large"),
        .init(value: 1.3, title: "Extra Large"),
        .init(value: 1.45, title: "Huge"),
        .init(value: 1.6, title: "Largest"),
    ]

    static func closest(_ value: Double) -> Double {
        options.min { abs($0.value - value) < abs($1.value - value) }?.value ?? 1.0
    }

    static func step(_ value: Double, direction: Int) -> Double {
        let current = closest(value)
        guard let index = options.firstIndex(where: { $0.value == current }) else {
            return current
        }
        let next = min(max(index + direction, 0), options.count - 1)
        return options[next].value
    }
}

@main
struct MishMailApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = MailStore()
    @AppStorage("fontScale") private var fontScale = 1.0
    @AppStorage(AppTheme.storageKey) private var appThemeRaw = AppTheme.system.rawValue

    private var hasMessageSelection: Bool {
        store.selectedThread != nil || !store.checkedThreadIds.isEmpty
    }

    private var hasSingleThreadSelection: Bool {
        store.selectedThread != nil
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environmentObject(store.listFocus)
                .tint(.notionAccent)
                .frame(minWidth: 900, minHeight: 560)
                .onChange(of: appThemeRaw) {
                    AppTheme.apply(.from(raw: appThemeRaw))
                }
                .onAppear {
                    AppDelegate.store = store
                    AppTheme.apply(.from(raw: appThemeRaw))
                    RemoteImagePolicy.migrateIfNeeded()
                    UpdateChecker.shared.prepareForQuit = { [weak store] in
                        await store?.prepareForTermination()
                    }
                    UpdateChecker.shared.hasOpenDraft = { [weak store] in
                        store?.composeRequest != nil
                    }
                    UpdateChecker.shared.startPeriodicChecks()
                }
                // mailto: from browsers / other apps when we're the default
                // email reader (Settings → General can claim that role).
                .onOpenURL { store.handleOpenURL($0) }
                // Route external URLs to the window that is already open.
                // Without this a WindowGroup answers a mailto: from another
                // app (browser, Notion Calendar, …) by spawning a second
                // MishMail window — and since both observe the same store,
                // the compose card shows up twice.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
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
            CommandMenu("Message") {
                Button("Reply") { store.perform(.reply) }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!hasSingleThreadSelection)
                Button("Reply All") { store.perform(.replyAll) }
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(!hasSingleThreadSelection)
                Button("Forward") { store.perform(.forward) }
                    .keyboardShortcut("f", modifiers: [.command, .option])
                    .disabled(!hasSingleThreadSelection)
                Divider()
                Button("Archive") { store.perform(.archive) }
                    .keyboardShortcut("a", modifiers: [.command, .control])
                    .disabled(!hasMessageSelection)
                Button("Trash") { store.perform(.trash) }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(!hasMessageSelection)
                Button(store.selectedThread?.isStarred == true ? "Unstar" : "Star") {
                    store.perform(.toggleStar)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!hasMessageSelection)
                Button("Mark Read/Unread") { store.perform(.toggleRead) }
                    .keyboardShortcut("u", modifiers: [.command, .option])
                    .disabled(!hasMessageSelection)
                Button("Snooze…") { store.perform(.snooze) }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(!hasMessageSelection)
                Button("Label…") { store.perform(.label) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                    .disabled(!hasSingleThreadSelection)
            }
            CommandMenu("Go") {
                Button("Inbox") { store.goTo(.inbox) }
                Button("Starred") { store.goTo(.starred) }
                Button("Sent") { store.goTo(.sent) }
                Button("Drafts") { store.goTo(.drafts) }
                Button("All Mail") { store.goTo(.allMail) }
                Button("Trash") { store.goTo(.trash) }
                Button("Snoozed") { store.goTo(.snoozed) }
                Button("Reminders") { store.goTo(.reminders) }
                ForEach(store.savedViews) { view in
                    Button(view.name) {
                        store.goTo(.saved(view.id ?? -1, view.name))
                    }
                }
            }
            // Slack/Chrome/VS Code convention. System "Paste and Match Style"
            // stays on ⌥⇧⌘V; this is the muscle-memory chord for plain paste
            // in any focused text field (compose, subject, search, settings).
            CommandGroup(after: .pasteboard) {
                Button("Paste without Formatting") {
                    NSApp.sendAction(#selector(NSTextView.pasteAsPlainText(_:)), to: nil, from: nil)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Increase Text Size") {
                    fontScale = AppFontScale.step(fontScale, direction: 1)
                }
                    .keyboardShortcut("+", modifiers: .command)
                Button("Decrease Text Size") {
                    fontScale = AppFontScale.step(fontScale, direction: -1)
                }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Reset Text Size") { fontScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
            }
            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts") { store.showShortcutsHelp = true }
            }
        }
        Settings {
            SettingsView()
                .environment(store)
        }
    }
}
