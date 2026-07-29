import SwiftUI
import AppKit

/// Notion-style date picker shared by snooze (window overlay) and schedule-send
/// (sheet): type a natural-language date ("tomorrow", "fri 3pm", "in 2 weeks",
/// "aug 12") and pick from live suggestions, or choose a preset. Fully
/// keyboard-driven: ↑/↓ move, Return picks, Esc cancels.
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
    /// Overlay presenters (snooze) clear their own state via this callback.
    /// Sheet presenters (schedule-send) leave it nil and rely on environment
    /// `dismiss()`. Never call environment `dismiss` when this is set —
    /// without an enclosing presentation, DismissAction can fall through to
    /// closing the window on some macOS versions.
    var onCancel: (() -> Void)? = nil
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
        DatePickRows.rows(
            query: query,
            presets: presets.map { ($0.title, $0.date) },
            clearOption: clearOption,
            minDate: minDate
        ).map { Option(title: $0.title, detail: $0.detail, action: $0.action) }
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
            // Focus in the same turn so the first typed character lands in
            // the field — no sheet-presentation race to wait out.
            fieldFocused = true
            installKeys()
        }
        .onDisappear { removeKeys() }
    }

    private func choose(_ option: Option) {
        // Pick first: for snooze, `pick` clears the overlay item without
        // animation and runs auto-advance in the same update. Only call
        // environment `dismiss()` for sheet presenters (schedule-send).
        if let action = option.action { pick(action) }
        if onCancel == nil { dismiss() }
    }

    private func cancel() {
        if let onCancel {
            onCancel()
        } else {
            dismiss()
        }
    }

    /// Owns ↑/↓/Return/Esc while open. ContentView's monitor stands down
    /// when `snoozingThread != nil` so these events aren't double-handled.
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
                cancel()
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

/// Snooze flavor of the shared picker, presented as a window overlay (not a
/// modal sheet) so options appear in the same frame as the `b` keypress —
/// same pattern as LabelPicker / CommandPalette. Passing nil to `snooze`
/// unsnoozes.
struct SnoozeSheet: View {
    let current: Date?
    let snooze: (Date?) -> Void
    let cancel: () -> Void

    /// Daypart-aware list (this morning after midnight, drop evening past 6pm, …).
    private var presets: [DatePickSheet.Preset] {
        SnoozePresets.presets().map { .init(title: $0.title, date: $0.date) }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)

            DatePickSheet(
                placeholder: "When? — try \"tomorrow\", \"fri 3pm\", \"aug 12\"",
                presets: presets,
                clearOption: current != nil ? ("Unsnooze", "back to inbox") : nil,
                footnote: current.map { "Currently snoozed until \(SnoozeDateParser.format($0))" },
                onCancel: cancel,
                pick: snooze
            )
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.lg))
            .pmCardElevation(cornerRadius: PMRadius.lg, intense: true)
            .padding(.top, 120)
        }
    }
}
