import SwiftUI

/// Address input with autocomplete backed by contacts mined from synced mail.
/// Comma-separated; suggestions match the token currently being typed.
struct AddressField: View {
    @EnvironmentObject var store: MailStore
    let label: String
    @Binding var text: String
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            TextField(label, text: $text)
                .focused($focused)
                .onChange(of: text) { highlighted = 0 }
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
                    guard focused, let pick = suggestions[safe: highlighted] else { return .ignored }
                    accept(pick)
                    return .handled
                }
                .onKeyPress(.return) {
                    guard focused, !currentToken.isEmpty, let pick = suggestions[safe: highlighted] else { return .ignored }
                    accept(pick)
                    return .handled
                }

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
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(idx == highlighted ? Color.accentColor.opacity(0.18) : .clear)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { if $0 { highlighted = idx } }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            }
        }
    }

    /// The address fragment after the last comma — what the user is typing now.
    private var currentToken: String {
        (text.split(separator: ",", omittingEmptySubsequences: false).last.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    private var suggestions: [MailStore.Contact] {
        let token = currentToken
        guard !token.isEmpty else { return [] }
        return store.contactSuggestions(for: token)
    }

    private func accept(_ contact: MailStore.Contact) {
        var parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.isEmpty { parts = [""] }
        parts[parts.count - 1] = " " + contact.email
        text = parts.joined(separator: ",").trimmingCharacters(in: .whitespaces) + ", "
    }
}
