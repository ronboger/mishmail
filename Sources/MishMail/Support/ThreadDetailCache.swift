import Foundation
import GRDB

/// Precomputed reading-pane body work for one message.
///
/// Quote-trail scans and HTML document assembly are whole-body string work —
/// doing them on the main actor at first paint stalls keyboard browse. The
/// repository actor builds these once per contentVersion (and fontScale) so
/// `MessageCard` / `HTMLBodyView` only hand ready strings to WebKit.
///
/// Dark/light appearance is handled inside the injected CSS via
/// `prefers-color-scheme`, so one assembled document covers both appearances.
/// Font scale and remote-image CSP do change the string; documents are keyed
/// for both image policies at the scale used when the payload was built.
struct MessageHTMLPrep: Equatable {
    var textHead: String?
    var htmlHead: String?
    var hasQuotedTrail: Bool
    var htmlBytes: Int
    var htmlHeadBytes: Int
    /// Assembled documents for the fontScale recorded on `documents`.
    var documents: MessageHTMLDocuments?

    static let empty = MessageHTMLPrep(
        textHead: nil, htmlHead: nil, hasQuotedTrail: false,
        htmlBytes: 0, htmlHeadBytes: 0, documents: nil)
}

/// Pre-assembled HTML for (authored|full) × (blocked|allowed).
///
/// Blocked CSP variants are built eagerly (Ask-policy default). Allowed
/// variants are assembled on demand from retained sources so the detail LRU
/// does not retain four full copies of every body (~2 MB each). The first
/// allowed access memoizes the assembled document in a box shared by every
/// copy of this struct — `MessageCard.body` reads these on each evaluation,
/// and re-running whole-body assembly there would jank Always/VIP browsing.
struct MessageHTMLDocuments: Equatable {
    /// Once-per-prep memo for allowed-variant assembly, shared across value
    /// copies (payload cache, card, pre-render all see the same box).
    fileprivate final class AllowedMemo {
        private let lock = NSLock()
        private var cached: [Bool: String?] = [:]

        func document(authored: Bool, assemble: () -> String?) -> String? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = cached[authored] { return hit }
            let value = assemble()
            cached[authored] = value
            return value
        }
    }

    var fontScale: Double
    var authoredBlocked: String?
    var fullBlocked: String?
    /// Source fragments for on-demand allowed assembly (not expanded docs).
    fileprivate var authoredSource: String?
    fileprivate var fullSource: String?
    private let allowedMemo = AllowedMemo()

    static func == (lhs: MessageHTMLDocuments, rhs: MessageHTMLDocuments) -> Bool {
        lhs.fontScale == rhs.fontScale
            && lhs.authoredBlocked == rhs.authoredBlocked
            && lhs.fullBlocked == rhs.fullBlocked
            && lhs.authoredSource == rhs.authoredSource
            && lhs.fullSource == rhs.fullSource
    }

    /// Allowed variant for the authored head; built once on first request.
    var authoredAllowed: String? {
        allowedMemo.document(authored: true) {
            guard let source = authoredSource, !source.isEmpty else { return nil }
            return Self.assemble(source, allowRemoteImages: true, fontScale: fontScale)
        }
    }

    /// Allowed variant for the full body; built once on first request.
    var fullAllowed: String? {
        allowedMemo.document(authored: false) {
            guard let source = fullSource, !source.isEmpty else { return nil }
            return Self.assemble(source, allowRemoteImages: true, fontScale: fontScale)
        }
    }

    func document(authored: Bool, allowRemoteImages: Bool) -> String? {
        switch (authored, allowRemoteImages) {
        case (true, false): return authoredBlocked
        case (true, true): return authoredAllowed
        case (false, false): return fullBlocked
        case (false, true): return fullAllowed
        }
    }

    private static func assemble(_ source: String, allowRemoteImages: Bool,
                                 fontScale: Double) -> String? {
        guard source.utf8.count <= HTMLBodyRenderPolicy.maximumAutomaticBytes
        else { return nil }
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
        let csp = HTMLBodyCSP.metaTag(allowRemoteImages: allowRemoteImages)
        let doc = HTMLBodyDocument.assemble(html: source, cspMeta: csp, styleCSS: css)
        return doc.isEmpty ? nil : doc
    }
}

