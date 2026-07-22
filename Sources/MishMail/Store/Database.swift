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
    // Denormalized label/category flags — avoids scanning labelIds / messages
    // for common mailbox filters (Sent, Drafts, Promotions, Social).
    var inSent: Bool = false
    var inDrafts: Bool = false
    /// Tab placement for Promotions (Primary inbox hides this). Set from the
    /// newest *INBOX-bearing* message at derive time — not from the union of
    /// `labelIds`, which keeps historical CATEGORY_PROMOTIONS on old invites.
    var inPromotions: Bool = false
    /// Same placement rule as `inPromotions`, for CATEGORY_SOCIAL.
    var inSocial: Bool = false
    /// True when any message still carries Gmail's SPAM label. Promotions/
    /// Social lists exclude these so they match gmail.com (spam is not a tab).
    var inSpam: Bool = false
    /// Lowercased email of the newest message's From (for VIP matching without scanning messages).
    var fromEmail: String = ""
    /// Space-separated unique lowercased From emails across all messages in
    /// the thread (for blocklist any-message match without scanning messages).
    var allFromEmails: String = ""
    /// Newest *inbound* message date (excludes pure outbound: SENT-without-INBOX,
    /// DRAFT, From=mailbox without INBOX). Nil when the thread has only own
    /// outbound. Inbox-style lists order by `COALESCE(lastInboundDate, lastDate)`
    /// so your reply doesn't jump a conversation to the top; Sent/Drafts/search
    /// and the row timestamp keep using `lastDate` (newest any message).
    /// "Remind if no reply" cancels only when this advances past `reminderSetAt`.
    var lastInboundDate: Date? = nil

    var labels: [String] { labelIds.split(separator: " ").map(String.init) }

    /// Sort key for inbox-style lists (inbox / promotions / social / per-account inbox).
    var inboxSortDate: Date { lastInboundDate ?? lastDate }

    /// User-label Gmail ids (`Label_*`) from the space-separated `labelIds`.
    var userLabelIds: [String] {
        labels.filter { $0.hasPrefix("Label_") }
    }

    /// Re-derive boolean flags from the space-separated `labelIds` string so
    /// local label mutations stay coherent with list/badge filters that use
    /// the denormalized columns.
    ///
    /// Does **not** touch `inPromotions` / `inSocial`: those are tab-placement
    /// flags from the newest INBOX-bearing message (`SyncEngine.tabCategoryFlags`),
    /// and `labelIds` is the historical union (still useful for search). Clobbering
    /// them from the union would hide personal replies under Promotions again
    /// after any optimistic mutation.
    mutating func syncFlagsFromLabelIds() {
        let set = Set(labels)
        isStarred = set.contains("STARRED")
        inInbox = set.contains("INBOX")
        inTrash = set.contains("TRASH")
        inSent = set.contains("SENT")
        inDrafts = set.contains("DRAFT")
        inSpam = set.contains("SPAM")
    }

    /// Apply a local label add/remove and re-derive the denormalized flags.
    /// Seeds STARRED/INBOX from `isStarred`/`inInbox` first: those flags can
    /// be optimistically ahead of `labelIds` (star/archive/snooze mutate only
    /// the flag), and syncFlagsFromLabelIds would otherwise clobber them.
    /// Explicit CATEGORY_PROMOTIONS / CATEGORY_SOCIAL add/remove update tab
    /// placement; other mutations leave `inPromotions` / `inSocial` alone.
    mutating func applyLabelMutation(add: Set<String> = [], remove: Set<String> = []) {
        var set = Set(labels)
        if isStarred { set.insert("STARRED") } else { set.remove("STARRED") }
        if inInbox { set.insert("INBOX") } else { set.remove("INBOX") }
        set.subtract(remove)
        set.formUnion(add)
        labelIds = set.sorted().joined(separator: " ")
        syncFlagsFromLabelIds()
        if add.contains("CATEGORY_PROMOTIONS") { inPromotions = true }
        if remove.contains("CATEGORY_PROMOTIONS") { inPromotions = false }
        if add.contains("CATEGORY_SOCIAL") { inSocial = true }
        if remove.contains("CATEGORY_SOCIAL") { inSocial = false }
    }
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
    /// Empty after v24 for rows written via upsert — body lives in `message_body`.
    /// Still populated in-memory by the parser before split on write.
    var bodyText: String
    var bodyHTML: String?
    var messageIdHeader: String   // RFC Message-ID, for reply threading
    var referencesHeader: String
    var labelIds: String
    var isUnread: Bool
    var hasAttachment: Bool
}

