import SwiftUI

/// Compose "From" control: a keyboard-first identity picker.
///
/// It sits in the Tab loop right before To, so ⇧Tab from the recipient field
/// lands here (`interactions: .edit` keeps it reachable without macOS "Full
/// Keyboard Access"). Once focused:
/// - ↑/↓ or ←/→ change the sender at once (closed) or move the highlight (open).
/// - Space / ↩ open the list; ↩ / Space again commit the highlighted row.
/// - Typing a letter jumps to the next address or name starting with it.
/// - Esc closes the list (ContentView routes it via `store.dismissFromPicker`).
/// - Tab moves on to To; ⇧Tab moves back to the previous control.
///
/// The list is an in-window overlay (not a Menu/popover) so the focused
/// control keeps receiving key presses while it is open.
struct FromIdentityPicker: View {
    @Environment(MailStore.self) private var store
    let identities: [SendIdentity]
    @Binding var selectedId: String
    /// Text shown on the closed control (ComposeView decides how identities
    /// are titled so the closed and open forms agree).
    let closedLabel: String
    let rowTitle: (SendIdentity) -> String

    @FocusState private var focused: Bool
    @State private var isOpen = false
    @State private var highlighted: Int?
    @State private var hovering = false

    private var selectedIndex: Int? {
        identities.firstIndex { $0.id == selectedId }
    }

    private var canChoose: Bool { identities.count > 1 }

    var body: some View {
        HStack(spacing: 6) {
            Text(closedLabel)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            if canChoose {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(focused ? Color.notionAccent : .secondary)
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: PMRadius.sm)
                .fill(chromeFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PMRadius.sm)
                .strokeBorder(Color.notionAccent.opacity(focused ? 0.9 : 0), lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.12), value: focused)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityIdentifier("compose.from")
        .accessibilityLabel("From")
        .accessibilityValue(closedLabel)
        .accessibilityAddTraits(.isButton)
        .help(canChoose ? "Sending address — ⇧Tab from To, then ↑↓ or Space"
                        : "Only one sending address for this message")
        .focusable(true, interactions: .edit)
        .focused($focused)
        .focusEffectDisabled()
        .onTapGesture {
            focused = true
            toggle()
        }
        .onKeyPress(.downArrow) { move(1) }
        .onKeyPress(.upArrow) { move(-1) }
        .onKeyPress(.rightArrow) { move(1) }
        .onKeyPress(.leftArrow) { move(-1) }
        .onKeyPress(.return) { activate() }
        .onKeyPress(.space) { activate() }
        .onKeyPress(.escape) {
            guard isOpen else { return .ignored }
            close()
            return .handled
        }
        .onKeyPress(characters: .alphanumerics, phases: .down) { press in
            guard let index = FromPickerModel.match(
                prefix: press.characters, in: identities,
                after: isOpen ? highlighted : selectedIndex) else { return .ignored }
            if isOpen { highlighted = index } else { choose(index) }
            return .handled
        }
        .onChange(of: focused) {
            // Tabbing away (or a click elsewhere) must not leave the list up.
            if !focused, isOpen { close() }
        }
        .onChange(of: isOpen) { store.fromPickerOpen = isOpen }
        .onChange(of: store.fromPickerDismissToken) { if isOpen { close() } }
        .onDisappear {
            if isOpen { store.fromPickerOpen = false }
        }
        .overlay(alignment: .topLeading) {
            if isOpen { list }
        }
        .zIndex(isOpen ? 20 : 0)
    }

    private var chromeFill: Color {
        if focused { return Color.notionAccent.opacity(0.10) }
        if hovering, canChoose { return Color.primary.opacity(0.06) }
        return .clear
    }

    // MARK: Open list

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(identities.enumerated()), id: \.element.id) { index, identity in
                row(identity, at: index)
            }
            Divider().padding(.vertical, 2)
            HStack(spacing: 10) {
                hint("↑↓", "move")
                hint("↩", "select")
                hint("esc", "close")
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .padding(4)
        .frame(width: 340, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: PMRadius.md))
        .overlay(RoundedRectangle(cornerRadius: PMRadius.md).strokeBorder(.separator))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .offset(y: 30)
        .transition(.opacity.combined(with: .offset(y: -4)))
        .accessibilityIdentifier("compose.from.list")
    }

    private func row(_ identity: SendIdentity, at index: Int) -> some View {
        let isSelected = identity.id == selectedId
        let isHighlighted = highlighted == index
        let detail = FromPickerModel.detail(for: identity)
        return Button {
            choose(index)
            DispatchQueue.main.async { focused = true }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.notionAccent)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: 12)
                VStack(alignment: .leading, spacing: 1) {
                    Text(rowTitle(identity))
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if identity.isDefault {
                    Text("Default")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06),
                                    in: Capsule())
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(isHighlighted ? Color.notionAccent.opacity(0.16) : .clear,
                        in: RoundedRectangle(cornerRadius: PMRadius.xs))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { if $0 { highlighted = index } }
        .accessibilityIdentifier("compose.from.row.\(identity.email)")
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(Color.primary.opacity(0.07),
                            in: RoundedRectangle(cornerRadius: 3))
            Text(label).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: Actions

    private func toggle() {
        if isOpen { close() } else { open() }
    }

    private func open() {
        guard !identities.isEmpty else { return }
        highlighted = selectedIndex ?? 0
        withAnimation(.easeOut(duration: 0.14)) { isOpen = true }
    }

    private func close() {
        withAnimation(.easeOut(duration: 0.12)) { isOpen = false }
    }

    private func choose(_ index: Int) {
        guard identities.indices.contains(index) else { return }
        selectedId = identities[index].id
        if isOpen { close() }
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard focused, !identities.isEmpty else { return .ignored }
        if isOpen {
            highlighted = FromPickerModel.step(from: highlighted, by: delta,
                                               count: identities.count)
        } else if let next = FromPickerModel.step(from: selectedIndex, by: delta,
                                                  count: identities.count) {
            choose(next)
        }
        return .handled
    }

    private func activate() -> KeyPress.Result {
        guard focused else { return .ignored }
        if isOpen {
            if let highlighted { choose(highlighted) } else { close() }
        } else {
            open()
        }
        return .handled
    }
}
