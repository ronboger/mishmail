import SwiftUI

struct ThreadListView: View {
    @EnvironmentObject var store: MailStore

    private var grouped: [(String, [MailThread])] {
        let cal = Calendar.current
        let now = Date()
        var groups: [(String, [MailThread])] = []
        var buckets: [String: [MailThread]] = [:]
        let order = ["Today", "Yesterday", "Last 7 days", "Last 30 days", "Older"]
        for thread in store.threads {
            let key: String
            if cal.isDateInToday(thread.lastDate) { key = "Today" }
            else if cal.isDateInYesterday(thread.lastDate) { key = "Yesterday" }
            else if thread.lastDate > now.addingTimeInterval(-7 * 86400) { key = "Last 7 days" }
            else if thread.lastDate > now.addingTimeInterval(-30 * 86400) { key = "Last 30 days" }
            else { key = "Older" }
            buckets[key, default: []].append(thread)
        }
        for key in order where buckets[key] != nil {
            groups.append((key, buckets[key]!))
        }
        return groups
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar()
            Divider()
            List(selection: $store.selectedThreadId) {
                ForEach(grouped, id: \.0) { title, threads in
                    Section(title) {
                        ForEach(threads) { thread in
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
                                .contextMenu { threadMenu(thread) }
                        }
                    }
                }
            }
        }
        .navigationTitle(store.selectedView.title)
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
        .overlay(alignment: .bottom) {
            if let undo = store.undoAction {
                HStack(spacing: 12) {
                    Text(undo.label)
                    Button("Undo") { undo.undo() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut("z", modifiers: .command)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(radius: 8)
                .padding(.bottom, 12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.undoAction?.id)
    }

    @ViewBuilder
    private func threadMenu(_ thread: MailThread) -> some View {
        Button("Archive") { store.archive(thread) }
        Button(thread.isStarred ? "Unstar" : "Star") { store.toggleStar(thread) }
        Button(thread.isUnread ? "Mark Read" : "Mark Unread") {
            store.setRead(thread, read: thread.isUnread)
        }
        Menu("Snooze") {
            Button("This evening (6 PM)") { store.snooze(thread, until: MailStore.snoozeDate(hour: 18)) }
            Button("Tomorrow morning (8 AM)") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 1)) }
            Button("Next week") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 7)) }
            if thread.snoozeUntil != nil {
                Button("Unsnooze") { store.snooze(thread, until: nil) }
            }
        }
        Menu("Remind me") {
            Button("Tomorrow") { store.setReminder(thread, after: 1) }
            Button("In 3 days") { store.setReminder(thread, after: 3) }
            Button("In a week") { store.setReminder(thread, after: 7) }
            if thread.reminderAt != nil {
                Button("Clear reminder") { store.setReminder(thread, after: nil) }
            }
        }
        Divider()
        Button("Trash", role: .destructive) { store.trash(thread) }
    }
}

/// Notion Mail-style filter chips above the list.
struct FilterBar: View {
    @EnvironmentObject var store: MailStore
    @State private var senderDraft = ""

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Button("Any label") { store.chips.labelId = nil; store.chips.labelName = nil }
                    ForEach(allLabels, id: \.gmailLabelId) { label in
                        Button(label.name) {
                            store.chips.labelId = label.gmailLabelId
                            store.chips.labelName = label.name
                        }
                    }
                } label: {
                    chipLabel(store.chips.labelName.map { "Label: \($0)" } ?? "Labels",
                              icon: "tag", active: store.chips.labelId != nil)
                }
                .menuStyle(.borderlessButton).fixedSize()

                chipToggle("Is unread", icon: "envelope.badge", isOn: $store.chips.unreadOnly)
                chipToggle("Show archived", icon: "archivebox", isOn: $store.chips.showArchived)
                chipToggle("Has attachment", icon: "paperclip", isOn: $store.chips.hasAttachmentOnly)

                TextField("From…", text: $senderDraft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
                    .onSubmit { store.chips.senderContains = senderDraft }

                if store.chips.isActive {
                    Button {
                        store.chips = FilterChips()
                        senderDraft = ""
                    } label: {
                        Label("Clear", systemImage: "xmark.circle.fill")
                            .font(.caption)
                    }
                    .buttonStyle(.plain).foregroundStyle(.secondary)

                    Button("Save as view…") {
                        var v = SavedView.empty()
                        v.name = store.selectedView.title + " (filtered)"
                        v.labelId = store.chips.labelId
                        v.unreadOnly = store.chips.unreadOnly
                        v.showArchived = store.chips.showArchived
                        v.hasAttachmentOnly = store.chips.hasAttachmentOnly
                        v.senderContains = store.chips.senderContains
                        if case .inbox = store.selectedView { v.excludePromotions = true }
                        store.editingView = v
                    }
                    .font(.caption).buttonStyle(.link)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    private var allLabels: [LabelRow] {
        let labels = store.labelsByAccount.values.flatMap { $0 }
        var seen = Set<String>()
        return labels.filter { seen.insert($0.gmailLabelId).inserted }.sorted { $0.name < $1.name }
    }

    private func chipLabel(_ title: String, icon: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption)
            Text(title).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(active ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                    in: Capsule())
    }

    private func chipToggle(_ title: String, icon: String, isOn: Binding<Bool>) -> some View {
        Button { isOn.wrappedValue.toggle() } label: {
            chipLabel(title, icon: icon, active: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
    }
}

struct ThreadRow: View {
    @EnvironmentObject var store: MailStore
    let thread: MailThread
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(thread.isUnread ? Color.accentColor : .clear)
                .frame(width: 8, height: 8)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(participantsDisplay)
                        .font(.system(size: 13, weight: thread.isUnread ? .semibold : .regular))
                        .lineLimit(1)
                    if thread.messageCount > 1 {
                        Text("\(thread.messageCount)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if !hovering {
                        if thread.hasAttachment {
                            Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                        }
                        if thread.reminderAt != nil {
                            Image(systemName: "bell.fill").font(.caption2).foregroundStyle(.orange)
                        }
                        if thread.isStarred {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        }
                        Text(thread.lastDate, format: relativeFormat)
                            .font(.caption).foregroundStyle(.secondary)
                    }
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
        .overlay(alignment: .topTrailing) {
            if hovering {
                HStack(spacing: 2) {
                    hoverButton("star", filled: thread.isStarred) { store.toggleStar(thread) }
                    hoverButton("archivebox") { store.archive(thread) }
                    hoverButton("clock") { store.snooze(thread, until: MailStore.snoozeDate(hour: 8, addDays: 1)) }
                    hoverButton("trash") { store.trash(thread) }
                }
                .padding(4)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .onHover { hovering = $0 }
    }

    private var participantsDisplay: String {
        thread.participants.isEmpty ? thread.fromDisplay : thread.participants
    }

    private func hoverButton(_ icon: String, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: filled ? "\(icon).fill" : icon)
                .font(.system(size: 11))
        }
        .buttonStyle(.plain)
        .padding(3)
    }

    private var relativeFormat: Date.FormatStyle {
        Calendar.current.isDateInToday(thread.lastDate)
            ? .dateTime.hour().minute()
            : .dateTime.month(.abbreviated).day()
    }
}
