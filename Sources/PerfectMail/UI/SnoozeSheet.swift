import SwiftUI
import AppKit

/// Notion-style snooze picker: type a natural-language date ("tomorrow",
/// "fri 3pm", "in 2 weeks", "aug 12") and pick from live suggestions, or
/// choose a preset. Fully keyboard-driven: ↑/↓ move, Return snoozes,
/// Esc cancels. Passing nil to `snooze` unsnoozes.
struct SnoozeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: Date?
    let snooze: (Date?) -> Void

    @State private var query = ""
    @State private var highlight = 0
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private struct Option: Identifiable {
        let title: String
        let detail: String
        let action: Date??   // .some(date) snooze, .some(nil) unsnooze
        var id: String { title + detail }
    }

    private static func nextWeekday(_ weekday: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let day = cal.nextDate(after: Date(), matching: DateComponents(weekday: weekday),
                               matchingPolicy: .nextTime)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private var options: [Option] {
        var list: [Option] = []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            let evening = MailStore.snoozeDate(hour: 18)
            var presets: [(String, Date)] = []
            if evening > Date() { presets.append(("This evening", evening)) }
            presets.append(("Tomorrow morning", MailStore.snoozeDate(hour: 8, addDays: 1)))
            presets.append(("This weekend", Self.nextWeekday(7, hour: 8)))
            presets.append(("Next week", Self.nextWeekday(2, hour: 8)))
            list = presets.map { Option(title: $0.0, detail: SnoozeDateParser.format($0.1), action: $0.1) }
        } else {
            list = SnoozeDateParser.suggestions(for: query).map { s in
                let parts = s.label.components(separatedBy: "  ·  ")
                return Option(title: parts.first ?? s.label,
                              detail: parts.count > 1 ? parts[1] : "",
                              action: s.date)
            }
        }
        if current != nil {
            list.append(Option(title: "Unsnooze", detail: "back to inbox", action: .some(nil)))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("When? — try \"tomorrow\", \"fri 3pm\", \"aug 12\"", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($fieldFocused)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .onChange(of: query) { highlight = 0 }

            if options.isEmpty {
                Text("No date matches — try \"tomorrow\", \"friday\", \"in 3 days\", \"aug 12 5pm\"")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                VStack(spacing: 1) {
                    ForEach(Array(options.enumerated()), id: \.element.id) { i, option in
                        Button { choose(option) } label: {
                            HStack {
                                Text(option.title).font(.system(size: 13))
                                Spacer()
                                Text(option.detail)
                                    .font(.system(size: 12))
                                    .foregroundStyle(i == highlight ? Color.white.opacity(0.85) : Color.secondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(i == highlight ? Color.accentColor : .clear,
                                    in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(i == highlight ? Color.white : Color.primary)
                        .onHover { if $0 { highlight = i } }
                    }
                }
            }

            if let current {
                Divider()
                Text("Currently snoozed until \(SnoozeDateParser.format(current))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 340)
        .onAppear {
            fieldFocused = true
            installKeys()
        }
        .onDisappear { removeKeys() }
    }

    private func choose(_ option: Option) {
        if let action = option.action { snooze(action) }
        dismiss()
    }

    /// The sheet owns the keyboard while it's up (the main window's monitor
    /// stands down when a snooze sheet is presented): ↑/↓ move the highlight
    /// even while typing, Return picks, Esc closes.
    private func installKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 125:  // down
                highlight = min(highlight + 1, max(options.count - 1, 0))
                return nil
            case 126:  // up
                highlight = max(highlight - 1, 0)
                return nil
            case 36, 76:  // return / keypad enter
                if options.indices.contains(highlight) { choose(options[highlight]) }
                return nil
            case 53:  // esc
                dismiss()
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
