import SwiftUI

// MARK: - Slash snippet picker

/// Compact picker that pops up while typing `/query` in the compose body.
/// The body editor keeps focus and drives it: ↑/↓ move the highlight,
/// Return inserts, Esc dismisses; clicking a row also inserts.
struct SlashSnippetPicker: View {
    let snippets: [Snippet]
    let query: String
    let selection: Int
    let choose: (Snippet) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "text.badge.plus").font(.system(size: 10))
                Text(query.isEmpty ? "Snippets" : "Snippets matching “/\(query)”")
                    .font(.system(size: 10.5, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 4)

            if snippets.isEmpty {
                Text(query.isEmpty
                     ? "No snippets yet — add them in Settings → Snippets."
                     : "No snippet matches “/\(query)”. Keep typing or press esc.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.bottom, 8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(snippets.enumerated()), id: \.element.id) { idx, snippet in
                            Button { choose(snippet) } label: {
                                HStack(spacing: 6) {
                                    Text("/\(snippet.name)")
                                        .font(.system(size: 12, weight: .medium))
                                        .lineLimit(1)
                                    if snippet.movesToBcc {
                                        MovesToBccBadge()
                                    }
                                    Text(snippet.previewLine)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(idx == selection ? Color.notionAccent.opacity(0.14) : .clear,
                                            in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 132)

                Divider()
                Text("↑↓ choose · ⏎ insert · esc dismiss")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10).padding(.vertical, 5)
            }
        }
        .background(Color(nsColor: .textBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
    }
}

/// Small "→ Bcc" tag shown on snippets that move the intro to Bcc on insert.
struct MovesToBccBadge: View {
    var body: some View {
        Text("→ Bcc")
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .help("Inserting moves To recipients to Bcc and promotes Cc to To")
    }
}

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
        snippets.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: title, search, close.
            HStack(spacing: 8) {
                Text("Snippets")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                if snippets.count > 4 {
                    SearchField(prompt: "Search", text: $query, compact: true)
                        .frame(maxWidth: 180)
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
                    HStack(spacing: 6) {
                        Text(snippet.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if snippet.movesToBcc { MovesToBccBadge() }
                    }
                    Text(snippet.previewLine)
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
