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
    /// Bare attendee emails from ATTENDEE lines (lowercased, mailto: stripped).
    /// Used to pick a send-as identity that the organizer's calendar already knows.
    var attendeeEmails: [String]
    var start: Date?
    var end: Date?
    var isAllDay: Bool
    var sequence: Int
    /// Full unfolded `RECURRENCE-ID…` property line from the request, when
    /// present (single-instance RSVP on a recurring series). Echoed verbatim
    /// into METHOD:REPLY so the organizer applies PARTSTAT to the right occurrence.
    var recurrenceIdLine: String?
    /// Raw ICS source (kept for debugging / future round-trips; reply is rebuilt).
    var sourceICS: String

    /// True when Accept / Decline / Maybe should be offered.
    /// Gmail is conservative: only METHOD:REQUEST is actionable. PUBLISH /
    /// unknown (forwarded exports) would otherwise email whatever ORGANIZER
    /// the untrusted attachment author wrote.
    var isActionable: Bool { method == .request }

    var isCancelled: Bool { method == .cancel }

    /// Attachment looks like a calendar invite by MIME or filename.
    static func isCalendarAttachment(mimeType: String, filename: String) -> Bool {
        let mime = mimeType.lowercased()
        if mime.hasPrefix("text/calendar") { return true }
        if mime.contains("application/ics") { return true }
        return filename.lowercased().hasSuffix(".ics")
    }

    /// Preferred single event from an ICS document (see `preferred(from:)`).
    static func parse(_ data: Data) -> CalendarInvite? {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parse(text)
    }

    static func parse(_ ics: String) -> CalendarInvite? {
        preferred(from: parseAll(ics))
    }

    /// Every VEVENT in the document, sharing the calendar-level METHOD.
    /// Multi-event ICS (series + exceptions, or multi-slot bookings) yields
    /// one invite per VEVENT with a UID.
    static func parseAll(_ data: Data) -> [CalendarInvite] {
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return [] }
        return parseAll(text)
    }

    static func parseAll(_ ics: String) -> [CalendarInvite] {
        let lines = unfold(ics)
        guard !lines.isEmpty else { return [] }

        var methodRaw: String?
        var inEvent = false
        /// Depth of nested components inside VEVENT (VALARM, etc.). Props
        /// belonging to those components must not overwrite VEVENT fields —
        /// Outlook VALARMs ship `DESCRIPTION:REMINDER` that would otherwise
        /// replace the meeting description under first-wins.
        var nestedDepth = 0
        var props: [String: (params: [String: String], value: String)] = [:]
        var attendeeEmails: [String] = []
        var recurrenceIdLine: String?
        var events: [CalendarInvite] = []

        func finishEvent() {
            if let invite = buildInvite(
                methodRaw: methodRaw, props: props,
                attendeeEmails: attendeeEmails,
                recurrenceIdLine: recurrenceIdLine, sourceICS: ics) {
                events.append(invite)
            }
            props = [:]
            attendeeEmails = []
            recurrenceIdLine = nil
            nestedDepth = 0
            inEvent = false
        }

        for line in lines {
            let upper = line.uppercased()
            if upper.hasPrefix("BEGIN:VEVENT") {
                if inEvent { finishEvent() }
                inEvent = true
                nestedDepth = 0
                props = [:]
                attendeeEmails = []
                recurrenceIdLine = nil
                continue
            }
            if upper.hasPrefix("END:VEVENT") {
                if inEvent { finishEvent() }
                continue
            }
            if !inEvent {
                if upper.hasPrefix("METHOD:") {
                    methodRaw = String(line.dropFirst("METHOD:".count))
                        .trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            // Skip nested components entirely (VALARM is the common case).
            if upper.hasPrefix("BEGIN:") {
                nestedDepth += 1
                continue
            }
            if upper.hasPrefix("END:") {
                if nestedDepth > 0 { nestedDepth -= 1 }
                continue
            }
            if nestedDepth > 0 { continue }

            guard let nameAndValue = splitProperty(line) else { continue }
            let name = nameAndValue.name
            let params = nameAndValue.params
            let value = nameAndValue.value

            if name == "ATTENDEE" {
                let (email, _) = parseAddress(value: value, params: params)
                let lower = email.lowercased()
                if !lower.isEmpty, !attendeeEmails.contains(lower) {
                    attendeeEmails.append(lower)
                }
            }
            if name == "RECURRENCE-ID", recurrenceIdLine == nil {
                // Keep the original property line (params + value) for the reply.
                recurrenceIdLine = line
            }
            // First wins for most props; later DTSTART/DTEND rarely appear twice.
            if props[name] == nil {
                props[name] = (params, value)
            }
        }
        if inEvent { finishEvent() }
        return events
    }

    /// Pick one event when the UI only wants a single card:
    /// 1. first with RECURRENCE-ID (instance invite on a series),
    /// 2. first METHOD:REQUEST,
    /// 3. first VEVENT.
    static func preferred(from invites: [CalendarInvite]) -> CalendarInvite? {
        if let inst = invites.first(where: { $0.recurrenceIdLine != nil }) {
            return inst
        }
        if let req = invites.first(where: { $0.method == .request }) {
            return req
        }
        return invites.first
    }

    private static func buildInvite(
        methodRaw: String?,
        props: [String: (params: [String: String], value: String)],
        attendeeEmails: [String],
        recurrenceIdLine: String?,
        sourceICS: String
    ) -> CalendarInvite? {
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
            attendeeEmails: attendeeEmails,
            start: startParsed?.date,
            end: end,
            isAllDay: startParsed?.allDay ?? false,
            sequence: sequence,
            recurrenceIdLine: recurrenceIdLine,
            sourceICS: sourceICS
        )
    }

    // MARK: - Reply

    /// Build a METHOD:REPLY ICS for this invite from `attendeeEmail`.
    /// Content lines longer than 75 octets are folded per RFC 5545 §3.1.
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
        // Instance RSVP on a recurring series — without this the organizer
        // applies PARTSTAT to the master / wrong occurrence.
        if let recurrenceIdLine, !recurrenceIdLine.isEmpty {
            lines.append(recurrenceIdLine)
        }
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
        return Self.foldICS(lines)
    }

    /// RFC 5545 §3.1: fold content lines so no line exceeds 75 octets.
    /// Continuations begin with a single SPACE after CRLF.
    static func foldICS(_ lines: [String]) -> String {
        lines.map { foldLine($0) }.joined(separator: "\r\n") + "\r\n"
    }

    /// Fold one logical line to ≤75 UTF-8 octets per physical line.
    static func foldLine(_ line: String, limit: Int = 75) -> String {
        let bytes = Array(line.utf8)
        guard bytes.count > limit else { return line }
        var out = [UInt8]()
        out.reserveCapacity(bytes.count + bytes.count / limit * 3)
        var offset = 0
        var first = true
        while offset < bytes.count {
            let budget = first ? limit : max(1, limit - 1) // room for leading SPACE
            var end = min(offset + budget, bytes.count)
            // Don't split mid multi-byte UTF-8 sequence.
            if end < bytes.count {
                while end > offset && (bytes[end] & 0xC0) == 0x80 {
                    end -= 1
                }
                if end == offset {
                    // Pathological: single code point longer than budget — force.
                    end = min(offset + budget, bytes.count)
                }
            }
            if !first {
                out.append(0x0D); out.append(0x0A); out.append(0x20) // CRLF + SPACE
            }
            out.append(contentsOf: bytes[offset..<end])
            offset = end
            first = false
        }
        return String(bytes: out, encoding: .utf8) ?? line
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

    /// Stable UserDefaults key for the last RSVP we sent for this UID (+ instance).
    static func rsvpDefaultsKey(accountId: String, uid: String,
                                recurrenceIdLine: String? = nil) -> String {
        // UID can contain `@` and punctuation; keep the key printable.
        let safeUID = uid.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? uid
        let safeAcct = accountId.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? accountId
        var key = "calendar.rsvp.\(safeAcct).\(safeUID)"
        if let recurrenceIdLine, !recurrenceIdLine.isEmpty {
            let safeRID = recurrenceIdLine
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? recurrenceIdLine
            key += ".\(safeRID)"
        }
        return key
    }

    static func storedRSVP(accountId: String, uid: String,
                           recurrenceIdLine: String? = nil,
                           defaults: UserDefaults = .standard) -> RSVP? {
        guard let raw = defaults.string(
            forKey: rsvpDefaultsKey(accountId: accountId, uid: uid,
                                    recurrenceIdLine: recurrenceIdLine))
        else { return nil }
        return RSVP(rawValue: raw)
    }

    static func storeRSVP(_ status: RSVP, accountId: String, uid: String,
                          recurrenceIdLine: String? = nil,
                          defaults: UserDefaults = .standard) {
        defaults.set(status.rawValue,
                     forKey: rsvpDefaultsKey(accountId: accountId, uid: uid,
                                             recurrenceIdLine: recurrenceIdLine))
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

    /// Split `NAME;PARAM=val:value`, respecting double-quoted param values so
    /// `CN="Boger; Ron"` does not break on the semicolon / colon inside quotes.
    static func splitProperty(_ line: String)
        -> (name: String, params: [String: String], value: String)? {
        // Find the first unquoted colon — that separates name/params from value.
        var inQuotes = false
        var colonIndex: String.Index?
        var i = line.startIndex
        while i < line.endIndex {
            let ch = line[i]
            if ch == "\"" { inQuotes.toggle() }
            else if ch == ":", !inQuotes {
                colonIndex = i
                break
            }
            i = line.index(after: i)
        }
        guard let colonIndex else { return nil }
        let nameAndParams = String(line[..<colonIndex])
        let value = String(line[line.index(after: colonIndex)...])

        // Split params on unquoted semicolons.
        var segments: [String] = []
        var current = ""
        inQuotes = false
        for ch in nameAndParams {
            if ch == "\"" { inQuotes.toggle(); current.append(ch); continue }
            if ch == ";", !inQuotes {
                segments.append(current)
                current = ""
                continue
            }
            current.append(ch)
        }
        segments.append(current)
        guard let namePart = segments.first, !namePart.isEmpty else { return nil }
        let name = namePart.uppercased()
        var params: [String: String] = [:]
        for seg in segments.dropFirst() {
            guard let eq = seg.firstIndex(of: "=") else { continue }
            let key = String(seg[..<eq]).uppercased()
            var val = String(seg[seg.index(after: eq)...])
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast())
                    .replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            params[key] = val
        }
        return (name, params, value)
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
                  let tz = resolveTimeZone(tzid) {
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

    /// Resolve an ICS TZID to a Foundation TimeZone. Handles IANA ids and a
    /// small Windows→IANA map for the Outlook-origin invites we actually see.
    static func resolveTimeZone(_ tzid: String) -> TimeZone? {
        let cleaned = tzid
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .trimmingCharacters(in: .whitespaces)
        if let tz = TimeZone(identifier: cleaned) { return tz }
        if let iana = windowsTimeZoneMap[cleaned],
           let tz = TimeZone(identifier: iana) { return tz }
        return nil
    }

    /// Common Windows TZ names → IANA. Incomplete by design; unmapped TZIDs
    /// still fall back to local time in `parseDate`.
    private static let windowsTimeZoneMap: [String: String] = [
        "W. Europe Standard Time": "Europe/Berlin",
        "Central European Standard Time": "Europe/Warsaw",
        "Romance Standard Time": "Europe/Paris",
        "GMT Standard Time": "Europe/London",
        "Greenwich Standard Time": "Atlantic/Reykjavik",
        "UTC": "UTC",
        "Eastern Standard Time": "America/New_York",
        "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver",
        "Pacific Standard Time": "America/Los_Angeles",
        "US Mountain Standard Time": "America/Phoenix",
        "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu",
        "Tokyo Standard Time": "Asia/Tokyo",
        "China Standard Time": "Asia/Shanghai",
        "India Standard Time": "Asia/Kolkata",
        "AUS Eastern Standard Time": "Australia/Sydney",
        "E. Australia Standard Time": "Australia/Brisbane",
        "Israel Standard Time": "Asia/Jerusalem",
        "Russian Standard Time": "Europe/Moscow",
        "South Africa Standard Time": "Africa/Johannesburg",
    ]

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
