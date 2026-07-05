import SwiftUI

/// Settings pane: rebind the Gmail-style single-key shortcuts. Click a
/// key capsule, press the new key; conflicts are refused with a warning.
struct ShortcutsSettings: View {
    @ObservedObject var bindings: KeyBindings
    @State private var listening: ShortcutCommand?
    @State private var warning: String?
    @State private var monitor: Any?

    var body: some View {
        PaneScaffold(title: "Keyboard shortcuts",
                     subtitle: "Click a key to change it, then press the new key. Press ? in the app to see every shortcut.") {
            Form {
                ForEach(KeyBindings.Category.allCases, id: \.self) { category in
                    Section(category.rawValue) {
                        ForEach(KeyBindings.catalog.filter { $0.category == category }) { spec in
                            row(spec)
                        }
                    }
                }
                Section {
                    HStack {
                        Button("Reset to defaults") {
                            bindings.resetToDefaults()
                            warning = nil
                        }
                        Spacer()
                        if let warning {
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.system(size: 12))
                                .foregroundStyle(.orange)
                        }
                    }
                } footer: {
                    Text("Single keys only — g and ? are reserved, and ⌘ shortcuts can't be changed yet.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
        .onDisappear { stopListening() }
    }

    private func row(_ spec: ShortcutSpec) -> some View {
        LabeledContent(spec.title) {
            Button {
                if listening == spec.command { stopListening() } else { startListening(spec.command) }
            } label: {
                Text(listening == spec.command ? "Press a key…" : bindings.key(for: spec.command))
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .frame(minWidth: 44)
                    .padding(.vertical, 3).padding(.horizontal, 8)
                    .background(listening == spec.command
                                    ? Color.accentColor.opacity(0.18)
                                    : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
    }

    private func startListening(_ command: ShortcutCommand) {
        stopListening()
        listening = command
        bindings.capturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            defer { stopListening() }
            if event.keyCode == 53 { return nil }  // esc cancels
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            guard mods.isEmpty,
                  let chars = event.charactersIgnoringModifiers, !chars.isEmpty
            else {
                warning = "Only single keys without ⌘/⌥/⌃ can be used."
                return nil
            }
            switch bindings.rebind(command, to: chars) {
            case .ok:
                warning = nil
            case .conflict(let other):
                warning = "“\(chars)” is already used by \(KeyBindings.title(for: other))."
            case .rejected(let message):
                warning = message
            }
            return nil
        }
    }

    private func stopListening() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        listening = nil
        bindings.capturing = false
    }
}
