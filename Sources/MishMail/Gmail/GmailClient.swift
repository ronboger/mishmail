import Foundation

// MARK: - Wire models (subset of the Gmail REST API we use)

struct GProfile: Decodable {
    let emailAddress: String
    let historyId: String
}

struct GMessageList: Decodable {
    struct Ref: Decodable { let id: String; let threadId: String }
    let messages: [Ref]?
    let nextPageToken: String?
}

struct GMessage: Decodable {
    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String?; let attachmentId: String?; let size: Int? }
    final class Part: Decodable {
        let mimeType: String?
        let filename: String?
        let headers: [Header]?
        let body: Body?
        let parts: [Part]?
    }
    let id: String
    let threadId: String
    let labelIds: [String]?
    let snippet: String?
    let internalDate: String?
    let historyId: String?
    let payload: Part?
}

struct GLabel: Decodable {
    struct GColor: Decodable {
        let backgroundColor: String?
        let textColor: String?
    }
    let id: String
    let name: String
    let type: String?
    /// Gmail's label color, when the user picked one in Gmail. Used to seed
    /// the local label color on first sync.
    let color: GColor?
}

struct GLabelList: Decodable { let labels: [GLabel]? }

/// A Gmail filter (settings.filters). Read-only in this app.
struct GFilter: Decodable, Identifiable, Hashable {
    struct Criteria: Decodable, Hashable {
        let from: String?
        let to: String?
        let subject: String?
        let query: String?
        let negatedQuery: String?
        let hasAttachment: Bool?
        let size: Int?                 // bytes
        let sizeComparison: String?    // "larger" | "smaller"
    }
    struct Action: Decodable, Hashable {
        let addLabelIds: [String]?
        let removeLabelIds: [String]?
        let forward: String?
    }
    let id: String
    let criteria: Criteria?
    let action: Action?
}

/// A Gmail "Send mail as" identity (settings.sendAs). Primary + verified
/// aliases are the only addresses that mailbox may put in From: when sending.
struct GSendAs: Decodable, Hashable {
    let sendAsEmail: String
    let displayName: String?
    let isPrimary: Bool?
    let isDefault: Bool?
    /// "accepted" | "pending" | … — non-primary rows need accepted to send.
    let verificationStatus: String?
    let treatAsAlias: Bool?
}

struct GHistoryList: Decodable {
    struct Item: Decodable {
        struct MsgWrap: Decodable { let message: GMessageList.Ref }
        struct LabelChange: Decodable {
            let message: GMessageList.Ref
            let labelIds: [String]?
        }
        let messagesAdded: [MsgWrap]?
        let messagesDeleted: [MsgWrap]?
        let labelsAdded: [LabelChange]?
        let labelsRemoved: [LabelChange]?
    }
    let history: [Item]?
    let nextPageToken: String?
    let historyId: String?
}

enum GmailError: LocalizedError {
    case http(Int, String)
    case historyExpired
    case noRefreshToken(String)
    /// Some message gets failed after retries (429/5xx/network). Caller must
    /// **not** advance historyId past this sync — replaying history is safe.
    case partialFetch(failedCount: Int)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Gmail API error \(code): \(body.prefix(300))"
        case .historyExpired: return "Sync history expired; a full resync is needed."
        case .noRefreshToken(let email): return "No saved sign-in for \(email). Reauthorize the account in Settings → Accounts."
        case .partialFetch(let n):
            return "Sync incomplete (\(n) messages still pending); will retry next pass."
        }
    }

    /// 404 = gone forever. 429/5xx = retry. Other HTTP = fail the operation.
    static func failureKind(for error: Error) -> MessageFetchFailureKind {
        MessageFetchFailureKind.classify(error)
    }
}

/// Outcome of classifying a getMessage error (pure — unit-tested).
enum MessageFetchFailureKind: Equatable {
    case notFound
    case retryable
    case fatal

    static func classify(_ error: Error) -> MessageFetchFailureKind {
        if let g = error as? GmailError {
            switch g {
            case .http(let code, _):
                if code == 404 { return .notFound }
                if code == 429 || (500...599).contains(code) { return .retryable }
                return .fatal
            case .historyExpired, .noRefreshToken, .partialFetch:
                return .fatal
            }
        }
        // URLSession / decoding / cancellation-as-error → retry next sync.
        return .retryable
    }
}

