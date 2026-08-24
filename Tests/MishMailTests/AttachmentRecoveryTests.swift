import XCTest
import GRDB

/// Attachment recovery: stale local rows with body but hasAttachment=0, and
/// the pure open-pane policy that decides when to re-fetch.
final class AttachmentRecoveryTests: XCTestCase {

    private let account = "ron@x.com"

    private func migrate() throws -> DatabaseQueue {
        let q = try DatabaseQueue()
        try AppDatabase.migrator.migrate(q)
        try q.write { db in
            try Account(id: account, displayName: "P", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
        }
        return q
    }

    private func seed(_ q: DatabaseQueue, gmailId: String, hasAttachment: Bool,
                      withAttachmentRow: Bool = false) throws {
        try q.write { db in
            let local = "\(account):\(gmailId)"
            try Message(
                id: local, accountId: account, gmailId: gmailId,
                threadId: "\(account):t1", fromHeader: "a@b.com", toHeader: account,
                ccHeader: "", bccHeader: "", subject: "s", date: Date(),
                snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "INBOX", isUnread: false,
                hasAttachment: hasAttachment).save(db)
            if withAttachmentRow {
                try AttachmentRow(
                    id: nil, messageId: local, gmailAttachmentId: "att-\(gmailId)",
                    filename: "file.pdf", mimeType: "application/pdf", size: 12
                ).insert(db)
            }
        }
    }

    // MARK: - filterGmailIdsNeedingAttachmentRepair

    func testFilterEmptyListedReturnsEmpty() throws {
        let q = try migrate()
        let need = try q.read {
            try SyncEngine.filterGmailIdsNeedingAttachmentRepair(
                $0, accountId: account, listed: [])
        }
        XCTAssertEqual(need, [])
    }

    func testFilterReturnsOnlyLocalHasAttachmentFalse() throws {
        let q = try migrate()
        // Cached without attachments (the bug shape).
        try seed(q, gmailId: "stale", hasAttachment: false)
        // Cached already healthy.
        try seed(q, gmailId: "ok", hasAttachment: true, withAttachmentRow: true)
        // Not in local DB at all — repair only re-parses existing rows;
        // brand-new ids are handled by normal fetchAll.
        let listed = ["stale", "ok", "missing-on-server-list-only", "stale"]
        let need = try q.read {
            try SyncEngine.filterGmailIdsNeedingAttachmentRepair(
                $0, accountId: account, listed: listed)
        }
        XCTAssertEqual(need, ["stale"],
                       "only local hasAttachment=0 ids; dedupe; skip healthy + unknown")
    }

    func testFilterOtherAccountDoesNotCount() throws {
        let q = try migrate()
        try q.write { db in
            try Account(id: "other@x.com", displayName: "O", historyId: nil,
                        lastSyncAt: nil, senderName: "").save(db)
            try Message(
                id: "other@x.com:shared", accountId: "other@x.com", gmailId: "shared",
                threadId: "other@x.com:t1", fromHeader: "", toHeader: "",
                ccHeader: "", bccHeader: "", subject: "", date: Date(),
                snippet: "", bodyText: "", bodyHTML: nil, messageIdHeader: "",
                referencesHeader: "", labelIds: "INBOX", isUnread: false,
                hasAttachment: false).save(db)
        }
        let need = try q.read {
            try SyncEngine.filterGmailIdsNeedingAttachmentRepair(
                $0, accountId: account, listed: ["shared"])
        }
        XCTAssertEqual(need, [], "other account's row must not trigger repair here")
    }

    // MARK: - AttachmentRepairReport completion gate

    func testRepairReportCompletedCleanlyMeansFlagSafe() {
        // Pure structural pin: only a clean report is allowed to set the
        // one-shot flag (rate-limit exhaustion / listed-cap truncation must not).
        let clean = SyncEngine.AttachmentRepairReport(
            touchedKeys: ["t1"], completedCleanly: true)
        let dirty = SyncEngine.AttachmentRepairReport(
            touchedKeys: ["t1"], completedCleanly: false)
        XCTAssertTrue(clean.completedCleanly)
        XCTAssertFalse(dirty.completedCleanly)
        XCTAssertNotEqual(clean.completedCleanly, dirty.completedCleanly)
    }

    // MARK: - shouldRecoverAttachments policy

    func testRecoverWhenFlagTrueButRowsEmpty() {
        XCTAssertTrue(SyncEngine.shouldRecoverAttachments(
            hasAttachmentFlag: true, localAttachmentCount: 0,
            accountRepairCompleted: true))
    }

    func testRecoverWhenFlagFalseBeforeAccountRepair() {
        // Criocore / Let's chat shape before the one-shot sync pass runs.
        XCTAssertTrue(SyncEngine.shouldRecoverAttachments(
            hasAttachmentFlag: false, localAttachmentCount: 0,
            accountRepairCompleted: false))
    }

    func testSkipWhenFlagFalseAfterAccountRepair() {
        // Clean attachment-free mail once repair has classified the mailbox.
        XCTAssertFalse(SyncEngine.shouldRecoverAttachments(
            hasAttachmentFlag: false, localAttachmentCount: 0,
            accountRepairCompleted: true))
    }

    func testSkipWhenLocalRowsAlreadyPresent() {
        XCTAssertFalse(SyncEngine.shouldRecoverAttachments(
            hasAttachmentFlag: true, localAttachmentCount: 2,
            accountRepairCompleted: false))
        XCTAssertFalse(SyncEngine.shouldRecoverAttachments(
            hasAttachmentFlag: false, localAttachmentCount: 1,
            accountRepairCompleted: false))
    }

    // MARK: - Parse still collects real PDF parts (regression pin)

    func testParseMultipartPDFAttachmentIsCollected() throws {
        let b64 = Data("plain".utf8).base64URLEncoded()
        let json = """
        {
          "id": "criocore", "threadId": "t-c",
          "internalDate": "1744537063000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [
              {"name": "From", "value": "Carlos <c@criocore.com>"},
              {"name": "Subject", "value": "Criocore - Compound intro"}
            ],
            "parts": [
              {"mimeType": "multipart/alternative", "parts": [
                {"mimeType": "text/plain", "body": {"data": "\(b64)"}}
              ]},
              {
                "mimeType": "application/pdf",
                "filename": "Criocore (03-30-2026).pdf",
                "headers": [
                  {"name": "Content-ID", "value": "<19d8633b233a57bae121>"},
                  {"name": "Content-Disposition",
                   "value": "attachment; filename=\\"Criocore (03-30-2026).pdf\\""}
                ],
                "body": {"attachmentId": "att-pdf-1", "size": 3462501}
              }
            ]
          }
        }
        """
        let data = Data(json.utf8)
        let g = try JSONDecoder().decode(GMessage.self, from: data)
        let (message, attachments) = MessageParser.parse(g, accountId: account)
        XCTAssertTrue(message.hasAttachment)
        XCTAssertEqual(attachments.count, 1)
        XCTAssertEqual(attachments[0].filename, "Criocore (03-30-2026).pdf")
        XCTAssertEqual(attachments[0].gmailAttachmentId, "att-pdf-1")
        XCTAssertEqual(attachments[0].size, 3_462_501)
        XCTAssertEqual(attachments[0].contentId, "19d8633b233a57bae121")
    }

    func testParseForwardedMessageWithTwoPDFs() throws {
        let b64 = Data("fwd".utf8).base64URLEncoded()
        let json = """
        {
          "id": "letschat", "threadId": "t-l",
          "internalDate": "1750284629000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "Fwd: Let's chat!"}],
            "parts": [
              {"mimeType": "text/html", "body": {"data": "\(b64)"}},
              {"mimeType": "application/pdf", "filename": "NanoDEX_March2026.pdf",
               "body": {"attachmentId": "a1", "size": 5983617}},
              {"mimeType": "application/pdf",
               "filename": "Case for Day 1 - 818068-PDF-ENG.pdf",
               "body": {"attachmentId": "a2", "size": 1383693}}
            ]
          }
        }
        """
        let g = try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
        let (message, attachments) = MessageParser.parse(g, accountId: account)
        XCTAssertTrue(message.hasAttachment)
        XCTAssertEqual(attachments.map(\.filename), [
            "NanoDEX_March2026.pdf",
            "Case for Day 1 - 818068-PDF-ENG.pdf"
        ])
    }

    func testParseImageAndPDFKeepsBothParts() throws {
        // Surgical-plan shape: letterhead HTML + image.png + PDF. Search-open
        // recovery used to feed these to ForEach with nil ids, so the pane
        // drew two copies of one file and hid the other.
        let b64 = Data("hi".utf8).base64URLEncoded()
        let json = """
        {
          "id": "plan", "threadId": "t-plan",
          "internalDate": "1752404400000",
          "payload": {
            "mimeType": "multipart/mixed",
            "headers": [{"name": "Subject", "value": "Surgical Plan Images"}],
            "parts": [
              {"mimeType": "text/html", "body": {"data": "\(b64)"}},
              {"mimeType": "image/png", "filename": "image.png",
               "body": {"attachmentId": "att-img", "size": 35840}},
              {"mimeType": "application/pdf",
               "filename": "Ron Boger Single Piece LeFort and BSSO.pdf",
               "body": {"attachmentId": "att-pdf", "size": 599040}}
            ]
          }
        }
        """
        let g = try JSONDecoder().decode(GMessage.self, from: Data(json.utf8))
        let (_, attachments) = MessageParser.parse(g, accountId: account)
        XCTAssertEqual(attachments.map(\.filename), [
            "image.png",
            "Ron Boger Single Piece LeFort and BSSO.pdf"
        ])
        XCTAssertEqual(attachments.map(\.id), [nil, nil],
                       "parse rows are not inserted yet")
        let identities = attachments.map(\.displayIdentity)
        XCTAssertEqual(Set(identities).count, 2,
                       "ForEach must not collapse image + PDF onto one chip")
    }

    func testDisplayIdentityUsesRowIdWhenPresent() {
        let parsed = AttachmentRow(
            id: nil, messageId: "m", gmailAttachmentId: "a1",
            filename: "image.png", mimeType: "image/png", size: 10)
        let stored = AttachmentRow(
            id: 7, messageId: "m", gmailAttachmentId: "a1",
            filename: "image.png", mimeType: "image/png", size: 10)
        XCTAssertTrue(parsed.displayIdentity.hasPrefix("part:"))
        XCTAssertEqual(stored.displayIdentity, "row:7")
        XCTAssertNotEqual(parsed.displayIdentity, stored.displayIdentity)
    }

    func testParsedIdentifiableIdsCollideButDisplayIdentitiesDoNot() {
        let image = AttachmentRow(
            id: nil, messageId: "m", gmailAttachmentId: "img",
            filename: "image.png", mimeType: "image/png", size: 35_840)
        let pdf = AttachmentRow(
            id: nil, messageId: "m", gmailAttachmentId: "pdf",
            filename: "plan.pdf", mimeType: "application/pdf", size: 599_040)
        XCTAssertEqual(image.id, pdf.id)
        XCTAssertNotEqual(image.displayIdentity, pdf.displayIdentity)
    }

    func testReadingPaneRowsPreferPersistedWhenPresent() {
        let parsed = [
            AttachmentRow(id: nil, messageId: "m", gmailAttachmentId: "img",
                          filename: "image.png", mimeType: "image/png", size: 1),
            AttachmentRow(id: nil, messageId: "m", gmailAttachmentId: "pdf",
                          filename: "plan.pdf", mimeType: "application/pdf", size: 2)
        ]
        let persisted = [
            AttachmentRow(id: 1, messageId: "m", gmailAttachmentId: "img",
                          filename: "image.png", mimeType: "image/png", size: 1),
            AttachmentRow(id: 2, messageId: "m", gmailAttachmentId: "pdf",
                          filename: "plan.pdf", mimeType: "application/pdf", size: 2)
        ]
        let rows = AttachmentRow.readingPaneRows(parsed: parsed, persisted: persisted)
        XCTAssertEqual(rows.map(\.id), [1, 2])
        XCTAssertEqual(
            AttachmentRow.readingPaneRows(parsed: parsed, persisted: []).map(\.gmailAttachmentId),
            ["img", "pdf"])
    }
}
