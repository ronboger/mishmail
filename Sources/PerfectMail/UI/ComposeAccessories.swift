import SwiftUI

// MARK: - Snippets panel

/// Inline snippet picker that slides up above the compose footer: search,
/// name + preview rows, insert on click, delete on hover. Lives inside the
/// card (not a popover) so it always presents and stays where you write.
struct SnippetsPanel: View {
    @EnvironmentObject var store: MailStore

    let insert: (Snippet) -> Void
    let saveDraftAsSnippet: () -> Void
    let close: () -> Void

    @State private var query = ""
    @State private var refresh = 0

    private var snippets: [Snippet] {
        _ = refresh
        return store.snippets()
    }
    private var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return snippets }
        return snippets.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title, search, close.
            HStack(spacing: 8) {
                Text("Snippets")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if snippets.count > 4 {
                    HStack(spacing: 4) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                        TextField("Search", text: $query)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                            .frame(maxWidth: 160)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close snippets")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)

            Divider()

            if snippets.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No snippets yet")
                        .font(.system(size: 12, weight: .medium))
                    Text("Save reusable text — a sign-off, an intro, a scheduling reply — then insert it here with one click.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
            } else if filtered.isEmpty {
                Text("No snippets match “\(query)”")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(10)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { snippet in
                            SnippetRow(snippet: snippet,
                                       insert: { insert(snippet) },
                                       delete: { store.deleteSnippet(snippet); refresh += 1 })
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 132)
            }

            Divider()

            Button(action: saveDraftAsSnippet) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Save draft as snippet")
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .help("Saves the current message body as a new snippet")
        }
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let insert: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: insert) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(snippet.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Insert “\(snippet.name)”")

            if hovering {
                Button(action: insert) {
                    Text("Insert")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(Color.notionAccent)
                }
                .buttonStyle(.plain)
                Button(action: delete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Delete this snippet")
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 4)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .onHover { hovering = $0 }
    }
}

// MARK: - Schedule send (custom date & time)

/// Window sheet for picking an exact send time. A sheet (not a popover)
/// because the compose card hugs the window edge, where popovers can fail
/// to present.
struct ScheduleSendSheet: View {
    @Environment(\.dismiss) private var dismiss
    let schedule: (Date) -> Void

    @State private var date = SendSchedule.tomorrowMorning.date()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Schedule send")
                .font(.system(size: 13, weight: .semibold))

            DatePicker("", selection: $date, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack(spacing: 8) {
                Text("Time")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Sends \(SendSchedule.describe(date))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("while PerfectMail is open")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Schedule") {
                    schedule(date)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(date <= Date())
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
