import SwiftUI

/// Notion Mail / Gmail-style calendar invite card: title, when, where, and
/// Accept / Decline / Maybe. Loads the `.ics` attachment, parses it, and
/// posts an iTIP METHOD:REPLY via `MailStore.rsvpToInvite`.
///
/// RSVP does not write to any local calendar — use **Open in Calendar** (or
/// Save / Quick Look) to hand the original `.ics` to Calendar.app.
struct CalendarInviteCard: View {
    @Environment(MailStore.self) private var store
    let message: Message
    let attachment: AttachmentRow
    var fontScale: Double = 1.0

    /// All VEVENTs from the ICS (multi-slot / series+exception files).
    @State private var invites: [CalendarInvite] = []
    @State private var loadError: String?
    @State private var loading = true
    /// Per-UID(+RECURRENCE-ID) in-flight and local RSVP state.
    @State private var sendingKey: String?
    @State private var localRSVPByKey: [String: CalendarInvite.RSVP] = [:]

    var body: some View {
        Group {
            if loading {
                loadingRow
            } else if !invites.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(invites.enumerated()), id: \.offset) { _, invite in
                        inviteBody(invite)
                    }
                }
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
                HStack(spacing: 8) {
                    statusPill("Cancelled", color: .secondary)
                    Spacer(minLength: 0)
                    fileActions
                }
            } else if invite.isActionable {
                rsvpRow(for: invite)
            } else {
                // PUBLISH / REPLY / unknown METHOD: show the event but don't
                // offer Accept (would email an untrusted ORGANIZER). Still
                // let the user open the .ics in Calendar.app.
                HStack(spacing: 8) {
                    statusPill(methodLabel(invite.method), color: .secondary)
                    Spacer(minLength: 0)
                    fileActions
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PMRadius.md))
        .overlay {
            RoundedRectangle(cornerRadius: PMRadius.md)
                .strokeBorder(
                    invite.isActionable
                        ? Color.notionAccent.opacity(0.22)
                        : Color.primary.opacity(0.08),
                    lineWidth: 1)
        }
        .contextMenu {
            Button("Open in Calendar") {
                store.openAttachment(attachment, message: message)
            }
            Button("Quick Look") {
                store.quickLookAttachment(attachment, message: message)
            }
            Button("Save As…") {
                store.saveAttachment(attachment, message: message)
            }
        }
    }

    @ViewBuilder
    private func rsvpRow(for invite: CalendarInvite) -> some View {
        let key = rsvpKey(invite)
        HStack(spacing: 8) {
            ForEach(CalendarInvite.RSVP.allCases, id: \.rawValue) { status in
                rsvpButton(status, invite: invite)
            }
            Spacer(minLength: 0)
            if let local = localRSVPByKey[key] {
                statusPill(local.subjectPrefix, color: tint(for: local))
            }
            fileActions
        }
    }

    private func rsvpKey(_ invite: CalendarInvite) -> String {
        CalendarInvite.rsvpDefaultsKey(
            accountId: message.accountId, uid: invite.uid,
            recurrenceIdLine: invite.recurrenceIdLine)
    }

    /// Hand the original .ics to Calendar.app / Quick Look / Save — RSVP
    /// alone never writes a local event.
    private var fileActions: some View {
        HStack(spacing: 4) {
            Button {
                store.openAttachment(attachment, message: message)
            } label: {
                Image(systemName: "calendar.badge.plus")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in Calendar")

            Button {
                store.quickLookAttachment(attachment, message: message)
            } label: {
                Image(systemName: "eye")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Quick Look")

            Button {
                store.saveAttachment(attachment, message: message)
            } label: {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 13 * fontScale))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Save As…")
        }
    }

    private func rsvpButton(_ status: CalendarInvite.RSVP,
                            invite: CalendarInvite) -> some View {
        let key = rsvpKey(invite)
        let selected = localRSVPByKey[key] == status
        let busy = sendingKey != nil
        let thisSending = sendingKey == key
        return Button {
            guard !busy else { return }
            Task { await respond(status, invite: invite) }
        } label: {
            HStack(spacing: 5) {
                if thisSending {
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

    private func methodLabel(_ method: CalendarInvite.Method) -> String {
        switch method {
        case .publish: return "Published event"
        case .reply: return "RSVP reply"
        case .cancel: return "Cancelled"
        case .counter: return "Counter proposal"
        case .refresh: return "Refresh request"
        case .add: return "Added event"
        case .unknown: return "Calendar event"
        case .request: return "Invitation"
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
            let parsed = CalendarInvite.parseAll(data)
            guard !parsed.isEmpty else {
                loadError = "Couldn't read this calendar invite."
                return
            }
            invites = parsed
            var map: [String: CalendarInvite.RSVP] = [:]
            for inv in parsed {
                if let stored = CalendarInvite.storedRSVP(
                    accountId: message.accountId, uid: inv.uid,
                    recurrenceIdLine: inv.recurrenceIdLine) {
                    map[rsvpKey(inv)] = stored
                }
            }
            localRSVPByKey = map
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func respond(_ status: CalendarInvite.RSVP,
                         invite: CalendarInvite) async {
        let key = rsvpKey(invite)
        sendingKey = key
        defer { sendingKey = nil }
        await store.rsvpToInvite(invite, status: status, message: message)
        // Re-read stored state — only updates on success.
        if let stored = CalendarInvite.storedRSVP(
            accountId: message.accountId, uid: invite.uid,
            recurrenceIdLine: invite.recurrenceIdLine) {
            withAnimation(PMMotion.feedback) { localRSVPByKey[key] = stored }
        }
    }
}
