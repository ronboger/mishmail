import Foundation
import GRDB

// MARK: - Records

struct Account: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "account"
    var id: String          // email address
    var displayName: String
    var historyId: String?  // last synced Gmail historyId
    var lastSyncAt: Date?
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
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    static func empty() -> SavedView {
        SavedView(id: nil, name: "", accountId: nil, labelId: nil, unreadOnly: false,
                  starredOnly: false, hasAttachmentOnly: false, senderContains: "",
                  showArchived: false, excludePromotions: false, category: nil)
    }
}

struct Snippet: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "snippet"
    var id: Int64?
    var name: String
    var body: String
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

struct LabelRow: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "label"
    var id: String          // "<account>:<labelId>"
    var accountId: String
    var gmailLabelId: String
    var name: String
    var type: String
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
        dbQueue = try DatabaseQueue(path: dir.appendingPathComponent("mail.sqlite").path)
        try migrator.migrate(dbQueue)
    }

    private var migrator: DatabaseMigrator {
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
        return m
    }
}
