import SwiftUI
import AppKit

/// Notion-style date picker sheet shared by snooze and schedule-send: type a
/// natural-language date ("tomorrow", "fri 3pm", "in 2 weeks", "aug 12") and
/// pick from live suggestions, or choose a preset. Fully keyboard-driven:
/// ↑/↓ move, Return picks, Esc cancels.
struct DatePickSheet: View {
    struct Preset {
        let title: String
        let date: Date
    }

    @Environment(\.dismiss) private var dismiss
    let placeholder: String
    let presets: [Preset]
    /// Extra row that picks `nil` (e.g. "Unsnooze"); omitted when absent.
    var clearOption: (title: String, detail: String)?
    /// Small caption under the divider (e.g. "Currently snoozed until …").
    var footnote: String?
    /// Reject typed suggestions at or before this instant (send times must
    /// be in the future; snooze accepts whatever the parser offers).
    var minDate: Date?
    let pick: (Date?) -> Void

    @State private var query = ""
    @State private var highlight = 0
    @State private var keyMonitor: Any?
    @FocusState private var fieldFocused: Bool

    private struct Option: Identifiable {
        let title: String
        let detail: String
        let action: Date??   // .some(date) picks a date, .some(nil) clears
        var id: String { title + detail }
    }

    private var options: [Option] {
        var list: [Option] = []
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            list = presets.map {
                Option(title: $0.title, detail: SnoozeDateParser.format($0.date), action: $0.date)
            }
        } else {
            list = SnoozeDateParser.suggestions(for: query)
                .filter { s in minDate.map { s.date > $0 } ?? true }
                .map { s in
                    let parts = s.label.components(separatedBy: "  ·  ")
                    return Option(title: parts.first ?? s.label,
                                  detail: parts.count > 1 ? parts[1] : "",
                                  action: s.date)
                }
        }
        if let clearOption {
            list.append(Option(title: clearOption.title, detail: clearOption.detail,
                               action: .some(nil)))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField(placeholder, text: $query)
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

            if let footnote {
                Divider()
                Text(footnote)
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
        if let action = option.action { pick(action) }
        dismiss()
    }

    /// The sheet owns the keyboard while it's up (the main window's monitor
    /// stands down or passes text-field events through): ↑/↓ move the
    /// highlight even while typing, Return picks, Esc closes.
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

/// Snooze flavor of the shared picker. Passing nil to `snooze` unsnoozes.
struct SnoozeSheet: View {
    let current: Date?
    let snooze: (Date?) -> Void

    private static func nextWeekday(_ weekday: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let day = cal.nextDate(after: Date(), matching: DateComponents(weekday: weekday),
                               matchingPolicy: .nextTime)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private var presets: [DatePickSheet.Preset] {
        var list: [DatePickSheet.Preset] = []
        let evening = MailStore.snoozeDate(hour: 18)
        if evening > Date() { list.append(.init(title: "This evening", date: evening)) }
        list.append(.init(title: "Tomorrow morning", date: MailStore.snoozeDate(hour: 8, addDays: 1)))
        list.append(.init(title: "This weekend", date: Self.nextWeekday(7, hour: 8)))
        list.append(.init(title: "Next week", date: Self.nextWeekday(2, hour: 8)))
        return list
    }

    var body: some View {
        DatePickSheet(
            placeholder: "When? — try \"tomorrow\", \"fri 3pm\", \"aug 12\"",
            presets: presets,
            clearOption: current != nil ? ("Unsnooze", "back to inbox") : nil,
            footnote: current.map { "Currently snoozed until \(SnoozeDateParser.format($0))" },
            pick: snooze)
    }
}
