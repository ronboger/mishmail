import Foundation
import GRDB

// MARK: - Records

struct Account: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "account"
    var id: String          // email address
    var displayName: String // user-facing label ("Personal", "Fund", …)
    var historyId: String?  // last synced Gmail historyId
    var lastSyncAt: Date?
    var senderName: String = ""   // real name shown to recipients on outgoing mail
}

struct MailThread: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "thread"
    var id: String          // "<account>:<gmailThreadId>"
    var accountId: String
    var gmailThreadId: String
    var subject: String
    var snippet: String
    var fromDisplay: String
    var lastDate: Date
    var isUnread: Bool
    var isStarred: Bool
    var inInbox: Bool
    var inTrash: Bool
    var labelIds: String    // space-separated Gmail label ids
    var snoozeUntil: Date?  // local snooze (client-side feature)
    var participants: String  // " .. "-joined display names, "me" for own sends
    var messageCount: Int
    var hasAttachment: Bool
    var reminderAt: Date?   // local follow-up reminder
    var reminderSetAt: Date? = nil  // thread activity cutoff for "remind if no reply"

    var labels: [String] { labelIds.split(separator: " ").map(String.init) }
}

struct Message: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message"
    var id: String          // "<account>:<gmailMessageId>"
    var accountId: String
    var gmailId: String
    var threadId: String    // FK to MailThread.id
    var fromHeader: String
    var toHeader: String
    var ccHeader: String
    var bccHeader: String = ""
    var subject: String
    var date: Date
    var snippet: String
    var bodyText: String
    var bodyHTML: String?
    var messageIdHeader: String   // RFC Message-ID, for reply threading
    var referencesHeader: String
    var labelIds: String
    var isUnread: Bool
    var hasAttachment: Bool
}

struct AttachmentRow: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "attachment"
    var id: Int64?
    var messageId: String   // FK to Message.id
    var gmailAttachmentId: String
    var filename: String
    var mimeType: String
    var size: Int
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct SavedView: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "savedView"
    var id: Int64?
    var name: String
    var accountId: String?      // nil = all accounts
    var labelId: String?        // Gmail label id
    var unreadOnly: Bool
    var starredOnly: Bool
    var hasAttachmentOnly: Bool
    var senderContains: String
    var showArchived: Bool
    var excludePromotions: Bool
    var category: String?       // CATEGORY_PROMOTIONS / _SOCIAL / _UPDATES / _FORUMS
    /// Full FilterChips serialized as JSON. Present for views created via
    /// "Save as view…" (lossless); nil for views built in the ViewEditor form,
    /// which fall back to the structured fields above.
    var chipsJSON: Data? = nil
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    static func empty() -> SavedView {
        SavedView(id: nil, name: "", accountId: nil, labelId: nil, unreadOnly: false,
                  starredOnly: false, hasAttachmentOnly: false, senderContains: "",
                  showArchived: false, excludePromotions: false, category: nil, chipsJSON: nil)
    }
}

struct Snippet: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snippet"
    var id: Int64?
    var name: String
    var body: String
    /// Intro etiquette: inserting this snippet moves To → Bcc and Cc → To.
    var movesToBcc: Bool = false
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Case-insensitive name-or-body match, shared by the compose panel and
    /// the settings page so their search behavior can't drift apart.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        return q.isEmpty
            || name.localizedCaseInsensitiveContains(q)
            || body.localizedCaseInsensitiveContains(q)
    }

    /// One-line preview for list rows.
    var previewLine: String { body.replacingOccurrences(of: "\n", with: " ") }
}

/// A composed message waiting for its send time. Gmail has no schedule-send
/// API, so the schedule is local: the app sends the message when it's due
/// (overdue ones go out on next launch).
struct ScheduledSend: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scheduledSend"
    var id: Int64?
    var accountId: String
    var toHeader: String
    var ccHeader: String
    var bccHeader: String
    var subject: String
    var body: String
    var sendAt: Date
    var replyToMessageId: String?   // Message.id, for reply threading
    var forward: Bool
    var replacingDraftId: String?   // Message.id of the Gmail draft this replaces
    var attachmentsJSON: Data       // JSON-encoded [MIMEBuilder.Attachment]
    var createdAt: Date
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    var attachments: [MIMEBuilder.Attachment] {
        (try? JSONDecoder().decode([MIMEBuilder.Attachment].self, from: attachmentsJSON)) ?? []
    }

    static func encodeAttachments(_ attachments: [MIMEBuilder.Attachment]) -> Data {
        (try? JSONEncoder().encode(attachments)) ?? Data("[]".utf8)
    }
}

/// On-device AI triage result for a thread (see MailStore.classifyInbox).
struct ThreadAICategory: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "threadAI"
    var threadId: String
    var category: String
    var id: String { threadId }
}

/// A VIP sender: mail from this address pins to the Inbox Priority section.
/// Emails are stored lowercased; the list is global across accounts.
struct VIPSender: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vipSender"
    var email: String
    var groupName: String? = nil
    var id: String { email }
}

