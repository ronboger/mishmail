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
        XCTAssertTrue(ics.contains("METHOD:REPLY"))
        XCTAssertTrue(ics.contains("PARTSTAT=ACCEPTED"))
        XCTAssertTrue(ics.contains("mailto:ron@x.com"))
        XCTAssertTrue(ics.contains("UID:abc123@google.com"))
        XCTAssertTrue(ics.contains("ORGANIZER"))
        XCTAssertTrue(ics.contains("mailto:erica@example.com"))
        XCTAssertTrue(ics.contains("SUMMARY:Emily\\, Jon x Ron [In-Person]")
                      || ics.contains("SUMMARY:Emily, Jon x Ron [In-Person]"))
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
}
