import SwiftUI

/// The Scheduled view: locally scheduled sends waiting for their time.
/// Not Gmail threads — rows edit back into compose, send now, or discard.
struct ScheduledListView: View {
    @EnvironmentObject var store: MailStore

    var body: some View {
        Group {
            if store.scheduledSends.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Nothing scheduled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Schedule a message from the arrow next to Send.")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.scheduledSends) { send in
                            ScheduledRow(send: send)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                }
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: 6) {
                Text("Scheduled")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.7))
                Text("· sends while PerfectMail is open")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.background)
        }
    }
}

private struct ScheduledRow: View {
    @EnvironmentObject var store: MailStore
    let send: ScheduledSend
    @State private var hovering = false

    private var recipients: String {
        MessageParser.splitAddresses(send.toHeader)
            .map { MessageParser.displayName(fromHeader: $0) }
            .joined(separator: ", ")
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)

            Text(recipients.isEmpty ? "(no recipients)" : recipients)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .frame(width: 170, alignment: .leading)

            (Text(send.subject.isEmpty ? "(no subject)" : send.subject)
                .fontWeight(.medium)
             + Text("  \(send.body.replacingOccurrences(of: "\n", with: " "))")
                .foregroundColor(.secondary))
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer(minLength: 12)

            if hovering {
                HStack(spacing: 10) {
                    rowButton("pencil", help: "Edit (back to compose)") {
                        store.editScheduledSend(send)
                    }
                    rowButton("paperplane", help: "Send now") {
                        store.sendScheduledNow(send)
                    }
                    rowButton("trash", help: "Discard") {
                        store.discardScheduledSend(send)
                    }
                }
            } else {
                Text(SendSchedule.describe(send.sendAt))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(hovering ? Color.primary.opacity(0.07) : .clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button("Edit in Compose") { store.editScheduledSend(send) }
            Button("Send Now") { store.sendScheduledNow(send) }
            Divider()
            Button("Discard", role: .destructive) { store.discardScheduledSend(send) }
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