/// A blocked sender: their threads are moved to Spam on sight (Notion
/// Mail-style "Block"). Emails are stored lowercased; global across accounts.
struct BlockedSender: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "blockedSender"
    var email: String
    var id: String { email }
}

struct LabelRow: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "label"
    /// sortOrder for labels the user hasn't ordered yet: they sort after any
    /// explicitly ordered labels, alphabetically among themselves.
    static let unsorted = 1_000_000
    var id: String          // "<account>:<labelId>"
    var accountId: String
    var gmailLabelId: String
    var name: String
    var type: String
    /// Display color as "#RRGGBB". Locally chosen (or seeded from Gmail's
    /// label color on first sync); nil falls back to a name-stable color.
    var color: String?
    var sortOrder: Int = LabelRow.unsorted
}

// MARK: - Database

final class AppDatabase {
    static let shared = try! AppDatabase()
    let dbQueue: DatabaseQueue

    init() throws {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory,
                                              in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("PerfectMail", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mail.sqlite").path

        // The mail cache is encrypted with SQLCipher; the key never leaves
        // the Keychain. A pre-encryption database is migrated in place.
        let passphrase = try Self.databaseKey()
        if FileManager.default.fileExists(atPath: path), Self.isPlaintext(path) {
            try Self.encryptInPlace(path: path, passphrase: passphrase)
        }
        do {
            dbQueue = try Self.openAndMigrate(path: path, passphrase: passphrase)
        } catch {
            // The cache can't be opened — wrong key (keychain item lost or
            // rotated, e.g. a backup restore) or a corrupt file. Everything in
            // it resyncs from Gmail, so set it aside and start fresh instead
            // of crashing at launch.
            NSLog("PerfectMail: mail cache unreadable (%@); resetting", "\(error)")
            try Self.setAsideUnreadable(path: path)
            dbQueue = try Self.openAndMigrate(path: path, passphrase: passphrase)
        }
    }

    private static func openAndMigrate(path: String, passphrase: String) throws -> DatabaseQueue {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
        }
        let queue = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(queue)
        return queue
    }

    /// Moves an unreadable database out of the way (kept as .unreadable for
    /// post-mortems, replacing any previous one) along with its WAL sidecars.
    private static func setAsideUnreadable(path: String) throws {
        let fm = FileManager.default
        try? fm.removeItem(atPath: path + ".unreadable")
        try fm.moveItem(atPath: path, toPath: path + ".unreadable")
        for sidecar in ["-wal", "-shm"] {
            try? fm.removeItem(atPath: path + sidecar)
        }
    }

    /// Random 256-bit key, hex-encoded, generated once and kept in the Keychain.
    private static func databaseKey() throws -> String {
        if let existing = Keychain.get("db.key") { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw KeychainError.status(errSecParam)
        }
        let key = bytes.map { String(format: "%02x", $0) }.joined()
        try Keychain.set(key, forKey: "db.key")
        return key
    }