/// Off-row body storage (v24). Keeps fat HTML off the `message` row so header
/// projections and list joins stay cheap under SQLCipher.
struct MessageBody: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "message_body"
    var id: String { messageId }
    var messageId: String   // PK, FK → message
    var bodyText: String
    var bodyHTML: String?
}

/// User-label membership for a thread (v23). System labels stay on denorm
/// flags / `labelIds`; queries for `Label_*` use this junction instead of LIKE.
struct ThreadLabel: Codable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "thread_label"
    var threadId: String
    var labelId: String     // Gmail user label id, e.g. Label_42
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
    /// JSON array of account emails that may use this snippet. `nil` or `[]`
    /// means available on every account (the default).
    var accountIdsJSON: String? = nil
    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }

    /// Account emails this snippet is scoped to. Empty = all accounts.
    var accountIds: [String] {
        get {
            guard let raw = accountIdsJSON?.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: raw)
            else { return [] }
            return decoded
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            let cleaned = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if cleaned.isEmpty {
                accountIdsJSON = nil
            } else if let data = try? JSONEncoder().encode(cleaned),
                      let s = String(data: data, encoding: .utf8) {
                accountIdsJSON = s
            }
        }
    }

    /// Whether this snippet may appear while composing as `accountId`.
    /// Empty `accountId` is treated as "not yet resolved" and keeps every
    /// snippet visible (compose fills From before send is allowed).
    func isAvailable(for accountId: String) -> Bool {
        let ids = accountIds
        guard !ids.isEmpty else { return true }
        let target = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return true }
        return ids.contains { $0.caseInsensitiveCompare(target) == .orderedSame }
    }

    /// Scope entries that still match a signed-in account (case-insensitive).
    /// Used to surface "removed account" orphans after sign-out.
    func accountIds(among knownAccountIds: [String]) -> (live: [String], removed: [String]) {
        let known = Set(knownAccountIds
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty })
        var live: [String] = []
        var removed: [String] = []
        for id in accountIds {
            if known.contains(id.lowercased()) {
                live.append(id)
            } else {
                removed.append(id)
            }
        }
        return (live, removed)
    }

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

    /// Stable identity for SwiftUI lists (optional DB id is nil for drafts).
    var listId: String {
        if let id { return "id-\(id)" }
        return "name-\(name.lowercased())"
    }
}

/// A composed message waiting for its send time. Gmail has no schedule-send
/// API, so the schedule is local: the app sends the message when it's due
/// (overdue ones go out on next launch).
struct ScheduledSend: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "scheduledSend"
    var id: Int64?
    var accountId: String
    /// From identity email (send-as or primary). Empty → treat as accountId
    /// (rows scheduled before v20).
    var fromEmail: String = ""
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

    /// Effective From address for MIME (send-as or the mailbox primary).
    var effectiveFromEmail: String {
        fromEmail.isEmpty ? accountId : fromEmail
    }

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

