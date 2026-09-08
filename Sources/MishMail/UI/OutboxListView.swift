import SwiftUI

/// The Outbox: drafts saved while Gmail was unreachable. Not Gmail threads —
/// rows reopen in compose or are discarded; a successful upload (on
/// reconnect, or from the editor) removes them.
struct OutboxListView: View {
    @Environment(MailStore.self) var store

    var body: some View {
        Group {
            if store.localDrafts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.up")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Outbox is empty")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Drafts saved while offline wait here until they upload.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.localDrafts) { draft in
                            OutboxRow(draft: draft)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Text("Outbox")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.7))
                Text(store.isOffline
                     ? "· uploads to Drafts when you're back online"
                     : "· uploading to Drafts")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
                if !store.isOffline && !store.localDrafts.isEmpty {
                    Button("Upload now") {
                        Task { await store.flushLocalDrafts() }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11))
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.background)
        }
    }
}

private struct OutboxRow: View {
    @Environment(MailStore.self) var store
    let draft: LocalDraft
    @State private var hovering = false

    private var recipients: String {
        MessageParser.splitAddresses(draft.toHeader)
            .map { MessageParser.displayName(fromHeader: $0) }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(recipients.isEmpty ? "(no recipients)" : recipients)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            (Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                .fontWeight(.medium)
             + Text("  \(draft.body.replacingOccurrences(of: "\n", with: " "))")
                .foregroundColor(.secondary))
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 12)

            if hovering {
                HStack(spacing: 10) {
                    rowButton("pencil", help: "Edit (back to compose)") {
                        store.editLocalDraft(draft)
                    }
                    rowButton("trash", help: "Discard") {
                        store.deleteLocalDraft(draft)
                    }
                }
            } else {
                Text(draft.updatedAt, format: .relative(presentation: .named))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.editLocalDraft(draft) }
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button("Edit in Compose") { store.editLocalDraft(draft) }
            Divider()
            Button("Discard", role: .destructive) { store.deleteLocalDraft(draft) }
        }
    }

    private func rowButton(_ icon: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