/// Pure builder for quote-trail + document assembly (hostless-testable).
enum MessageHTMLPrepBuilder {
    /// Scan the body for a collapsible quoted trail and assemble the HTML
    /// documents WebKit will load. Preserves `HTMLBodyRenderPolicy` 2 MB
    /// guards: oversized bodies only get a bounded quote scan, and auto-render
    /// documents are still subject to the same byte budget at paint time.
    static func prep(bodyText: String, bodyHTML: String?,
                     fontScale: Double) -> MessageHTMLPrep {
        let fullHTMLBytes = bodyHTML?.utf8.count ?? 0
        guard fullHTMLBytes > 0 || !bodyText.isEmpty else { return .empty }

        let detectedHTMLHead: String? = {
            guard let html = bodyHTML, !html.isEmpty else { return nil }
            if fullHTMLBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes {
                return QuotedReply.authoredHTMLHead(html)
            }
            return QuotedReply.authoredHTMLHead(
                html,
                scanCharacterLimit: HTMLBodyRenderPolicy.oversizedQuoteScanCharacterLimit)
        }()

        let textHead: String?
        let htmlHead: String?
        let hasQuotedTrail: Bool
        if let head = detectedHTMLHead {
            textHead = nil
            htmlHead = head
            hasQuotedTrail = true
        } else if fullHTMLBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes,
                  let head = QuotedReply.splitText(bodyText)?.head {
            textHead = head
            htmlHead = nil
            hasQuotedTrail = true
        } else {
            textHead = nil
            htmlHead = nil
            hasQuotedTrail = false
        }
        let htmlHeadBytes = htmlHead?.utf8.count ?? 0

        let documents: MessageHTMLDocuments?
        if let html = bodyHTML, !html.isEmpty {
            documents = assembleDocuments(
                fullHTML: html,
                htmlHead: htmlHead,
                fontScale: fontScale)
        } else {
            documents = nil
        }

        return MessageHTMLPrep(
            textHead: textHead,
            htmlHead: htmlHead,
            hasQuotedTrail: hasQuotedTrail,
            htmlBytes: fullHTMLBytes,
            htmlHeadBytes: htmlHeadBytes,
            documents: documents)
    }

    /// Rebuild only the assembled documents for a new font scale, keeping the
    /// already-scanned quote trail.
    static func reassembleDocuments(_ prep: MessageHTMLPrep,
                                    fullHTML: String?,
                                    fontScale: Double) -> MessageHTMLPrep {
        guard let html = fullHTML, !html.isEmpty else {
            var copy = prep
            copy.documents = nil
            return copy
        }
        var copy = prep
        copy.documents = assembleDocuments(
            fullHTML: html,
            htmlHead: prep.htmlHead,
            fontScale: fontScale)
        return copy
    }

    private static func assembleDocuments(fullHTML: String,
                                          htmlHead: String?,
                                          fontScale: Double) -> MessageHTMLDocuments {
        // Only blocked CSP variants are expanded eagerly. Allowed variants are
        // produced on demand from the retained sources (common path is Ask).
        let css = HTMLBodyDarkMode.injectedCSS(fontScale: fontScale)
        let cspBlocked = HTMLBodyCSP.metaTag(allowRemoteImages: false)

        func assembleBlocked(_ source: String) -> String? {
            // Cap automatic assembly the same way render does — multi-megabyte
            // bodies stay behind the explicit-load placeholder and never get
            // a prebuilt document that would thrash memory in the LRU.
            guard source.utf8.count <= HTMLBodyRenderPolicy.maximumAutomaticBytes
            else { return nil }
            let doc = HTMLBodyDocument.assemble(
                html: source, cspMeta: cspBlocked, styleCSS: css)
            return doc.isEmpty ? nil : doc
        }

        let authoredSource: String?
        let authoredBlocked: String?
        if let head = htmlHead, !head.isEmpty {
            authoredSource = head
            authoredBlocked = assembleBlocked(head)
        } else {
            authoredSource = nil
            authoredBlocked = nil
        }

        let fullBlocked = assembleBlocked(fullHTML)
        // Retain full source only when a blocked doc was produced (under budget).
        let fullSource: String? = fullBlocked == nil ? nil : fullHTML
        // Drop authored source when blocked assembly was skipped (over budget).
        let retainedAuthoredSource: String? = authoredBlocked == nil ? nil : authoredSource

        return MessageHTMLDocuments(
            fontScale: fontScale,
            authoredBlocked: authoredBlocked,
            fullBlocked: fullBlocked,
            authoredSource: retainedAuthoredSource,
            fullSource: fullSource)
    }
}

/// Everything the reading pane needs for its first useful frame.
///
/// Headers, the initially expanded body, draft bodies, and attachments load in
/// one database snapshot. Keeping this payload together avoids a main-thread
/// query per message/card and gives neighbor prefetch a reusable result.
struct ThreadDetailPayload: Equatable {
    var messages: [Message]
    var attachmentsByMessageId: [String: [AttachmentRow]]
    /// Precomputed quote trails + assembled HTML, keyed by message id.
    var bodyPrepByMessageId: [String: MessageHTMLPrep]

