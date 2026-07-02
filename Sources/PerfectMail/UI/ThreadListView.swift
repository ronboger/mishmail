import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        List(store.threads, selection: $store.selectedThreadId) { thread in
            ThreadRow(thread: thread)
                .tag(thread.id)
                .swipeActions(edge: .trailing) {
                    Button { store.archive(thread) } label: {
                        Label("Archive", systemImage: "archivebox")
                    }.tint(.green)
                    Button(role: .destructive) { store.trash(thread) } label: {
                        Label("Trash", systemImage: "trash")
                    }
                }
                .contextMenu {
                    Button("Archive") { store.archive(thread) }
                    Button(thread.isStarred ? "Unstar" : "Star") { store.toggleStar(thread) }
                    Button(thread.isUnread ? "Mark Read" : "Mark Unread") {
                        store.setRead(thread, read: thread.isUnread)
                    }
                    Menu("Snooze") {
                        Button("This evening (6 PM)") { store.snooze(thread, until: snoozeDate(hour: 18)) }
                        Button("Tomorrow morning (8 AM)") { store.snooze(thread, until: snoozeDate(hour: 8, addDays: 1)) }
                        Button("Next week") { store.snooze(thread, until: snoozeDate(hour: 8, addDays: 7)) }
                        if thread.snoozeUntil != nil {
                            Button("Unsnooze") { store.snooze(thread, until: nil) }
                        }
                    }
                    Divider()
                    Button("Trash", role: .destructive) { store.trash(thread) }
                }
        }
        .navigationTitle(store.selectedView.title)
        // Keyboard shortcuts on the focused list selection.
        .background {
            Group {
                shortcutButton("e") { selected.map(store.archive) }
                shortcutButton("#") { selected.map(store.trash) }
                shortcutButton("s") { selected.map(store.toggleStar) }
                shortcutButton("u") { if let t = selected { store.setRead(t, read: t.isUnread) } }
                shortcutButton("h") { if let t = selected { store.snooze(t, until: snoozeDate(hour: 8, addDays: 1)) } }
                shortcutButton("j") { moveSelection(1) }
                shortcutButton("k") { moveSelection(-1) }
            }
            .opacity(0)
        }
        .overlay {
            if store.threads.isEmpty {
                ContentUnavailableView(
                    store.accounts.isEmpty ? "No accounts connected" : "Nothing here",
                    systemImage: store.accounts.isEmpty ? "person.crop.circle.badge.plus" : "tray",
                    description: Text(store.accounts.isEmpty
                        ? "Add a Google account from the sidebar to get started."
                        : "You're all caught up.")
                )
            }
        }
    }

    private var selected: MailThread? {
        store.threads.first { $0.id == store.selectedThreadId }
    }

    private func moveSelection(_ delta: Int) {
        guard !store.threads.isEmpty else { return }
        let idx = store.threads.firstIndex { $0.id == store.selectedThreadId } ?? -delta.signum().clamped()
        let next = min(max(idx + delta, 0), store.threads.count - 1)
        store.selectedThreadId = store.threads[next].id
    }

    private func shortcutButton(_ key: Character, action: @escaping () -> Void) -> some View {
        Button(action: action) { EmptyView() }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [])
    }

    private func snoozeDate(hour: Int, addDays: Int = 0) -> Date {
        var cal = Calendar.current
        cal.timeZone = .current
        let base = cal.date(byAdding: .day, value: addDays, to: Date())!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: base)!
    }
}

private extension Int {
    func clamped() -> Int { self < 0 ? 0 : self }
}

struct ThreadRow: View {
    let thread: MailThread

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.fromDisplay)
                        .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    Spacer()
                    if thread.isStarred {
                        Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                    }
                    Text(thread.lastDate, format: relativeFormat)
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(thread.subject.isEmpty ? "(no subject)" : thread.subject)
                    .font(.system(size: 12, weight: thread.isUnread ? .medium : .regular))
                    .lineLimit(1)
                Text(thread.snippet)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var relativeFormat: Date.FormatStyle {
        Calendar.current.isDateInToday(thread.lastDate)
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
    }
}