    /// A plaintext SQLite file starts with the magic "SQLite format 3\0";
    /// an SQLCipher file starts with a random salt.
    private static func isPlaintext(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path),
              let magic = try? handle.read(upToCount: 16) else { return false }
        try? handle.close()
        return magic.elementsEqual("SQLite format 3\u{0}".utf8)
    }

    /// One-time migration: exports the plaintext database into an encrypted
    /// copy (sqlcipher_export) and swaps it into place.
    private static func encryptInPlace(path: String, passphrase: String) throws {
        let tmp = path + ".encrypting"
        try? FileManager.default.removeItem(atPath: tmp)
        let plain = try DatabaseQueue(path: path)
        try plain.inDatabase { db in
            try db.execute(sql: "ATTACH DATABASE ? AS encrypted KEY ?", arguments: [tmp, passphrase])
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
        }
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.moveItem(atPath: tmp, toPath: path)
    }

    /// Static so tests can migrate an in-memory database.
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "account") { t in
                t.primaryKey("id", .text)
                t.column("displayName", .text).notNull()
                t.column("historyId", .text)
                t.column("lastSyncAt", .datetime)
            }
            try db.create(table: "thread") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull().indexed()
                    .references("account", onDelete: .cascade)
                t.column("gmailThreadId", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("snippet", .text).notNull()
                t.column("fromDisplay", .text).notNull()
                t.column("lastDate", .datetime).notNull().indexed()
                t.column("isUnread", .boolean).notNull()
                t.column("isStarred", .boolean).notNull()
                t.column("inInbox", .boolean).notNull().indexed()
                t.column("inTrash", .boolean).notNull()
                t.column("labelIds", .text).notNull()
                t.column("snoozeUntil", .datetime)
            }
            try db.create(table: "message") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull().indexed()
                    .references("account", onDelete: .cascade)
                t.column("gmailId", .text).notNull()
                t.column("threadId", .text).notNull().indexed()
                t.column("fromHeader", .text).notNull()
                t.column("toHeader", .text).notNull()
                t.column("ccHeader", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("date", .datetime).notNull()
                t.column("snippet", .text).notNull()
                t.column("bodyText", .text).notNull()
                t.column("bodyHTML", .text)
                t.column("messageIdHeader", .text).notNull()
                t.column("referencesHeader", .text).notNull()
                t.column("labelIds", .text).notNull()
                t.column("isUnread", .boolean).notNull()
            }
            try db.create(table: "label") { t in
                t.primaryKey("id", .text)
                t.column("accountId", .text).notNull().indexed()
                    .references("account", onDelete: .cascade)
                t.column("gmailLabelId", .text).notNull()
                t.column("name", .text).notNull()
                t.column("type", .text).notNull()
            }
            try db.create(table: "snippet") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("body", .text).notNull()
            }
            // Full-text search over messages, kept in sync by triggers.
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.column("subject")
                t.column("fromHeader")
                t.column("bodyText")
            }
        }
        m.registerMigration("v2") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "participants", .text).notNull().defaults(to: "")
                t.add(column: "messageCount", .integer).notNull().defaults(to: 1)
                t.add(column: "hasAttachment", .boolean).notNull().defaults(to: false)
                t.add(column: "reminderAt", .datetime)
            }
            try db.alter(table: "message") { t in
                t.add(column: "hasAttachment", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "attachment") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("messageId", .text).notNull().indexed()
                    .references("message", onDelete: .cascade)
                t.column("gmailAttachmentId", .text).notNull()
                t.column("filename", .text).notNull()
                t.column("mimeType", .text).notNull()
                t.column("size", .integer).notNull()
            }
            try db.create(table: "savedView") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("name", .text).notNull()
                t.column("accountId", .text)
                t.column("labelId", .text)
                t.column("unreadOnly", .boolean).notNull().defaults(to: false)
                t.column("starredOnly", .boolean).notNull().defaults(to: false)
                t.column("hasAttachmentOnly", .boolean).notNull().defaults(to: false)
                t.column("senderContains", .text).notNull().defaults(to: "")
                t.column("showArchived", .boolean).notNull().defaults(to: false)
                t.column("excludePromotions", .boolean).notNull().defaults(to: false)
                t.column("category", .text)
            }
        }
        m.registerMigration("v3") { db in
            try db.alter(table: "account") { t in
                t.add(column: "senderName", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v4") { db in
            try db.alter(table: "message") { t in
                t.add(column: "bccHeader", .text).notNull().defaults(to: "")
            }
        }
        m.registerMigration("v5") { db in
            try db.create(table: "scheduledSend") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("accountId", .text).notNull()
                t.column("toHeader", .text).notNull()
                t.column("ccHeader", .text).notNull()
                t.column("bccHeader", .text).notNull()
                t.column("subject", .text).notNull()
                t.column("body", .text).notNull()
                t.column("sendAt", .datetime).notNull().indexed()
                t.column("replyToMessageId", .text)
                t.column("forward", .boolean).notNull().defaults(to: false)
                t.column("replacingDraftId", .text)
                t.column("attachmentsJSON", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }
        }
        // Local, on-device AI triage. Kept in its own table so re-deriving
        // thread metadata during sync never wipes a classification.
        m.registerMigration("v6") { db in
            try db.create(table: "threadAI") { t in
                t.column("threadId", .text).primaryKey()
                t.column("category", .text).notNull()
            }
        }
        // Lossless saved views: the full filter set, serialized as JSON.
        m.registerMigration("v7") { db in
            try db.alter(table: "savedView") { t in
                t.add(column: "chipsJSON", .blob)
            }
        }
        // "Remind if no reply": remember the thread's activity level when a
        // reminder is set, so the reminder can cancel itself if the thread moves.
        m.registerMigration("v8") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "reminderSetAt", .datetime)
            }
        }
        // Move-to-bcc snippets (intro etiquette: To → Bcc, Cc → To on insert).
        m.registerMigration("v9") { db in
            try db.alter(table: "snippet") { t in
                t.add(column: "movesToBcc", .boolean).notNull().defaults(to: false)
            }
        }
        // Label colors (local hex override, seeded from Gmail's palette) and
        // user-defined ordering. Unordered labels sort after ordered ones,
        // hence the large default.
        m.registerMigration("v10") { db in
            try db.alter(table: "label") { t in
                t.add(column: "color", .text)
                t.add(column: "sortOrder", .integer).notNull().defaults(to: LabelRow.unsorted)
            }
        }
        // VIP senders: mail from these addresses pins to the Inbox Priority
        // section. Stored lowercased; global across accounts.
        m.registerMigration("v11") { db in
            try db.create(table: "vipSender") { t in
                t.primaryKey("email", .text)
            }
        }
        // Blocked senders: their threads leave the inbox for Spam, now and on
        // every future sync. Stored lowercased; global across accounts.
        m.registerMigration("v12") { db in
            try db.create(table: "blockedSender") { t in
                t.primaryKey("email", .text)
            }
        }
        // VIP groups: optional tag (founders, investors, family, …) per VIP sender.
        m.registerMigration("v13") { db in
            try db.alter(table: "vipSender") { t in
                t.add(column: "groupName", .text)
            }
        }
        return m
    }
}