    func suppressingDrafts(_ suppressedIds: Set<String>) -> ThreadDetailPayload {
        guard !suppressedIds.isEmpty else { return self }
        let visible = messages.filter { !suppressedIds.contains($0.id) }
        let visibleIds = Set(visible.map(\.id))
        return ThreadDetailPayload(
            messages: visible,
            attachmentsByMessageId: attachmentsByMessageId.filter {
                visibleIds.contains($0.key)
            },
            bodyPrepByMessageId: bodyPrepByMessageId.filter {
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

struct MessageBodyLoad {
    let message: Message
    let prep: MessageHTMLPrep
}

struct ThreadDetailCacheEntry: Equatable {
    var contentVersion: Int
    var fontScale: Double
    var payload: ThreadDetailPayload
}

/// Off-main reading-pane repository with a bounded, real neighbor cache.
///
/// The previous prefetch path decoded rows and discarded them. This actor
/// retains ten payloads (current + nearby navigation / re-open) and serializes
/// cache ownership without putting SQLCipher reads on MainActor. Quote-trail
/// scans and HTML document assembly also run here so the main actor only
/// mounts ready strings into WebKit.
actor ThreadDetailRepository {
    private let db: DatabasePool
    private var cache = ThreadDetailLRU<ThreadDetailCacheEntry>(capacity: 10)

    init(db: DatabasePool) {
        self.db = db
    }

    func payload(threadId: String, suppressingDrafts suppressedIds: Set<String>,
                 contentVersion: Int,
                 fontScale: Double = 1.0,
                 forceReload: Bool = false) -> ThreadDetailLoad {
        if !forceReload,
           let cached = cache.value(for: threadId),
           cached.contentVersion == contentVersion {
            var payload = cached.payload
            if abs(cached.fontScale - fontScale) > 0.001 {
                payload = Self.reassemblePayloadDocuments(payload, fontScale: fontScale)
                cache.insert(
                    ThreadDetailCacheEntry(
                        contentVersion: contentVersion,
                        fontScale: fontScale,
                        payload: payload),
                    for: threadId)
            }
            return ThreadDetailLoad(
                payload: payload.suppressingDrafts(suppressedIds),
                cacheHit: true)
        }

        // Hold the SQLCipher reader only for row fetch. Quote scans and HTML
        // document assembly are pure string work and must not pin a connection.
        var loaded = (try? db.read { db in
            try Self.fetchPayload(threadId: threadId, db: db)
        }) ?? ThreadDetailPayload(
            messages: [], attachmentsByMessageId: [:], bodyPrepByMessageId: [:])
        loaded.bodyPrepByMessageId = Self.buildBodyPrep(
            messages: loaded.messages, fontScale: fontScale)
        cache.insert(
            ThreadDetailCacheEntry(
                contentVersion: contentVersion,
                fontScale: fontScale,
                payload: loaded),
            for: threadId)
        return ThreadDetailLoad(
            payload: loaded.suppressingDrafts(suppressedIds),
            cacheHit: false)
    }

    func messageBody(id: String, fontScale: Double = 1.0) -> MessageBodyLoad? {
        guard let loaded: Message = try? db.read({ db in
            guard var message = try Message.fetchOne(db, key: id) else { return nil }
            if let body = try MessageBody.fetchOne(db, key: id) {
                message.bodyText = body.bodyText
                message.bodyHTML = body.bodyHTML
            }
            return message
        }) else { return nil }

        let prep = MessageHTMLPrepBuilder.prep(
            bodyText: loaded.bodyText,
            bodyHTML: loaded.bodyHTML,
            fontScale: fontScale)

        if var entry = cache.value(for: loaded.threadId),
           let idx = entry.payload.messages.firstIndex(where: { $0.id == id }) {
            entry.payload.messages[idx] = loaded
            entry.payload.bodyPrepByMessageId[id] = prep
            // Leave entry.fontScale alone: only this one prep was built at
            // the requested scale. Stamping the entry would make a later
            // payload() cache hit skip reassembly for the sibling messages
            // whose documents still carry the old scale.
            cache.insert(entry, for: loaded.threadId)
        }
        return MessageBodyLoad(message: loaded, prep: prep)
    }

    /// Fetch messages, hydrated bodies, and attachments only. Callers must run
    /// `buildBodyPrep` after the read transaction returns.
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
            attachmentsByMessageId: Dictionary(grouping: attachments, by: \.messageId),
            bodyPrepByMessageId: [:])
    }

    /// Quote-trail scan + document assembly — pure string work, no DB.
    nonisolated static func buildBodyPrep(
        messages: [Message],
        fontScale: Double
    ) -> [String: MessageHTMLPrep] {
        var bodyPrep: [String: MessageHTMLPrep] = [:]
        bodyPrep.reserveCapacity(messages.count)
        for message in messages {
            // Skip empty header-only rows — prep is filled when the body loads.
            let hasBody = !(message.bodyText.isEmpty && (message.bodyHTML ?? "").isEmpty)
            guard hasBody else { continue }
            bodyPrep[message.id] = MessageHTMLPrepBuilder.prep(
                bodyText: message.bodyText,
                bodyHTML: message.bodyHTML,
                fontScale: fontScale)
        }
        return bodyPrep
    }

    private nonisolated static func reassemblePayloadDocuments(
        _ payload: ThreadDetailPayload,
        fontScale: Double
    ) -> ThreadDetailPayload {
        var copy = payload
        for message in payload.messages {
            guard var prep = copy.bodyPrepByMessageId[message.id] else { continue }
            prep = MessageHTMLPrepBuilder.reassembleDocuments(
                prep, fullHTML: message.bodyHTML, fontScale: fontScale)
            copy.bodyPrepByMessageId[message.id] = prep
        }
        return copy
    }

    private nonisolated static func hasDraftLabel(_ labelIds: String) -> Bool {
        labelIds.split(whereSeparator: \.isWhitespace).contains { $0 == "DRAFT" }
    }
}
