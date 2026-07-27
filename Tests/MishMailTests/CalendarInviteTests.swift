import XCTest

final class CalendarInviteTests: XCTestCase {

    // Google Calendar–shaped REQUEST (matches the invite.ics style users get
    // when someone books a meeting with them).
    private let sampleRequest = """
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        CALSCALE:GREGORIAN
        METHOD:REQUEST
        BEGIN:VEVENT
        DTSTART:20260805T210000Z
        DTEND:20260805T220000Z
        DTSTAMP:20260727T182900Z
        ORGANIZER;CN=Erica Maldonado:mailto:erica@example.com
        UID:abc123@google.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=
         TRUE;CN=Ron Boger;X-NUM-GUESTS=0:mailto:ron@x.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;RSVP=TRUE
         ;CN=Erica Maldonado;X-NUM-GUESTS=0:mailto:erica@example.com
        CREATED:20260727T182800Z
        DESCRIPTION:Let's meet to discuss the roadmap.\\nBring notes.
        LAST-MODIFIED:20260727T182800Z
        LOCATION:Cafe Strada\\, Berkeley
        SEQUENCE:0
        STATUS:CONFIRMED
        SUMMARY:Emily\\, Jon x Ron [In-Person]
        TRANSP:OPAQUE
        END:VEVENT
        END:VCALENDAR
        """

    func testParseRequestBasicFields() {
        let invite = CalendarInvite.parse(sampleRequest)
        XCTAssertNotNil(invite)
        guard let invite else { return }
        XCTAssertEqual(invite.method, .request)
        XCTAssertEqual(invite.uid, "abc123@google.com")
        XCTAssertEqual(invite.summary, "Emily, Jon x Ron [In-Person]")
        XCTAssertEqual(invite.location, "Cafe Strada, Berkeley")
        XCTAssertTrue(invite.description.contains("roadmap"))
        XCTAssertEqual(invite.organizerEmail, "erica@example.com")
        XCTAssertEqual(invite.organizerName, "Erica Maldonado")
        XCTAssertEqual(invite.sequence, 0)
        XCTAssertFalse(invite.isAllDay)
        XCTAssertTrue(invite.isActionable)
        XCTAssertFalse(invite.isCancelled)
        XCTAssertNil(invite.recurrenceIdLine)
        XCTAssertEqual(Set(invite.attendeeEmails),
                       Set(["ron@x.com", "erica@example.com"]))
        XCTAssertNotNil(invite.start)
        XCTAssertNotNil(invite.end)
        // 2026-08-05 21:00–22:00 UTC
        XCTAssertEqual(invite.start?.timeIntervalSince1970, 1_785_963_600)
        XCTAssertEqual(invite.end?.timeIntervalSince1970, 1_785_967_200)
    }

    func testUnfoldedAttendeeLineDoesNotBreakParse() {
        // sampleRequest has a folded ATTENDEE line; UID must still parse.
        let invite = CalendarInvite.parse(sampleRequest)
        XCTAssertEqual(invite?.uid, "abc123@google.com")
        XCTAssertTrue(invite?.attendeeEmails.contains("ron@x.com") == true)
    }

