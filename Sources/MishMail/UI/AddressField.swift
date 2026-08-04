import SwiftUI

/// Notion Mail-style recipient field: accepted addresses render as chips,
/// with autocomplete backed by contacts mined from synced mail.
///
/// Chips are clickable: click the address to re-open it in the text field for
/// editing (typos, wrong contact). × still removes without editing.
struct TokenAddressField: View {
    @Environment(MailStore.self) var store
    let label: String
    @Binding var tokens: [String]
    @Binding var draft: String
    var autoFocus = false
    @FocusState private var focused: Bool
    @State private var highlighted = 0
    /// Backspace never reaches onKeyPress — the field editor eats it —
    /// so an NSEvent monitor (active only while focused) pops the last chip.
    @State private var keyMonitor: Any?
    /// Hovered chip (for pointer + slightly stronger fill).
    @State private var hoveredToken: String?
    /// True while we've pushed a pointing-hand cursor for a chip hover.
    /// Cleared on hover exit *and* when the chip is removed under the cursor
    /// (click-to-edit / ×), which otherwise skips the exit callback and leaves
    /// a stuck pointing hand.
    @State private var chipCursorPushed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tokens, id: \.self) { token in
                            chip(token)
                        }
                        TextField(tokens.isEmpty ? "Add recipients" : "", text: $draft)
                            .accessibilityIdentifier("addressField.\(label)")
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .frame(minWidth: 160)
                            .focused($focused)
                            .onChange(of: draft) {
                                highlighted = 0
                                if draft.hasSuffix(",") { commitDraft() }
                            }
                            .onChange(of: focused) {
                                // Leaving the field turns typed text into a chip.
                                // Deferred: mutating tokens *during* the Tab
                                // traversal restructures the row mid-move and
                                // AppKit drops the just-granted Subject focus
                                // after the first keystroke.
                                if !focused {
                                    DispatchQueue.main.async { commitDraft() }
                                }
                                syncKeyMonitor()
                            }
                            .onSubmit { commitDraft() }
                            .onKeyPress(.downArrow) {
                                guard focused, !suggestions.isEmpty else { return .ignored }
                                highlighted = min(highlighted + 1, suggestions.count - 1)
                                return .handled
                            }
                            .onKeyPress(.upArrow) {
                                guard focused, !suggestions.isEmpty else { return .ignored }
                                highlighted = max(highlighted - 1, 0)
                                return .handled
                            }
                            .onKeyPress(.tab) {
                                // Tab always travels on to the next field
                                // (Subject) — returning .handled here used to
                                // trap the user in To, so their subject text
                                // landed in the recipient draft. Accept the
                                // highlighted suggestion (or commit the typed
                                // address) on the next runloop turn so the
                                // token mutation can't break the in-flight
                                // focus traversal.
                                guard focused else { return .ignored }
                                let pick = suggestions[safe: highlighted]
                                DispatchQueue.main.async {
                                    if let pick { accept(pick) } else { commitDraft() }
                                }
                                return .ignored
                            }
                            .onKeyPress(.return) {
                                guard focused, !draft.isEmpty else { return .ignored }
                                if let pick = suggestions[safe: highlighted] { accept(pick) }
                                else { commitDraft() }
                                return .handled
                            }
                    }
                    // Fixed row height tall enough for chips, so adding the
                    // first recipient doesn't grow the row.
                    .frame(height: 22)
                }
            }
            .padding(.vertical, 7)

            Divider()
        }
        // The suggestion list floats over whatever is below instead of
        // pushing the layout around.
        .overlay(alignment: .topLeading) {
            if focused, !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { idx, contact in
                        Button {
                            accept(contact)
                        } label: {
                            HStack {
                                Text(contact.name.isEmpty ? contact.email : contact.name)
                                    .font(.system(size: 12))
                                if !contact.name.isEmpty {
                                    Text(contact.email)
                                        .font(.system(size: 11)).foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(idx == highlighted ? Color.notionAccent.opacity(0.18) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlighted = idx } }
                    }
                }
                .frame(width: 380, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .shadow(radius: 10)
                .offset(x: 36, y: 38)
            }
        }
        .zIndex(focused ? 10 : 0)
        .onAppear {
            if autoFocus {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true }
            }
        }
        .onDisappear {
            clearChipHoverChrome()
            removeKeyMonitor()
        }
    }

    /// One recipient chip: click address → edit in the text field; × → remove.
    @ViewBuilder
    private func chip(_ token: String) -> some View {
        let isHovered = hoveredToken == token
        HStack(spacing: 0) {
            // Address (or contact name) — click re-opens for editing.
            Button {
                beginEdit(token)
            } label: {
                Text(displayName(token))
                    .font(.system(size: 12))
                    .padding(.leading, 8)
                    .padding(.vertical, 3)
                    .padding(.trailing, 3)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(token == displayName(token)
                  ? "Click to edit"
                  : "\(token) — click to edit")

            Button {
                clearChipHoverChrome()
                tokens = TokenAddressEditing.remove(tokens: tokens, token: token)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .padding(.trailing, 8)
                    .padding(.vertical, 3)
                    .padding(.leading, 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove")
        }
        .background(
            Color.secondary.opacity(isHovered ? 0.22 : 0.14),
            in: Capsule()
        )
        .onHover { inside in
            if inside {
                hoveredToken = token
                if !chipCursorPushed {
                    NSCursor.pointingHand.push()
                    chipCursorPushed = true
                }
            } else if hoveredToken == token {
                clearChipHoverChrome()
            }
        }
    }

    /// Pop pointing-hand + clear hover highlight. Safe to call when nothing
    /// is hovered (no-op). Must run when a chip is removed under the cursor
    /// so SwiftUI's missing hover-exit doesn't leave a stuck hand.
    private func clearChipHoverChrome() {
        if chipCursorPushed {
            NSCursor.pop()
            chipCursorPushed = false
        }
        hoveredToken = nil
    }

    /// Installs the backspace monitor while this field is focused.
    private func syncKeyMonitor() {
        if focused {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 51,   // delete (backspace)
                      event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                      draft.isEmpty, !tokens.isEmpty
                else { return event }
                tokens.removeLast()
                return nil
            }
        } else {
            removeKeyMonitor()
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private var suggestions: [MailStore.Contact] {
        let token = draft.trimmingCharacters(in: .whitespaces)
        guard !token.isEmpty else { return [] }
        return store.contactSuggestions(for: token).filter { !tokens.contains($0.email) }
    }

    private func displayName(_ email: String) -> String {
        store.contacts.first { $0.email == email }.flatMap { $0.name.isEmpty ? nil : $0.name } ?? email
    }

    private func accept(_ contact: MailStore.Contact) {
        // Same dedup as commit — autocomplete shouldn't re-add an existing chip.
        if !tokens.contains(contact.email) {
            tokens.append(contact.email)
        }
        draft = ""
    }

    private func commitDraft() {
        let result = TokenAddressEditing.commit(tokens: tokens, draft: draft)
        // Skip no-op writes: blur-time commits run right after a Tab
        // traversal, and a gratuitous tokens/draft invalidation there can
        // re-render the row and knock focus off the field Tab just reached.
        if result.tokens != tokens { tokens = result.tokens }
        if result.draft != draft { draft = result.draft }
    }

    private func beginEdit(_ token: String) {
        clearChipHoverChrome()
        let result = TokenAddressEditing.beginEdit(tokens: tokens, draft: draft, token: token)
        tokens = result.tokens
        draft = result.draft
        // Defer re-focus: the chip button click resigns the TextField first;
        // setting focused in the same turn races that resignation (same
        // pattern as autoFocus on appear).
        DispatchQueue.main.async { focused = true }
    }
}
