import SwiftUI

/// Gmail-style "?" cheat sheet: every shortcut, grouped, with any custom
/// bindings reflected live. Dismiss with Esc, ?, or the Done button.
struct ShortcutsHelpView: View {
    @ObservedObject var bindings: KeyBindings
    @Environment(\.dismiss) private var dismiss

    /// Fixed (non-rebindable) shortcuts, shown for reference.
    private static let fixed: [(section: String, rows: [(key: String, title: String)])] = [
        ("Go to (press g, then…)", [
            ("g i", "Inbox"), ("g s", "Starred"), ("g t", "Sent"),
            ("g d", "Drafts"), ("g a", "All mail"), ("g p", "Promotions"),
        ]),
        ("Other", [
            ("↑ / ↓", "Browse conversations"),
            ("← / →", "Hide / show sidebar"),
            ("Return", "Open conversation"),
            ("⌘↩", "Focus conversation full-app (Send while composing)"),
            ("⇧⌘↩", "Compose side by side with the conversation"),
            ("x", "Select / deselect (multi-select)"),
            ("Shift-click checkbox", "Select a range"),
            ("/", "Search"),
            ("Esc", "Drop field focus → clear checks → exit focus → clear search → close pane"),
            ("⌘K", "Command palette (Insert link while composing)"),
            ("/ (in compose)", "Snippet picker (typed in body)"),
            ("⌘/", "Snippets panel (in compose)"),
            ("⌘⇧V", "Paste without formatting"),
            ("⌃F", "Filter menu"),
            ("⌘⇧R", "Sync all"),
            ("⌘+ / ⌘− / ⌘0", "Text size"),
            ("⌘,", "Settings"),
            ("?", "This help"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Keyboard shortcuts").font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 10)
            Divider().padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(KeyBindings.Category.allCases, id: \.self) { category in
                        section(category.rawValue,
                                rows: KeyBindings.catalog.filter { $0.category == category }
                                    .map { (bindings.key(for: $0.command), $0.title) })
                    }
                    ForEach(Self.fixed, id: \.section) { group in
                        section(group.section, rows: group.rows)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 520)
    }

    private func section(_ title: String, rows: [(key: String, title: String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            ForEach(rows, id: \.title) { row in
                HStack {
                    Text(row.key)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(.vertical, 2).padding(.horizontal, 6)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                        .frame(minWidth: 90, alignment: .leading)
                    Text(row.title).font(.system(size: 13))
                    Spacer()
                }
            }
        }
    }
}