    func testParseCancel() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:CANCEL
            VERSION:2.0
            BEGIN:VEVENT
            UID:cancel-1@x.com
            SUMMARY:Scrapped standup
            DTSTART:20260801T160000Z
            ORGANIZER:mailto:boss@x.com
            SEQUENCE:1
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)
        XCTAssertEqual(invite?.method, .cancel)
        XCTAssertTrue(invite?.isCancelled == true)
        XCTAssertFalse(invite?.isActionable == true)
    }

    func testAllDayDate() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:allday@x.com
            SUMMARY:Offsite
            DTSTART;VALUE=DATE:20260810
            DTEND;VALUE=DATE:20260812
            ORGANIZER:mailto:hr@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)
        XCTAssertTrue(invite?.isAllDay == true)
        XCTAssertNotNil(invite?.start)
        XCTAssertNotNil(invite?.end)
    }

    func testDurationFallbackWhenNoDTEND() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:dur@x.com
            SUMMARY:Quick call
            DTSTART:20260805T150000Z
            DURATION:PT45M
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)
        XCTAssertEqual(invite?.start?.timeIntervalSince1970, 1_785_942_000)
        XCTAssertEqual(invite?.end?.timeIntervalSince1970, 1_785_942_000 + 45 * 60)
    }

    func testParseDuration() {
        XCTAssertEqual(CalendarInvite.parseDuration("PT1H30M"), 5400)
        XCTAssertEqual(CalendarInvite.parseDuration("P1D"), 86400)
        XCTAssertEqual(CalendarInvite.parseDuration("-PT15M"), -900)
        XCTAssertEqual(CalendarInvite.parseDuration("P1W"), 7 * 86400)
        XCTAssertNil(CalendarInvite.parseDuration("not-a-duration"))
    }

    func testReplyICSContainsMethodAndPartstat() {
        let invite = CalendarInvite.parse(sampleRequest)!
        let ics = invite.replyICS(status: .accepted,
                                  attendeeEmail: "ron@x.com",
                                  attendeeName: "Ron Boger")
        // Unfold so assertions ignore RFC 5545 folding of long ATTENDEE lines.
        let logical = CalendarInvite.unfold(ics).joined(separator: "\n")
        XCTAssertTrue(logical.contains("METHOD:REPLY"))
        XCTAssertTrue(logical.contains("PARTSTAT=ACCEPTED"))
        XCTAssertTrue(logical.contains("mailto:ron@x.com"))
        XCTAssertTrue(logical.contains("UID:abc123@google.com"))
        XCTAssertTrue(logical.contains("ORGANIZER"))
        XCTAssertTrue(logical.contains("mailto:erica@example.com"))
        XCTAssertTrue(logical.contains("SUMMARY:Emily\\, Jon x Ron [In-Person]")
                      || logical.contains("SUMMARY:Emily, Jon x Ron [In-Person]"),
                      "summary missing in reply:\n\(logical)")
    }

    func testReplyAttachmentMimeAndSubject() {
        let invite = CalendarInvite.parse(sampleRequest)!
        let att = invite.replyAttachment(status: .tentative, attendeeEmail: "ron@x.com")
        XCTAssertEqual(att.filename, "invite.ics")
        XCTAssertTrue(att.mimeType.contains("text/calendar"))
        XCTAssertTrue(att.mimeType.contains("method=REPLY"))
        XCTAssertFalse(att.data.isEmpty)
        XCTAssertEqual(invite.replySubject(status: .declined),
                       "Declined: Emily, Jon x Ron [In-Person]")
        XCTAssertTrue(invite.replyBody(status: .accepted, responderName: "Ron")
            .contains("accepted"))
    }

    func testMissingUIDReturnsNil() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            SUMMARY:No uid
            END:VEVENT
            END:VCALENDAR
            """
        XCTAssertNil(CalendarInvite.parse(ics))
    }

    func testIsCalendarAttachment() {
        XCTAssertTrue(CalendarInvite.isCalendarAttachment(
            mimeType: "text/calendar; charset=UTF-8", filename: "invite.ics"))
        XCTAssertTrue(CalendarInvite.isCalendarAttachment(
            mimeType: "application/octet-stream", filename: "meeting.ICS"))
        XCTAssertFalse(CalendarInvite.isCalendarAttachment(
            mimeType: "application/pdf", filename: "deck.pdf"))
    }

    func testRSVPPersistenceRoundTrip() {
        // Dedicated suite so we don't clobber the user's defaults.
        let suite = "CalendarInviteTests.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        XCTAssertNil(CalendarInvite.storedRSVP(accountId: "ron@x.com",
                                               uid: "abc@google.com",
                                               defaults: ud))
        CalendarInvite.storeRSVP(.accepted, accountId: "ron@x.com",
                                 uid: "abc@google.com", defaults: ud)
        XCTAssertEqual(
            CalendarInvite.storedRSVP(accountId: "ron@x.com",
                                      uid: "abc@google.com",
                                      defaults: ud),
            .accepted)
    }

    func testWhenDescriptionAllDay() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:d@x.com
            SUMMARY:Day
            DTSTART;VALUE=DATE:20260810
            DTEND;VALUE=DATE:20260811
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        let desc = invite.whenDescription()
        XCTAssertFalse(desc.isEmpty)
        // Should not look like a time-of-day string.
        XCTAssertFalse(desc.contains(":"))
    }

    func testMIMEBuilderKeepsCalendarMethodParameter() {
        let invite = CalendarInvite.parse(sampleRequest)!
        let att = invite.replyAttachment(status: .accepted, attendeeEmail: "ron@x.com")
        let raw = MIMEBuilder.build(
            from: "Ron <ron@x.com>", to: "erica@example.com",
            subject: invite.replySubject(status: .accepted),
            bodyText: invite.replyBody(status: .accepted, responderName: "Ron"),
            inReplyTo: "<orig@mail>",
            attachments: [att])
        let text = String(data: raw, encoding: .utf8)!
        XCTAssertTrue(text.contains("text/calendar; method=REPLY"))
        XCTAssertTrue(text.contains("filename=\"invite.ics\""))
        XCTAssertTrue(text.contains("In-Reply-To: <orig@mail>"))
        XCTAssertTrue(text.contains("Subject: Accepted:"))
    }

    // MARK: - Fable review follow-ups

    func testRecurrenceIdEchoedInReply() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:series@google.com
            SUMMARY:Weekly sync
            DTSTART:20260805T170000Z
            DTEND:20260805T173000Z
            RECURRENCE-ID:20260805T170000Z
            ORGANIZER:mailto:lead@x.com
            ATTENDEE:mailto:ron@x.com
            SEQUENCE:0
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        XCTAssertEqual(invite.recurrenceIdLine, "RECURRENCE-ID:20260805T170000Z")
        let reply = invite.replyICS(status: .accepted, attendeeEmail: "ron@x.com")
        XCTAssertTrue(reply.contains("RECURRENCE-ID:20260805T170000Z"),
                      "instance RSVP must carry RECURRENCE-ID; got:\n\(reply)")
    }

    func testRecurrenceIdWithTZIDPreserved() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:series@x.com
            SUMMARY:Office hours
            DTSTART;TZID=America/Los_Angeles:20260805T100000
            DTEND;TZID=America/Los_Angeles:20260805T110000
            RECURRENCE-ID;TZID=America/Los_Angeles:20260805T100000
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        XCTAssertEqual(invite.recurrenceIdLine,
                       "RECURRENCE-ID;TZID=America/Los_Angeles:20260805T100000")
        let reply = invite.replyICS(status: .declined, attendeeEmail: "ron@x.com")
        XCTAssertTrue(reply.contains(
            "RECURRENCE-ID;TZID=America/Los_Angeles:20260805T100000"))
    }

    func testValarmDoesNotOverwriteDescription() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:alarm@x.com
            SUMMARY:Dentist
            DESCRIPTION:Bring insurance card
            DTSTART:20260805T180000Z
            DTEND:20260805T190000Z
            ORGANIZER:mailto:desk@clinic.com
            BEGIN:VALARM
            TRIGGER:-PT30M
            ACTION:DISPLAY
            DESCRIPTION:REMINDER
            END:VALARM
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        XCTAssertEqual(invite.description, "Bring insurance card")
        XCTAssertNotEqual(invite.description, "REMINDER")
        XCTAssertEqual(invite.summary, "Dentist")
    }

    func testValarmBeforeDescriptionStillSkipped() {
        // First-wins would have kept REMINDER if VALARM weren't skipped.
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:alarm2@x.com
            SUMMARY:Call
            DTSTART:20260805T180000Z
            BEGIN:VALARM
            DESCRIPTION:REMINDER
            ACTION:DISPLAY
            TRIGGER:-PT15M
            END:VALARM
            DESCRIPTION:Real notes
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        XCTAssertEqual(invite.description, "Real notes")
    }

    func testOnlyRequestIsActionable() {
        XCTAssertTrue(CalendarInvite.parse("""
            BEGIN:VCALENDAR
            METHOD:REQUEST
            BEGIN:VEVENT
            UID:r@x.com
            SUMMARY:Meet
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """)?.isActionable == true)

        XCTAssertFalse(CalendarInvite.parse("""
            BEGIN:VCALENDAR
            METHOD:PUBLISH
            BEGIN:VEVENT
            UID:p@x.com
            SUMMARY:Holiday
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """)?.isActionable == true)

        // No METHOD → unknown → not actionable (untrusted ORGANIZER).
        XCTAssertFalse(CalendarInvite.parse("""
            BEGIN:VCALENDAR
            BEGIN:VEVENT
            UID:u@x.com
            SUMMARY:Exported
            ORGANIZER:mailto:stranger@evil.example
            END:VEVENT
            END:VCALENDAR
            """)?.isActionable == true)
    }

    func testWindowsTZIDMapsToIANA() {
        XCTAssertEqual(
            CalendarInvite.resolveTimeZone("Pacific Standard Time")?.identifier,
            "America/Los_Angeles")
        XCTAssertEqual(
            CalendarInvite.resolveTimeZone("W. Europe Standard Time")?.identifier,
            "Europe/Berlin")
        // IANA passes through.
        XCTAssertEqual(
            CalendarInvite.resolveTimeZone("America/New_York")?.identifier,
            "America/New_York")
        XCTAssertNil(CalendarInvite.resolveTimeZone("Totally Fake Zone"))
    }

    func testWindowsTZIDUsedForDTSTART() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:outlook@x.com
            SUMMARY:Standup
            DTSTART;TZID=Pacific Standard Time:20260805T090000
            DTEND;TZID=Pacific Standard Time:20260805T093000
            ORGANIZER:mailto:boss@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        // 2026-08-05 09:00 America/Los_Angeles (PDT, UTC-7) = 16:00 UTC
        let expected = TimeZone(identifier: "America/Los_Angeles")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = expected
        let start = cal.date(from: DateComponents(
            year: 2026, month: 8, day: 5, hour: 9, minute: 0, second: 0))!
        XCTAssertEqual(invite.start?.timeIntervalSince1970, start.timeIntervalSince1970)
    }

    func testQuotedCNWithSemicolon() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:cn@x.com
            SUMMARY:Chat
            DTSTART:20260805T180000Z
            ORGANIZER;CN="Boger; Ron":mailto:ron@x.com
            ATTENDEE;CN="Smith, Jane":mailto:jane@y.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        XCTAssertEqual(invite.organizerEmail, "ron@x.com")
        XCTAssertEqual(invite.organizerName, "Boger; Ron")
        XCTAssertEqual(invite.attendeeEmails, ["jane@y.com"])
    }

    func testSplitPropertyRespectsQuotedParams() {
        let line = #"ORGANIZER;CN="Boger; Ron":mailto:ron@x.com"#
        let parsed = CalendarInvite.splitProperty(line)
        XCTAssertEqual(parsed?.name, "ORGANIZER")
        XCTAssertEqual(parsed?.params["CN"], "Boger; Ron")
        XCTAssertEqual(parsed?.value, "mailto:ron@x.com")
    }

    func testRSVPPersistenceIsPerRecurrenceInstance() {
        let suite = "CalendarInviteTests.rid.\(UUID().uuidString)"
        let ud = UserDefaults(suiteName: suite)!
        defer { ud.removePersistentDomain(forName: suite) }
        let rid = "RECURRENCE-ID:20260805T170000Z"
        CalendarInvite.storeRSVP(.accepted, accountId: "ron@x.com",
                                 uid: "series@x.com",
                                 recurrenceIdLine: rid, defaults: ud)
        // Master (no RID) is still unanswered.
        XCTAssertNil(CalendarInvite.storedRSVP(
            accountId: "ron@x.com", uid: "series@x.com", defaults: ud))
        XCTAssertEqual(
            CalendarInvite.storedRSVP(
                accountId: "ron@x.com", uid: "series@x.com",
                recurrenceIdLine: rid, defaults: ud),
            .accepted)
    }

    // MARK: - Line folding + multi-VEVENT

    func testFoldLineRespects75OctetLimit() {
        let long = "SUMMARY:" + String(repeating: "A", count: 120)
        let folded = CalendarInvite.foldLine(long)
        let physical = folded.components(separatedBy: "\r\n")
        XCTAssertGreaterThan(physical.count, 1)
        for (i, line) in physical.enumerated() {
            let octets = line.utf8.count
            XCTAssertLessThanOrEqual(octets, 75, "line \(i) is \(octets) octets: \(line.prefix(80))")
            if i > 0 {
                XCTAssertTrue(line.hasPrefix(" "), "continuation must start with SPACE")
            }
        }
        // Unfold must recover the logical line.
        let recovered = physical.enumerated().map { i, l in
            i == 0 ? l : String(l.dropFirst())
        }.joined()
        XCTAssertEqual(recovered, long)
    }

    func testReplyICSFoldsLongSummary() {
        let summary = String(repeating: "Meeting about Q3 roadmap and budget ", count: 5)
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:long@x.com
            SUMMARY:\(summary)
            DTSTART:20260805T180000Z
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let invite = CalendarInvite.parse(ics)!
        let reply = invite.replyICS(status: .accepted, attendeeEmail: "ron@x.com")
        for line in reply.components(separatedBy: "\r\n") where !line.isEmpty {
            XCTAssertLessThanOrEqual(line.utf8.count, 75,
                                     "unfolded-looking line too long: \(line.prefix(90))")
        }
        // METHOD and PARTSTAT still present after folding.
        XCTAssertTrue(reply.contains("METHOD:REPLY"))
        XCTAssertTrue(reply.contains("PARTSTAT=ACCEPTED"))
    }

    func testParseAllMultipleVEVENTs() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:master@x.com
            SUMMARY:Weekly series
            DTSTART:20260801T170000Z
            DTEND:20260801T180000Z
            RRULE:FREQ=WEEKLY
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            BEGIN:VEVENT
            UID:master@x.com
            SUMMARY:Weekly series (exception)
            DTSTART:20260808T180000Z
            DTEND:20260808T190000Z
            RECURRENCE-ID:20260808T170000Z
            ORGANIZER:mailto:a@x.com
            END:VEVENT
            END:VCALENDAR
            """
        let all = CalendarInvite.parseAll(ics)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[0].summary, "Weekly series")
        XCTAssertNil(all[0].recurrenceIdLine)
        XCTAssertEqual(all[1].summary, "Weekly series (exception)")
        XCTAssertNotNil(all[1].recurrenceIdLine)
        // preferred() picks the instance (RECURRENCE-ID) over the master.
        let pref = CalendarInvite.preferred(from: all)
        XCTAssertEqual(pref?.recurrenceIdLine, "RECURRENCE-ID:20260808T170000Z")
        XCTAssertEqual(CalendarInvite.parse(ics)?.recurrenceIdLine,
                       "RECURRENCE-ID:20260808T170000Z")
    }

    func testPreferredFallsBackToFirstRequest() {
        let ics = """
            BEGIN:VCALENDAR
            METHOD:REQUEST
            VERSION:2.0
            BEGIN:VEVENT
            UID:a@x.com
            SUMMARY:First
            ORGANIZER:mailto:o@x.com
            END:VEVENT
            BEGIN:VEVENT
            UID:b@x.com
            SUMMARY:Second
            ORGANIZER:mailto:o@x.com
            END:VEVENT
            END:VCALENDAR
            """
        XCTAssertEqual(CalendarInvite.parse(ics)?.summary, "First")
        XCTAssertEqual(CalendarInvite.parseAll(ics).count, 2)
    }
}

