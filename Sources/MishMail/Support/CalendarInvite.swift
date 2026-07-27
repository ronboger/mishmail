import Foundation

/// Parsed iCalendar invite (RFC 5545 / iTIP RFC 5546) from a `text/calendar`
/// or `.ics` attachment. Pure value type — no network, no store.
struct CalendarInvite: Equatable, Sendable {
    enum Method: String, Equatable, Sendable {
        case request = "REQUEST"
        case reply = "REPLY"
        case cancel = "CANCEL"
        case publish = "PUBLISH"
        case counter = "COUNTER"
        case refresh = "REFRESH"
        case add = "ADD"
        case unknown

        init(raw: String?) {
            guard let raw, let m = Method(rawValue: raw.uppercased()) else {
                self = .unknown
                return
            }
            self = m
        }
    }

    /// Guest RSVP for a METHOD:REPLY we send.
    enum RSVP: String, Equatable, Sendable, CaseIterable {
        case accepted = "ACCEPTED"
        case declined = "DECLINED"
        case tentative = "TENTATIVE"

        var buttonTitle: String {
            switch self {
            case .accepted: return "Accept"
            case .declined: return "Decline"
            case .tentative: return "Maybe"
            }
        }

        /// Subject prefix matching Gmail / Apple Mail (`Accepted: …`).
        var subjectPrefix: String {
            switch self {
            case .accepted: return "Accepted"
            case .declined: return "Declined"
            case .tentative: return "Tentative"
            }
        }

        var pastParticiple: String {
            switch self {
            case .accepted: return "accepted"
            case .declined: return "declined"
            case .tentative: return "tentatively accepted"
            }
        }
    }

    var method: Method
    var uid: String
    var summary: String
    var location: String
    var description: String
    var organizerEmail: String
    var organizerName: String
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    var sequence: Int
    /// Raw unfolded ICS used to build the METHOD:REPLY payload.
    var sourceICS: String

    /// True when this is an actionable invitation (not a cancel/publish/reply).
    var isActionable: Bool {
        method == .request || method == .publish || method == .unknown
    }

    var isCancelled: Bool { method == .cancel }

    /// Attachment looks like a calendar invite by MIME or filename.
    static func isCalendarAttachment(mimeType: String, filename: String) -> Bool {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("text/calendar") { return true }
        if mime.contains("application/ics") { return true }
        return filename.lowercased().hasSuffix(".ics")
    }