/// A VIP group definition: persists even with no members, and `enabled`
/// pauses/resumes VIP status for every sender tagged with the group.
struct VIPGroupRow: Codable, Identifiable, Hashable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "vipGroup"
    var name: String
    var enabled: Bool = true
    var id: String { name }
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
    // A pool (WAL), not a serial queue: concurrent readers (e.g. the live
    // search dropdown's per-keystroke FTS lookup) run on their own snapshot
    // connections instead of queuing behind a sync-engine write transaction.
    let dbPool: DatabasePool
    /// True after `close()` — no further access is valid (process is quitting).
    private(set) var isClosed = false
    private let closeLock = NSLock()

    init() throws {
        let root = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask, appropriateFor: nil, create: true)
        let environment = ProcessInfo.processInfo.environment
        let isUITest = environment["MISHMAIL_UI_TEST"] == "1"
        let isDeveloperDemo = environment["MISHMAIL_DEMO"] == "1"
        let dir = Self.storageDirectory(
            root: root,
            isUITest: isUITest,
            isDeveloperDemo: isDeveloperDemo
        )
        // UI automation gets a dedicated, disposable database. A developer's
        // signed-in Debug mailbox is never inspected, seeded, or removed.
        if isUITest, FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("mail.sqlite").path

        // Real mail is encrypted with a Keychain-held key. The fictional demo
        // uses a fixed non-secret fixture key so an ad-hoc source build never
        // asks for Keychain access (and can be rebuilt freely).
        let passphrase = try Self.databaseKey()
        if FileManager.default.fileExists(atPath: path), Self.isPlaintext(path) {
            try Self.encryptInPlace(path: path, passphrase: passphrase)
        }
        do {
            dbPool = try Self.openAndMigrate(path: path, passphrase: passphrase)
        } catch {
            // The cache can't be opened — wrong key (keychain item lost or
            // rotated, e.g. a backup restore) or a corrupt file. Everything in
            // it resyncs from Gmail, so set it aside and start fresh instead
            // of crashing at launch.
            NSLog("MishMail: mail cache unreadable (%@); resetting", "\(error)")
            try Self.setAsideUnreadable(path: path)
            dbPool = try Self.openAndMigrate(path: path, passphrase: passphrase)
        }
    }

    static func storageDirectory(
        root: URL,
        isUITest: Bool,
        isDeveloperDemo: Bool = false
    ) -> URL {
        let name: String
        if isUITest {
            name = "MishMailUITests"
        } else if isDeveloperDemo {
            name = "MishMailDemo"
        } else {
            name = "MishMail"
        }
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Abort in-flight statements so cancelled tasks can finish promptly
    /// during termination (long full-table scans like contacts rebuild).
    /// No-ops after a successful `close()` (interrupt on a closed pool can
    /// crash). Still runs after a *failed* close so we can unblock live
    /// statements and retry.
    func interrupt() {
        closeLock.lock()
        let closed = isClosed
        closeLock.unlock()
        guard !closed else { return }
        dbPool.interrupt()
    }

    /// Close the pool once, after background readers have been cancelled and
    /// awaited. Must run before process exit so SQLCipher's atexit teardown
    /// (`sqlcipher_extra_shutdown`) does not race live reader connections.
    ///
    /// Only flips `isClosed` after a successful `close()`. GRDB can throw
    /// `SQLITE_BUSY` when live statements block close (zombie-ish state);
    /// swallowing that while marking closed would block interrupt/retry and
    /// hide the residual atexit race.
    func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        guard !isClosed else { return }
        do {
            try dbPool.close()
            isClosed = true
        } catch {
            NSLog("MishMail: dbPool.close failed: %@", "\(error)")
        }
    }

    private static func openAndMigrate(path: String, passphrase: String) throws -> DatabasePool {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.usePassphrase(passphrase)
        }
        let pool = try DatabasePool(path: path, configuration: config)
        try migrator.migrate(pool)
        return pool
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

    /// True for disposable, non-secret databases that must not touch a
    /// developer's Keychain. Pure and visible to the hostless test target.
    static func usesFixtureDatabaseKey(environment: [String: String]) -> Bool {
        environment["MISHMAIL_DEMO"] == "1"
            || environment["MISHMAIL_UI_TEST"] == "1"
    }

    /// Random 256-bit key, hex-encoded, generated once and kept in the Keychain.
    /// Demo/UI-test mail is fictional, so it deliberately uses a fixed key and
    /// avoids creating a Keychain item under an unstable ad-hoc signature.
    private static func databaseKey() throws -> String {
        if usesFixtureDatabaseKey(environment: ProcessInfo.processInfo.environment) {
            return String(repeating: "00", count: 32)
        }
        return try Keychain.existingOrCreate(from: Keychain.read("db.key")) {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(
                kSecRandomDefault, bytes.count, &bytes
            ) == errSecSuccess else {
                throw KeychainError.status(errSecParam)
            }
            let key = bytes.map { String(format: "%02x", $0) }.joined()
            try Keychain.set(key, forKey: "db.key")
            return key
        }
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
        // VIP group definitions: groups persist even when empty, and can be
        // toggled off to pause their members' VIP status without removing them.
        m.registerMigration("v14") { db in
            try db.create(table: "vipGroup") { t in
                t.primaryKey("name", .text)
                t.column("enabled", .boolean).notNull().defaults(to: true)
            }
        }
        // Rebuild message_fts with prefix indexes (2- and 3-char). The live
        // search dropdown queries prefixes on every keystroke (`FTS5Pattern
        // matchingAllPrefixesIn:`); without prefix indexes SQLite scans the
        // full term list for each short prefix — the exact hot path while
        // typing. Drop the old table + its sync triggers, recreate with
        // prefixes, and repopulate from `message`.
        m.registerMigration("v15") { db in
            try db.dropFTS5SynchronizationTriggers(forTable: "message_fts")
            try db.drop(table: "message_fts")
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.column("subject")
                t.column("fromHeader")
                t.column("bodyText")
                t.prefixes = [2, 3]
            }
        }
        // Denormalized label flags + newest-from email on thread for fast
        // mailbox filters / VIP matching without scanning messages or
        // parsing labelIds strings on every list query.
        m.registerMigration("v16") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "inSent", .boolean).notNull().defaults(to: false)
                t.add(column: "inDrafts", .boolean).notNull().defaults(to: false)
                t.add(column: "inPromotions", .boolean).notNull().defaults(to: false)
                t.add(column: "inSocial", .boolean).notNull().defaults(to: false)
                t.add(column: "fromEmail", .text).notNull().defaults(to: "")
            }
            // Token-aware label matches: labelIds is space-separated. Bound
            // each id with spaces (and allow start/end of string) so SENT
            // doesn't false-positive on a hypothetical *SENT* user label.
            try db.execute(sql: """
                UPDATE thread SET
                  inSent = (labelIds = 'SENT' OR labelIds LIKE 'SENT %'
                            OR labelIds LIKE '% SENT' OR labelIds LIKE '% SENT %'),
                  inDrafts = (labelIds = 'DRAFT' OR labelIds LIKE 'DRAFT %'
                              OR labelIds LIKE '% DRAFT' OR labelIds LIKE '% DRAFT %'),
                  inPromotions = (labelIds = 'CATEGORY_PROMOTIONS'
                                  OR labelIds LIKE 'CATEGORY_PROMOTIONS %'
                                  OR labelIds LIKE '% CATEGORY_PROMOTIONS'
                                  OR labelIds LIKE '% CATEGORY_PROMOTIONS %'),
                  inSocial = (labelIds = 'CATEGORY_SOCIAL'
                              OR labelIds LIKE 'CATEGORY_SOCIAL %'
                              OR labelIds LIKE '% CATEGORY_SOCIAL'
                              OR labelIds LIKE '% CATEGORY_SOCIAL %')
                """)
            // Newest message From → lowercased bare email (mirrors
            // MessageParser.emailAddress + lowercased). Angle-bracket form
            // first; else the whole header trimmed of brackets/spaces.
            try db.execute(sql: """
                UPDATE thread SET fromEmail = lower(coalesce((
                    SELECT CASE
                        WHEN instr(m.fromHeader, '<') > 0
                             AND instr(m.fromHeader, '>') > instr(m.fromHeader, '<')
                        THEN substr(m.fromHeader,
                                    instr(m.fromHeader, '<') + 1,
                                    instr(m.fromHeader, '>') - instr(m.fromHeader, '<') - 1)
                        ELSE trim(m.fromHeader, '<> ')
                    END
                    FROM message m
                    WHERE m.threadId = thread.id
                    ORDER BY m.date DESC
                    LIMIT 1
                ), ''))
                """)
        }
        // Trim message_fts: index subject + fromHeader only. Body text is
        // large and rarely hit from the live search dropdown; body search
        // falls back to server search (`searchAllGmail` / `searchServer`).
        m.registerMigration("v17") { db in
            try db.dropFTS5SynchronizationTriggers(forTable: "message_fts")
            try db.drop(table: "message_fts")
            try db.create(virtualTable: "message_fts", using: FTS5()) { t in
                t.synchronize(withTable: "message")
                t.column("subject")
                t.column("fromHeader")
                t.prefixes = [2, 3]
            }
        }
        // Composite indexes for hot *list* queries at scale (MailStore.baseQuery
        // + ORDER BY lastDate DESC LIMIT N). Each index covers a denorm flag
        // filter, inTrash, and lastDate so SQLite can satisfy the ORDER BY
        // without sorting all matching rows (important for Sent etc. at 50k+).
        //
        // Not for fetchSidebarCounts: that path is a single full-table
        // `SELECT SUM(CASE …) FROM thread` with no WHERE — SQLite cannot use
        // these indexes for it. Badge/count speed needs a separate change
        // (per-count WHERE queries or partial indexes on isUnread).
        // Single-column inInbox / lastDate / accountId indexes already exist
        // from v1; these multi-column ones cut list page scans under SQLCipher.
        m.registerMigration("v18") { db in
            // Inbox list: inInbox=1 AND inTrash=0 ORDER BY lastDate DESC
            // (baseQuery .inbox / .account).
            try db.create(
                index: "thread_on_inInbox_inTrash_lastDate",
                on: "thread",
                columns: ["inInbox", "inTrash", "lastDate"])
            // Drafts list: inDrafts=1 AND inTrash=0 ORDER BY lastDate DESC.
            try db.create(
                index: "thread_on_inDrafts_inTrash_lastDate",
                on: "thread",
                columns: ["inDrafts", "inTrash", "lastDate"])
            // Sent list: inSent=1 AND inTrash=0 ORDER BY lastDate DESC.
            try db.create(
                index: "thread_on_inSent_inTrash_lastDate",
                on: "thread",
                columns: ["inSent", "inTrash", "lastDate"])
            // Promotions list: inPromotions=1 AND inTrash=0 ORDER BY lastDate DESC.
            try db.create(
                index: "thread_on_inPromotions_inTrash_lastDate",
                on: "thread",
                columns: ["inPromotions", "inTrash", "lastDate"])
            // Social list: inSocial=1 AND inTrash=0 ORDER BY lastDate DESC.
            try db.create(
                index: "thread_on_inSocial_inTrash_lastDate",
                on: "thread",
                columns: ["inSocial", "inTrash", "lastDate"])
            // Starred list: isStarred=1 AND inTrash=0 ORDER BY lastDate DESC.
            try db.create(
                index: "thread_on_isStarred_inTrash_lastDate",
                on: "thread",
                columns: ["isStarred", "inTrash", "lastDate"])
            // Account-scoped lists (ORDER BY lastDate). accountId alone is
            // indexed from v1; pairing with lastDate covers the common ORDER BY.
            try db.create(
                index: "thread_on_accountId_lastDate",
                on: "thread",
                columns: ["accountId", "lastDate"])
        }
        // v19: denormalized SPAM flag so Promotions/Social can exclude spam
        // without scanning labelIds (Gmail keeps CATEGORY_* on spam threads).
        m.registerMigration("v19") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "inSpam", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: """
                UPDATE thread SET
                  inSpam = (labelIds = 'SPAM'
                            OR labelIds LIKE 'SPAM %'
                            OR labelIds LIKE '% SPAM'
                            OR labelIds LIKE '% SPAM %')
                """)
        }

        // v20: remember which From identity a scheduled send uses (primary or
        // send-as). Empty string means "same as accountId" for old rows.
        m.registerMigration("v20") { db in
            try db.alter(table: "scheduledSend") { t in
                t.add(column: "fromEmail", .text).notNull().defaults(to: "")
            }
        }
        // v21: partial indexes for SidebarCounts per-predicate COUNT(*) queries.
        // The v18 composites help list ORDER BY lastDate; they do not help
        // full-table SUM(CASE) badge SQL. These partials make each count scan
        // only matching rows (unread inbox, starred, drafts, …).
        m.registerMigration("v21") { db in
            // Primary inbox unread (+ dock badge same predicate).
            try db.execute(sql: """
                CREATE INDEX thread_unread_primary_inbox
                ON thread(accountId)
                WHERE isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
                  AND inPromotions = 0 AND inSocial = 0
                """)
            try db.execute(sql: """
                CREATE INDEX thread_unread_promotions
                ON thread(accountId)
                WHERE isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
                  AND inPromotions = 1
                """)
            try db.execute(sql: """
                CREATE INDEX thread_unread_social
                ON thread(accountId)
                WHERE isUnread = 1 AND inTrash = 0 AND inSpam = 0 AND inInbox = 1
                  AND inSocial = 1
                """)
            try db.execute(sql: """
                CREATE INDEX thread_starred_active
                ON thread(accountId)
                WHERE isStarred = 1 AND inTrash = 0
                """)
            try db.execute(sql: """
                CREATE INDEX thread_drafts_active
                ON thread(accountId)
                WHERE inDrafts = 1 AND inTrash = 0
                """)
        }
        // v22: partial indexes for the two SidebarCounts paths that were still
        // full-table scans after v21 (reminders + snoozed). The snooze cutoff
        // (`snoozeUntil > now`) cannot live in the index WHERE; scanning only
        // the snoozed subset is enough.
        m.registerMigration("v22") { db in
            try db.execute(sql: """
                CREATE INDEX thread_has_reminder
                ON thread(accountId)
                WHERE reminderAt IS NOT NULL
                """)
            try db.execute(sql: """
                CREATE INDEX thread_snoozed_active
                ON thread(accountId)
                WHERE snoozeUntil IS NOT NULL AND inTrash = 0
                """)
        }
        // v23: user-label junction + allFromEmails for blocklist any-message match.
        m.registerMigration("v23") { db in
            try db.create(table: "thread_label") { t in
                t.column("threadId", .text).notNull()
                    .references("thread", onDelete: .cascade)
                t.column("labelId", .text).notNull()
                t.primaryKey(["threadId", "labelId"])
            }
            try db.create(
                index: "thread_label_on_labelId",
                on: "thread_label",
                columns: ["labelId"])
            try db.alter(table: "thread") { t in
                t.add(column: "allFromEmails", .text).notNull().defaults(to: "")
            }
            // Backfill junction from space-separated labelIds (user labels only).
            let rows = try Row.fetchAll(db, sql: "SELECT id, labelIds FROM thread")
            for row in rows {
                let tid: String = row["id"]
                let labelIds: String = row["labelIds"]
                for lab in labelIds.split(separator: " ").map(String.init)
                    where lab.hasPrefix("Label_") {
                    try db.execute(
                        sql: "INSERT OR IGNORE INTO thread_label (threadId, labelId) VALUES (?, ?)",
                        arguments: [tid, lab])
                }
            }
            // Backfill allFromEmails from message From headers.
            try db.execute(sql: """
                UPDATE thread SET allFromEmails = coalesce((
                    SELECT group_concat(email, ' ')
                    FROM (
                        SELECT DISTINCT lower(trim(
                            CASE
                                WHEN instr(m.fromHeader, '<') > 0
                                     AND instr(m.fromHeader, '>') > instr(m.fromHeader, '<')
                                THEN substr(m.fromHeader,
                                            instr(m.fromHeader, '<') + 1,
                                            instr(m.fromHeader, '>') - instr(m.fromHeader, '<') - 1)
                                ELSE trim(m.fromHeader, '<> ')
                            END
                        )) AS email
                        FROM message m
                        WHERE m.threadId = thread.id
                          AND instr(m.fromHeader, '@') > 0
                    )
                    WHERE email != ''
                ), '')
                """)
        }
        // v24: off-row message bodies. Copy then clear on-row columns so header
        // fetches no longer pay SQLCipher costs for large HTML.
        m.registerMigration("v24") { db in
            try db.create(table: "message_body") { t in
                t.primaryKey("messageId", .text)
                    .references("message", onDelete: .cascade)
                t.column("bodyText", .text).notNull().defaults(to: "")
                t.column("bodyHTML", .text)
            }
            try db.execute(sql: """
                INSERT INTO message_body (messageId, bodyText, bodyHTML)
                SELECT id, bodyText, bodyHTML FROM message
                """)
            // Prefer WHERE so already-empty rows (if any) skip the write. FTS
            // sync triggers still reindex subject+from for each updated row on
            // first launch of this migration — expected pause on large caches.
            try db.execute(sql: """
                UPDATE message SET bodyText = '', bodyHTML = NULL
                WHERE bodyText != '' OR bodyHTML IS NOT NULL
                """)
        }
        // v25: lastInboundDate for inbox sort / "remind if no reply" without
        // overloading lastDate (which Sent, Drafts, search, and row timestamps
        // need as newest-message date).
        m.registerMigration("v25") { db in
            try db.alter(table: "thread") { t in
                t.add(column: "lastInboundDate", .datetime)
            }
            // Helps inbox ORDER BY COALESCE(lastInboundDate, lastDate) at scale
            // when lastInboundDate is populated (partial-null still falls back).
            try db.create(
                index: "thread_on_inInbox_inTrash_lastInboundDate",
                on: "thread",
                columns: ["inInbox", "inTrash", "lastInboundDate"])
            // Date columns only — a full deriveThread would recompute label
            // denorm from message rows and wipe category flags that only
            // lived on the thread's labelIds (v16 backfill / Gmail gaps).
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, accountId FROM thread
                """)
            for row in rows {
                let threadKey: String = row["id"]
                let accountId: String = row["accountId"]
                let messages = try Message
                    .filter(Column("threadId") == threadKey)
                    .order(Column("date").desc)
                    .fetchAll(db)
                guard let newest = messages.first else {
                    try db.execute(sql: """
                        UPDATE thread SET lastInboundDate = NULL WHERE id = ?
                        """, arguments: [threadKey])
                    continue
                }
                let inbound = SyncEngine.lastInboundDate(
                    messages: messages, accountId: accountId)
                try db.execute(sql: """
                    UPDATE thread SET lastDate = ?, lastInboundDate = ? WHERE id = ?
                    """, arguments: [newest.date, inbound, threadKey])
            }
        }
        // v26: per-snippet account scope (nil/empty JSON = all accounts).
        m.registerMigration("v26") { db in
            try db.alter(table: "snippet") { t in
                t.add(column: "accountIdsJSON", .text)
            }
        }
        // v27: tab-category denorm from newest INBOX-bearing message (not the
        // historical labelIds union). Existing caches would otherwise keep
        // personal-reply threads stuck under Promotions/Social forever.
        // Raw SQL only — do not decode the live `Message` record here; a
        // future non-optional message column would break upgrades from ≤v26.
        m.registerMigration("v27") { db in
            let threadIds = try String.fetchAll(db, sql: "SELECT id FROM thread")
            for threadKey in threadIds {
                let labelStrings = try String.fetchAll(db, sql: """
                    SELECT labelIds FROM message
                    WHERE threadId = ?
                    ORDER BY date DESC
                    """, arguments: [threadKey])
                let tabs = SyncEngine.tabCategoryFlags(labelIdStrings: labelStrings)
                try db.execute(sql: """
                    UPDATE thread SET inPromotions = ?, inSocial = ? WHERE id = ?
                    """, arguments: [tabs.promotions, tabs.social, threadKey])
            }
        }
        return m
    }
}

// MARK: - Shutdown ordering

/// Coordinates cancel → interrupt → await → close so GRDB/SQLCipher is not
/// torn down under active readers (EXC_BAD_ACCESS in sqlcipher_page_hmac).
enum DatabaseLifecycle {
    /// - Parameters:
    ///   - tasks: Unstructured database Tasks still holding the pool.
    ///   - interrupt: Abort long-running SQL (e.g. `DatabasePool.interrupt`).
    ///   - close: Release the pool after tasks have finished.
    static func shutDown(
        tasks: [Task<Void, Never>],
        interrupt: () -> Void,
        close: () -> Void
    ) async {
        for task in tasks { task.cancel() }
        interrupt()
        for task in tasks { await task.value }
        close()
    }

    /// Holds the in-flight termination task for `singleFlight`.
    /// MainActor-isolated so check/set of `task` is never concurrent.
    @MainActor
    final class FlightSlot {
        var task: Task<Void, Never>?
    }

    /// Single-flight wrapper matching `MailStore.prepareForTermination`:
    /// concurrent callers share one in-flight task and all await it, so a
    /// second quit cannot finish before the first close completes.
    ///
    /// `@MainActor` is load-bearing (SE-0338): a nonisolated async helper
    /// would hop to the concurrent executor, so two MainActor callers could
    /// both observe `slot.task == nil` and double-run `work`.
    @MainActor
    static func singleFlight(
        slot: FlightSlot,
        work: @escaping @MainActor () async -> Void
    ) async {
        if let existing = slot.task {
            await existing.value
            return
        }
        // No suspension between check and set — still on MainActor.
        let task = Task { @MainActor in
            await work()
        }
        slot.task = task
        await task.value
    }
}