/// Result of multi-get with permanent vs retryable misses separated.
struct MessageFetchReport: Sendable {
    var messages: [GMessage]
    /// 404 — do not retry; treat as deleted for this cycle.
    var notFoundIds: [String]
    /// Still failing after retries — do not advance historyId.
    var retryExhaustedIds: [String]

    var hasRetryExhausted: Bool { !retryExhaustedIds.isEmpty }
}

// MARK: - Client

/// Thin async client over the Gmail REST API for a single account.
/// Owns access-token refresh; the refresh token comes from the Keychain.
actor GmailClient {
    private let accountEmail: String
    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast

    init(accountEmail: String) {
        self.accountEmail = accountEmail
    }

    private var base: String { "https://gmail.googleapis.com/gmail/v1/users/me" }

    private func validToken() async throws -> String {
        if let t = accessToken, tokenExpiry > Date().addingTimeInterval(60) { return t }
        guard let refresh = Keychain.get("refreshToken.\(accountEmail)") else {
            throw GmailError.noRefreshToken(accountEmail)
        }
        let (token, expiresIn) = try await OAuthService.refreshAccessToken(refreshToken: refresh)
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        return token
    }

    private func request<T: Decodable>(_ method: String, _ path: String,
                                       query: [String: String] = [:],
                                       jsonBody: [String: Any]? = nil) async throws -> T {
        var comps = URLComponents(string: base + path)!
        if !query.isEmpty { comps.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        if let jsonBody {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            if code == 404, path.hasPrefix("/history") { throw GmailError.historyExpired }
            throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// For endpoints with empty responses (DELETE).
    private func requestVoid(_ method: String, _ path: String) async throws {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = method
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: API surface

    func profile() async throws -> GProfile {
        try await request("GET", "/profile")
    }

    func labels() async throws -> [GLabel] {
        let list: GLabelList = try await request("GET", "/labels")
        return list.labels ?? []
    }

    /// Creates a user label (409 if the name already exists).
    func createLabel(name: String) async throws -> GLabel {
        try await request("POST", "/labels", jsonBody: [
            "name": name,
            "labelListVisibility": "labelShow",
            "messageListVisibility": "show",
        ])
    }

    /// All filters the account has set up in Gmail. Requires the
    /// gmail.settings.basic scope (403 for tokens granted before it).
    func listFilters() async throws -> [GFilter] {
        struct List: Decodable { let filter: [GFilter]? }
        let list: List = try await request("GET", "/settings/filters")
        return list.filter ?? []
    }

    /// "Send mail as" identities for this mailbox (primary + aliases).
    /// Same settings.basic scope as filters; 403 for pre-scope tokens.
    func listSendAs() async throws -> [GSendAs] {
        struct List: Decodable { let sendAs: [GSendAs]? }
        let list: List = try await request("GET", "/settings/sendAs")
        return list.sendAs ?? []
    }

    struct GLabelDetail: Decodable {
        let id: String
        let threadsUnread: Int?
        let messagesUnread: Int?
    }

    /// Authoritative per-label unread counts, straight from Gmail.
    func labelInfo(_ id: String) async throws -> GLabelDetail {
        try await request("GET", "/labels/\(id)")
    }

    /// The account's display name from the Google profile.
    func userName() async throws -> String? {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        struct Info: Decodable { let name: String? }
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(Info.self, from: data).name
    }

    func listMessages(query: String? = nil, labelIds: [String] = [],
                      pageToken: String? = nil, maxResults: Int = 100) async throws -> GMessageList {
        var q: [String: String] = ["maxResults": String(maxResults)]
        if let query { q["q"] = query }
        if !labelIds.isEmpty { q["labelIds"] = labelIds.joined(separator: ",") }
        if let pageToken { q["pageToken"] = pageToken }
        return try await request("GET", "/messages", query: q)
    }

    func getMessage(id: String, format: String = "full") async throws -> GMessage {
        try await request("GET", "/messages/\(id)", query: ["format": format])
    }

    /// Kill-switch for HTTP batch get. Env `MISHMAIL_GMAIL_BATCH=0` or
    /// UserDefaults `gmail.batchGet` = false falls back to concurrent singles.
    nonisolated static var batchGetEnabled: Bool {
        if ProcessInfo.processInfo.environment["MISHMAIL_GMAIL_BATCH"] == "0" { return false }
        if UserDefaults.standard.object(forKey: "gmail.batchGet") as? Bool == false { return false }
        return true
    }

    /// Max messages per `batch/gmail/v1` request (Gmail allows up to 100).
    nonisolated static let batchGetChunkSize = 50

    /// Max attempts for a single get on retryable errors (429/5xx/network).
    nonisolated static let getRetryAttempts = 3

    /// Fetch many messages. Batch when enabled; gaps filled with concurrent
    /// singles. Returns successes plus notFound vs retry-exhausted ids so
    /// history sync can refuse to advance past transient failures.
    func getMessages(ids: [String], format: String = "full") async throws -> MessageFetchReport {
        guard !ids.isEmpty else {
            return MessageFetchReport(messages: [], notFoundIds: [], retryExhaustedIds: [])
        }
        if !Self.batchGetEnabled || ids.count == 1 {
            return try await getMessagesConcurrent(ids: ids, format: format)
        }
        var report = MessageFetchReport(messages: [], notFoundIds: [], retryExhaustedIds: [])
        report.messages.reserveCapacity(ids.count)
        var i = ids.startIndex
        while i < ids.endIndex {
            let end = ids.index(i, offsetBy: Self.batchGetChunkSize, limitedBy: ids.endIndex) ?? ids.endIndex
            let chunk = Array(ids[i..<end])
            let part: [GMessage]
            do {
                part = try await getMessagesBatch(ids: chunk, format: format)
            } catch {
                // Whole batch transport failed — fall back to concurrent for chunk.
                let sub = try await getMessagesConcurrent(ids: chunk, format: format)
                report.messages += sub.messages
                report.notFoundIds += sub.notFoundIds
                report.retryExhaustedIds += sub.retryExhaustedIds
                i = end
                continue
            }
            let got = Set(part.map(\.id))
            report.messages += part
            let missing = chunk.filter { !got.contains($0) }
            if !missing.isEmpty {
                let sub = try await getMessagesConcurrent(ids: missing, format: format)
                report.messages += sub.messages
                report.notFoundIds += sub.notFoundIds
                report.retryExhaustedIds += sub.retryExhaustedIds
            }
            i = end
        }
        return report
    }

    /// Convenience when caller only needs messages (backfill). Does **not**
    /// throw on partial retry exhaustion — drops exhausted ids.
    func getMessagesIgnoringRetryExhaustion(ids: [String], format: String = "full") async throws -> [GMessage] {
        try await getMessages(ids: ids, format: format).messages
    }

    private enum ConcurrentItem: Sendable {
        case ok(GMessage)
        case notFound(String)
        case exhausted(String)
    }

    /// Bounded concurrent singles with per-id retry. 404 → notFound (skip).
    /// Retryable failures retry up to `getRetryAttempts`; still failing →
    /// exhausted. Fatal errors (403, etc.) throw and abort the group.
    private func getMessagesConcurrent(ids: [String], format: String) async throws -> MessageFetchReport {
        try await withThrowingTaskGroup(of: ConcurrentItem.self) { group in
            var iterator = ids.makeIterator()
            var pending = 0
            var report = MessageFetchReport(messages: [], notFoundIds: [], retryExhaustedIds: [])
            report.messages.reserveCapacity(ids.count)
            func addNext() {
                if let id = iterator.next() {
                    group.addTask { try await self.fetchOneClassified(id: id, format: format) }
                    pending += 1
                }
            }
            for _ in 0..<min(8, ids.count) { addNext() }
            while pending > 0 {
                let item = try await group.next()!
                pending -= 1
                switch item {
                case .ok(let msg): report.messages.append(msg)
                case .notFound(let id): report.notFoundIds.append(id)
                case .exhausted(let id): report.retryExhaustedIds.append(id)
                }
                addNext()
            }
            return report
        }
    }

    private func fetchOneClassified(id: String, format: String) async throws -> ConcurrentItem {
        var lastRetryable: Error?
        for attempt in 0..<Self.getRetryAttempts {
            do {
                let msg = try await getMessage(id: id, format: format)
                if attempt > 0 {
                    PerfMetrics.measure(.syncGetRetry, meta: "id=\(id) attempt=\(attempt + 1)") { () }
                }
                return .ok(msg)
            } catch {
                switch MessageFetchFailureKind.classify(error) {
                case .notFound:
                    return .notFound(id)
                case .fatal:
                    throw error
                case .retryable:
                    lastRetryable = error
                    if attempt + 1 < Self.getRetryAttempts {
                        let ns: UInt64 = 200_000_000 * UInt64(1 << attempt) // 0.2s, 0.4s, …
                        try? await Task.sleep(nanoseconds: ns)
                    }
                }
            }
        }
        _ = lastRetryable
        PerfMetrics.measure(.syncGetRetry, meta: "exhausted id=\(id)") { () }
        return .exhausted(id)
    }

    /// One multipart batch request. Pure parse of the response body is in
    /// `GmailBatch.parseResponse` for unit tests.
    private func getMessagesBatch(ids: [String], format: String) async throws -> [GMessage] {
        let boundary = "batch_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = GmailBatch.buildRequestBody(ids: ids, format: format, boundary: boundary)
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/batch/gmail/v1")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "")
        }
        let contentType = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        return try GmailBatch.parseResponse(data: data, contentType: contentType)
    }

    func modifyMessage(id: String, add: [String] = [], remove: [String] = []) async throws {
        var body: [String: Any] = [:]
        if !add.isEmpty { body["addLabelIds"] = add }
        if !remove.isEmpty { body["removeLabelIds"] = remove }
        let _: GMessage = try await request("POST", "/messages/\(id)/modify", jsonBody: body)
    }

    func modifyThread(id: String, add: [String] = [], remove: [String] = []) async throws {
        struct ThreadResp: Decodable { let id: String }
        var body: [String: Any] = [:]
        if !add.isEmpty { body["addLabelIds"] = add }
        if !remove.isEmpty { body["removeLabelIds"] = remove }
        let _: ThreadResp = try await request("POST", "/threads/\(id)/modify", jsonBody: body)
    }

    func trashThread(id: String) async throws {
        struct ThreadResp: Decodable { let id: String }
        let _: ThreadResp = try await request("POST", "/threads/\(id)/trash")
    }

    func history(since historyId: String, pageToken: String? = nil) async throws -> GHistoryList {
        var q = ["startHistoryId": historyId]
        if let pageToken { q["pageToken"] = pageToken }
        return try await request("GET", "/history", query: q)
    }

    /// Sends an RFC 2822 message. Pass threadId to reply within a thread.
    func send(raw: Data, threadId: String? = nil) async throws {
        var body: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId { body["threadId"] = threadId }
        let _: GMessage = try await request("POST", "/messages/send", jsonBody: body)
    }

    /// Saves an RFC 2822 message as a Gmail draft.
    func createDraft(raw: Data, threadId: String? = nil) async throws {
        struct DraftResp: Decodable { let id: String }
        var message: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId { message["threadId"] = threadId }
        let _: DraftResp = try await request("POST", "/drafts", jsonBody: ["message": message])
    }

    struct GDraftRef: Decodable {
        let id: String
        let message: GMessageList.Ref
    }

    /// Lists all drafts (draft id ↔ message id mapping).
    func listDrafts() async throws -> [GDraftRef] {
        struct List: Decodable { let drafts: [GDraftRef]?; let nextPageToken: String? }
        var all: [GDraftRef] = []
        var pageToken: String?
        repeat {
            var q: [String: String] = ["maxResults": "100"]
            if let pageToken { q["pageToken"] = pageToken }
            let page: List = try await request("GET", "/drafts", query: q)
            all += page.drafts ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    func deleteDraft(id: String) async throws {
        try await requestVoid("DELETE", "/drafts/\(id)")
    }

    /// Downloads an attachment's bytes.
    func getAttachment(messageId: String, attachmentId: String) async throws -> Data {
        struct Body: Decodable { let data: String? }
        let body: Body = try await request("GET", "/messages/\(messageId)/attachments/\(attachmentId)")
        guard let b64 = body.data, let data = MessageParser.decodeBase64URLData(b64) else {
            throw GmailError.http(0, "attachment payload missing")
        }
        return data
    }
}