    /// Parse the first VEVENT in an ICS document. Returns nil when there is
    /// no usable event (missing UID, empty payload).
    static func parse(_ data: Data) -> CalendarInvite? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parse(text)
    }

    static func parse(_ ics: String) -> CalendarInvite? {
        let lines = unfold(ics)
        guard !lines.isEmpty else { return nil }

        var methodRaw: String?
        var inEvent = false
        var props: [String: (params: [String: String], value: String)] = [:]
        // Preserve ATTENDEE lines (multiple) separately for reply building.
        var attendeeLines: [String] = []

        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") {
                inEvent = true
                props = [:]
                attendeeLines = []
                continue
            }
            if upper.hasPrefix("END:VEVENT") {
                break
            }
            if !inEvent {
                if upper.hasPrefix("METHOD:") {
                    methodRaw = String(line.dropFirst("METHOD:".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let nameAndParams = String(line[..<colon])
            let value = String(line[line.index(after: colon)...])
            let parts = nameAndParams.split(separator: ";", maxSplits: 32,
                                            omittingEmptySubsequences: false)
            guard let namePart = parts.first else { continue }
            let name = String(namePart).uppercased()
            var params: [String: String] = [:]
            for p in parts.dropFirst() {
                let kv = p.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                params[String(kv[0]).uppercased()] = String(kv[1])
            }
            if name == "ATTENDEE" {
                attendeeLines.append(line)
            }
            // First wins for most props; later DTSTART/DTEND rarely appear twice.
            if props[name] == nil {
                props[name] = (params, value)
            }
        }

        let uid = props["UID"]?.value.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !uid.isEmpty else { return nil }

        let summary = unescape(props["SUMMARY"]?.value ?? "")
        let location = unescape(props["LOCATION"]?.value ?? "")
        let description = unescape(props["DESCRIPTION"]?.value ?? "")
        let sequence = Int(props["SEQUENCE"]?.value.trimmingCharacters(in: .whitespaces) ?? "") ?? 0

        let (orgEmail, orgName) = parseAddress(
            value: props["ORGANIZER"]?.value ?? "",
            params: props["ORGANIZER"]?.params ?? [:])

        let startParsed = parseDate(props["DTSTART"])
        let endParsed = parseDate(props["DTEND"])
        // DURATION fallback when no DTEND (common for some exporters).
        var end = endParsed?.date
        if end == nil, let start = startParsed?.date,
           let duration = props["DURATION"]?.value,
           let seconds = parseDuration(duration) {
            end = start.addingTimeInterval(seconds)
        }

        return CalendarInvite(
            method: Method(raw: methodRaw),
            uid: uid,
            summary: summary.isEmpty ? "Calendar event" : summary,
            location: location,
            description: description,
            organizerEmail: orgEmail,
            organizerName: orgName,
            start: startParsed?.date,
            end: end,
            isAllDay: startParsed?.allDay ?? false,
            sequence: sequence,
            sourceICS: ics
        )
    }

    // MARK: - Reply

    /// Build a METHOD:REPLY ICS for this invite from `attendeeEmail`.
    func replyICS(status: RSVP, attendeeEmail: String, attendeeName: String = "") -> String {
        let email = attendeeEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let cn = attendeeName.trimmingCharacters(in: .whitespacesAndNewlines)
        let stamp = Self.formatUTC(Date())
        var lines: [String] = [
            "BEGIN:VCALENDAR",
            "PRODID:-//MishMail//Calendar RSVP//EN",
            "VERSION:2.0",
            "METHOD:REPLY",
            "CALSCALE:GREGORIAN",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "DTSTAMP:\(stamp)",
            "SEQUENCE:\(sequence)",
        ]
        if let start {
            lines.append(isAllDay
                ? "DTSTART;VALUE=DATE:\(Self.formatDateOnly(start))"
                : "DTSTART:\(Self.formatUTC(start))")
        }
        if let end {
            lines.append(isAllDay
                ? "DTEND;VALUE=DATE:\(Self.formatDateOnly(end))"
                : "DTEND:\(Self.formatUTC(end))")
        }
        lines.append("SUMMARY:\(Self.escape(summary))")
        if !location.isEmpty {
            lines.append("LOCATION:\(Self.escape(location))")
        }
        if !organizerEmail.isEmpty {
            let orgCN = organizerName.isEmpty ? "" : ";CN=\(Self.escapeParam(organizerName))"
            lines.append("ORGANIZER\(orgCN):mailto:\(organizerEmail)")
        }
        var attendee = "ATTENDEE;PARTSTAT=\(status.rawValue);ROLE=REQ-PARTICIPANT"
        if !cn.isEmpty {
            attendee += ";CN=\(Self.escapeParam(cn))"
        }
        attendee += ":mailto:\(email)"
        lines.append(attendee)
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// Human subject for the RSVP message.
    func replySubject(status: RSVP) -> String {
        "\(status.subjectPrefix): \(summary)"
    }

    /// Short plain-text body for the RSVP message.
    func replyBody(status: RSVP, responderName: String) -> String {
        let who = responderName.isEmpty ? "The invitee" : responderName
        return "\(who) has \(status.pastParticiple) this invitation."
    }

    /// MIME attachment for the REPLY ICS.
    func replyAttachment(status: RSVP, attendeeEmail: String,
                         attendeeName: String = "") -> MIMEBuilder.Attachment {
        let ics = replyICS(status: status, attendeeEmail: attendeeEmail,
                           attendeeName: attendeeName)
        return .init(
            filename: "invite.ics",
            // method=REPLY is required so calendar agents treat this as iTIP.
            mimeType: "text/calendar; method=REPLY",
            data: Data(ics.utf8)
        )
    }

    /// When-string for the invite card (locale-aware).
    func whenDescription(now: Date = Date(),
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        guard let start else { return "Time not specified" }
        if isAllDay {
            let df = DateFormatter()
            df.locale = locale
            df.calendar = calendar
            df.doesRelativeDateFormatting = true
            df.dateStyle = .full
            df.timeStyle = .none
            if let end, end > start.addingTimeInterval(24 * 3600 - 1) {
                // Multi-day all-day: end is exclusive in iCal DATE form.
                let lastDay = calendar.date(byAdding: .day, value: -1, to: end) ?? end
                if calendar.isDate(start, inSameDayAs: lastDay) {
                    return df.string(from: start)
                }
                return "\(df.string(from: start)) – \(df.string(from: lastDay))"
            }
            return df.string(from: start)
        }

        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeStyle = .short
        time.dateStyle = .none

        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.doesRelativeDateFormatting = true
        day.dateStyle = .full
        day.timeStyle = .none

        let dayPart = day.string(from: start)
        if let end {
            if calendar.isDate(start, inSameDayAs: end) {
                return "\(dayPart) · \(time.string(from: start)) – \(time.string(from: end))"
            }
            let endDay = day.string(from: end)
            return "\(dayPart) \(time.string(from: start)) – \(endDay) \(time.string(from: end))"
        }
        return "\(dayPart) · \(time.string(from: start))"
    }

    // MARK: - Persistence key for local RSVP state

    /// Stable UserDefaults key for the last RSVP we sent for this UID.
    static func rsvpDefaultsKey(accountId: String, uid: String) -> String {
        // UID can contain `@` and punctuation; keep the key printable.
        let safeUID = uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? uid
        let safeAcct = accountId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? accountId
        return "calendar.rsvp.\(safeAcct).\(safeUID)"
    }

    static func storedRSVP(accountId: String, uid: String,
                           defaults: UserDefaults = .standard) -> RSVP? {
        guard let raw = defaults.string(forKey: rsvpDefaultsKey(accountId: accountId, uid: uid))
        else { return nil }
        return RSVP(rawValue: raw)
    }

    static func storeRSVP(_ status: RSVP, accountId: String, uid: String,
                          defaults: UserDefaults = .standard) {
        defaults.set(status.rawValue, forKey: rsvpDefaultsKey(accountId: accountId, uid: uid))
    }

    // MARK: - Parsing helpers

    /// RFC 5545 line unfolding: a line starting with SPACE/TAB continues the previous.
    static func unfold(_ ics: String) -> [String] {
        let raw = ics
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var out: [String] = []
        for line in raw {
            if line.hasPrefix(" ") || line.hasPrefix("\t"), let last = out.popLast() {
                out.append(last + line.dropFirst())
            } else {
                out.append(line)
            }
        }
        return out.filter { !$0.isEmpty }
    }

    private static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",")
            .replacingOccurrences(of: "\\;", with: ";")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static func escapeParam(_ value: String) -> String {
        // PARAM values with specials get double-quoted (RFC 5545).
        if value.contains(where: { ";,:\"\\".contains($0) || $0.isWhitespace }) {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func parseAddress(value: String, params: [String: String])
        -> (email: String, name: String) {
        var v = value.trimmingCharacters(in: .whitespaces)
        if v.lowercased().hasPrefix("mailto:") {
            v = String(v.dropFirst("mailto:".count))
        }
        let email = v.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        var name = params["CN"] ?? ""
        if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        return (email, name)
    }

    private struct ParsedDate {
        let date: Date
        let allDay: Bool
    }

    private static func parseDate(
        _ prop: (params: [String: String], value: String)?
    ) -> ParsedDate? {
        guard let prop else { return nil }
        let value = prop.value.trimmingCharacters(in: .whitespaces)
        let params = prop.params
        let isDate = (params["VALUE"]?.uppercased() == "DATE")
            || (value.count == 8 && value.allSatisfy(\.isNumber))

        if isDate {
            guard value.count >= 8,
                  let y = Int(value.prefix(4)),
                  let m = Int(value.dropFirst(4).prefix(2)),
                  let d = Int(value.dropFirst(6).prefix(2)) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = .current
            guard let date = cal.date(from: DateComponents(year: y, month: m, day: d))
            else { return nil }
            return ParsedDate(date: date, allDay: true)
        }

        // FORM #1 / #2: YYYYMMDDTHHMMSS[Z] with optional TZID.
        let isUTC = value.hasSuffix("Z")
        let core = isUTC ? String(value.dropLast()) : value
        guard core.count >= 15,
              let y = Int(core.prefix(4)),
              let mo = Int(core.dropFirst(4).prefix(2)),
              let d = Int(core.dropFirst(6).prefix(2)),
              let h = Int(core.dropFirst(9).prefix(2)),
              let mi = Int(core.dropFirst(11).prefix(2)),
              let s = Int(core.dropFirst(13).prefix(2)) else { return nil }

        var cal = Calendar(identifier: .gregorian)
        if isUTC {
            cal.timeZone = TimeZone(secondsFromGMT: 0)!
        } else if let tzid = params["TZID"],
                  let tz = TimeZone(identifier: tzid)
                    ?? TimeZone(identifier: tzid.replacingOccurrences(of: "\"", with: "")) {
            cal.timeZone = tz
        } else {
            cal.timeZone = .current
        }
        var comps = DateComponents()
        comps.year = y; comps.month = mo; comps.day = d
        comps.hour = h; comps.minute = mi; comps.second = s
        guard let date = cal.date(from: comps) else { return nil }
        return ParsedDate(date: date, allDay: false)
    }

    /// Parse RFC 5545 DURATION (`PT1H30M`, `P1D`, `-PT15M`).
    static func parseDuration(_ raw: String) -> TimeInterval? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var sign: Double = 1
        if s.hasPrefix("-") { sign = -1; s = String(s.dropFirst()) }
        guard s.hasPrefix("P") else { return nil }
        s = String(s.dropFirst())
        var total: Double = 0
        var num = ""
        var inTime = false
        for ch in s {
            if ch == "T" { inTime = true; continue }
            if ch.isNumber { num.append(ch); continue }
            guard let n = Double(num) else { return nil }
            num = ""
            switch ch {
            case "W": total += n * 7 * 24 * 3600
            case "D": total += n * 24 * 3600
            case "H" where inTime: total += n * 3600
            case "M" where inTime: total += n * 60
            case "S" where inTime: total += n
            default: return nil
            }
        }
        if !num.isEmpty { return nil }
        return total * sign
    }

    static func formatUTC(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(format: "%04d%02d%02dT%02d%02d%02dZ",
                      c.year ?? 0, c.month ?? 0, c.day ?? 0,
                      c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }

    static func formatDateOnly(_ date: Date) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}
