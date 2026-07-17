import Foundation
import GRDB

/// Everything the reading pane needs for its first useful frame.
///
/// Headers, the initially expanded body, draft bodies, and attachments load in
/// one database snapshot. Keeping this payload together avoids a main-thread
/// query per message/card and gives neighbor prefetch a reusable result.
struct ThreadDetailPayload: Equatable {
    var messages: [Message]
    var attachmentsByMessageId: [String: [AttachmentRow]]

    func suppressingDrafts(_ suppressedIds: Set<String>) -> ThreadDetailPayload {
        guard !suppressedIds.isEmpty else { return self }
        let visible = messages.filter { !suppressedIds.contains($0.id) }
        let visibleIds = Set(visible.map(\.id))
        return ThreadDetailPayload(
            messages: visible,
            attachmentsByMessageId: attachmentsByMessageId.filter {
                visibleIds.contains($0.key)
            })
    }
}

/// Small deterministic LRU used by the actor below. Split out so eviction
/// behavior is hostless-testable without constructing a DatabasePool.
struct ThreadDetailLRU<Value> {
    let capacity: Int
    private(set) var values: [String: Value] = [:]
    private(set) var order: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    mutating func value(for key: String) -> Value? {
        guard let value = values[key] else { return nil }
        touch(key)
        return value
    }

    mutating func insert(_ value: Value, for key: String) {
        values[key] = value
        touch(key)
        while order.count > capacity, let evicted = order.first {
            order.removeFirst()
            values.removeValue(forKey: evicted)
        }
    }

    mutating func removeValue(for key: String) {
        values.removeValue(forKey: key)
        order.removeAll { $0 == key }
    }

    mutating func removeAll() {
        values.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

struct ThreadDetailLoad {
    let payload: ThreadDetailPayload
    let cacheHit: Bool
}

/// Off-main reading-pane repository with a bounded, real neighbor cache.
///
/// The previous prefetch path decoded rows and discarded them. This actor
/// retains five payloads (current + nearby navigation) and serializes cache
/// ownership without putting SQLCipher reads on MainActor.
actor ThreadDetailRepository {
    private let db: DatabasePool
    private var cache = ThreadDetailLRU<ThreadDetailPayload>(capacity: 5)

    init(db: DatabasePool) {
        self.db = db
    }

    func payload(threadId: String, suppressingDrafts suppressedIds: Set<String>,
                 forceReload: Bool = false) -> ThreadDetailLoad {
        if !forceReload, let cached = cache.value(for: threadId) {
            return ThreadDetailLoad(
                payload: cached.suppressingDrafts(suppressedIds),
                cacheHit: true)
        }

        let loaded = (try? db.read { db in
            try Self.fetchPayload(threadId: threadId, db: db)
        }) ?? ThreadDetailPayload(messages: [], attachmentsByMessageId: [:])
        cache.insert(loaded, for: threadId)
        return ThreadDetailLoad(
            payload: loaded.suppressingDrafts(suppressedIds),
            cacheHit: false)
    }

    func messageBody(id: String) -> Message? {
        guard let loaded: Message = try? db.read({ db in
            guard var message = try Message.fetchOne(db, key: id) else { return nil }
            if let body = try MessageBody.fetchOne(db, key: id) {
                message.bodyText = body.bodyText
                message.bodyHTML = body.bodyHTML
            }
            return message
        }) else { return nil }
        if var payload = cache.value(for: loaded.threadId),
           let idx = payload.messages.firstIndex(where: { $0.id == id }) {
            payload.messages[idx] = loaded
            cache.insert(payload, for: loaded.threadId)
        }
        return loaded
    }

    func invalidate(threadId: String) {
        cache.removeValue(for: threadId)
    }

    func invalidateAll() {
        cache.removeAll()
    }

    nonisolated static func fetchPayload(threadId: String,
                                         db: Database) throws -> ThreadDetailPayload {
        var messages = try Message.fetchAll(
            db,
            sql: """
                SELECT id, accountId, gmailId, threadId, fromHeader, toHeader, ccHeader,
                       bccHeader, subject, date, snippet,
                       '' AS bodyText, NULL AS bodyHTML,
                       messageIdHeader, referencesHeader, labelIds, isUnread, hasAttachment
                FROM message
                WHERE threadId = ?
                ORDER BY date
                """,
            arguments: [threadId])

        // First frame expands the newest sent message. Draft cards also need
        // their previews immediately, so hydrate exactly those bodies.
        var hydrateIds = Set(
            messages.filter { Self.hasDraftLabel($0.labelIds) }.map(\.id))
        if let newestSent = messages.last(where: {
            !Self.hasDraftLabel($0.labelIds)
        }) {
            hydrateIds.insert(newestSent.id)
        }
        if !hydrateIds.isEmpty {
            let bodies = try MessageBody
                .filter(hydrateIds.contains(Column("messageId")))
                .fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: bodies.map { ($0.messageId, $0) })
            for idx in messages.indices {
                if let body = byId[messages[idx].id] {
                    messages[idx].bodyText = body.bodyText
                    messages[idx].bodyHTML = body.bodyHTML
                }
            }
        }

        let messageIds = messages.map(\.id)
        let attachments: [AttachmentRow]
        if messageIds.isEmpty {
            attachments = []
        } else {
            attachments = try AttachmentRow
                .filter(messageIds.contains(Column("messageId")))
                .order(Column("id"))
                .fetchAll(db)
        }
        return ThreadDetailPayload(
            messages: messages,
            attachmentsByMessageId: Dictionary(grouping: attachments, by: \.messageId))
    }

    private nonisolated static func hasDraftLabel(_ labelIds: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == "DRAFT" }
    }
}
