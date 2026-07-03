import SwiftUI

/// Notion Mail-style recipient field: accepted addresses render as chips,
/// with autocomplete backed by contacts mined from synced mail.
struct TokenAddressField: View {
    @EnvironmentObject var store: MailStore
    let label: String
    @Binding var tokens: [String]
    @State private var draft = ""
    @FocusState private var focused: Bool
    @State private var highlighted = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Text(label)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .leading)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(tokens, id: \.self) { token in
                            HStack(spacing: 3) {
                                Text(displayName(token)).font(.system(size: 12))
                                Button {
                                    tokens.removeAll { $0 == token }
                                } label: {
                                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                                }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.14), in: Capsule())
                        }
                        TextField(tokens.isEmpty ? "Add recipients" : "", text: $draft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .frame(minWidth: 160)
                            .focused($focused)
                            .onChange(of: draft) {
                                highlighted = 0
                                if draft.hasSuffix(",") { commitDraft() }
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
                                guard focused, let pick = suggestions[safe: highlighted] else { return .ignored }
                                accept(pick)
                                return .handled
                            }
                            .onKeyPress(.return) {
                                guard focused, !draft.isEmpty else { return .ignored }
                                if let pick = suggestions[safe: highlighted] { accept(pick) }
                                else { commitDraft() }
                                return .handled
                            }
                            .onKeyPress(.delete) {
                                guard focused, draft.isEmpty, !tokens.isEmpty else { return .ignored }
                                tokens.removeLast()
                                return .handled
                            }
                    }
                }
            }
            .padding(.vertical, 7)

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
                .padding(.bottom, 4)
            }
            Divider()
        }
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
        tokens.append(contact.email)
        draft = ""
    }

    private func commitDraft() {
        let cleaned = draft.trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        if cleaned.contains("@") { tokens.append(cleaned) }
        draft = ""
    }
}
