import SwiftUI

/// Notion Mail / Gmail-style calendar invite card: title, when, where, and
/// Accept / Decline / Maybe. Loads the `.ics` attachment, parses it, and
/// posts an iTIP METHOD:REPLY via `MailStore.rsvpToInvite`.
struct CalendarInviteCard: View {
    @Environment(MailStore.self) private var store
    let message: Message
    let attachment: AttachmentRow
    var fontScale: Double = 1.0

    @State private var invite: CalendarInvite?
    @State private var loadError: String?
    @State private var loading = true
    @State private var sending: CalendarInvite.RSVP?
    @State private var localRSVP: CalendarInvite.RSVP?

    var body: some View {
        Group {
            if loading {
                loadingRow
            } else if let invite {
                inviteBody(invite)
            } else if let loadError {
                Text(loadError)
                    .font(PMFont.caption(fontScale))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: PMRadius.md))
            }
        }
        .task(id: "\(message.id)|\(attachment.id ?? 0)") {
            await loadInvite()
        }
    }

    private var loadingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Loading calendar invite…")
                .font(PMFont.caption(fontScale))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PMRadius.md))
    }

    @ViewBuilder
    private func inviteBody(_ invite: CalendarInvite) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: invite.isCancelled
                      ? "calendar.badge.minus" : "calendar")
                    .font(.system(size: 18 * fontScale, weight: .semibold))
                    .foregroundStyle(invite.isCancelled ? Color.secondary : Color.notionAccent)
                    .frame(width: 28, height: 28)
                    .background(
                        (invite.isCancelled ? Color.secondary : Color.notionAccent)
                            .opacity(0.12),
                        in: RoundedRectangle(cornerRadius: PMRadius.sm)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(invite.summary)
                        .font(.system(size: 13.5 * fontScale, weight: .semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Text(invite.whenDescription())
                        .font(PMFont.secondary(fontScale))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    if !invite.location.isEmpty {
                        Label(invite.location, systemImage: "mappin.and.ellipse")
                            .font(PMFont.caption(fontScale))
                            .foregroundStyle(.secondary)
                            .labelStyle(.titleAndIcon)
                            .textSelection(.enabled)
                    }
                    if !invite.organizerEmail.isEmpty {
                        let who = invite.organizerName.isEmpty
                            ? invite.organizerEmail
                            : "\(invite.organizerName) <\(invite.organizerEmail)>"
                        Text("Organizer · \(who)")
                            .font(PMFont.caption(fontScale))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }

            if invite.isCancelled {
                statusPill("Cancelled", color: .secondary)
            } else if invite.isActionable {
                rsvpRow(for: invite)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PMRadius.md))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.md)
                .strokeBorder(Color.notionAccent.opacity(0.22), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func rsvpRow(for invite: CalendarInvite) -> some View {
        HStack(spacing: 8) {
            ForEach(CalendarInvite.RSVP.allCases, id: \.rawValue) { status in
                rsvpButton(status, invite: invite)
            }
            Spacer(minLength: 0)
            if let localRSVP {
                statusPill(localRSVP.subjectPrefix, color: tint(for: localRSVP))
            }
        }
    }

    private func rsvpButton(_ status: CalendarInvite.RSVP,
                            invite: CalendarInvite) -> some View {
        let selected = localRSVP == status
        let busy = sending != nil
        return Button {
            guard !busy else { return }
            Task { await respond(status, invite: invite) }
        } label: {
            HStack(spacing: 5) {
                if sending == status {
                    ProgressView().controlSize(.mini)
                }
                Text(status.buttonTitle)
                    .font(.system(size: 12.5 * fontScale, weight: .medium))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                selected
                    ? tint(for: status).opacity(0.18)
                    : Color.secondary.opacity(0.12),
                in: Capsule()
            )
            .foregroundStyle(selected ? tint(for: status) : Color.primary)
            .overlay {
                Capsule()
                    .strokeBorder(
                        selected ? tint(for: status).opacity(0.45) : Color.clear,
                        lineWidth: 1)
            }
        }
        .buttonStyle(PressScaleButtonStyle(enabled: !busy))
        .disabled(busy)
        .help(helpText(for: status, invite: invite))
    }

    private func statusPill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 11 * fontScale, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }

    private func tint(for status: CalendarInvite.RSVP) -> Color {
        switch status {
        case .accepted: return .green
        case .declined: return .red
        case .tentative: return .orange
        }
    }

    private func helpText(for status: CalendarInvite.RSVP,
                          invite: CalendarInvite) -> String {
        let org = invite.organizerEmail.isEmpty ? "the organizer" : invite.organizerEmail
        return "\(status.buttonTitle) and email \(org)"
    }

    // MARK: - Load / respond

    private func loadInvite() async {
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let data = try await store.downloadAttachment(attachment, message: message)
            guard let parsed = CalendarInvite.parse(data) else {
                loadError = "Couldn't read this calendar invite."
                return
            }
            invite = parsed
            localRSVP = CalendarInvite.storedRSVP(
                accountId: message.accountId, uid: parsed.uid)
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func respond(_ status: CalendarInvite.RSVP,
                         invite: CalendarInvite) async {
        sending = status
        defer { sending = nil }
        await store.rsvpToInvite(invite, status: status, message: message)
        // Re-read stored state — only updates on success.
        if let stored = CalendarInvite.storedRSVP(
            accountId: message.accountId, uid: invite.uid) {
            withAnimation(PMMotion.feedback) { localRSVP = stored }
        }
    }
}
