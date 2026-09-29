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

struct GMessage: Decodable, Sendable {
    struct Header: Decodable, Sendable { let name: String; let value: String }
    struct Body: Decodable, Sendable { let data: String?; let attachmentId: String?; let size: Int? }
    /// Recursive MIME tree — class (not struct) so Decodable can handle self-reference.
    /// All stored properties are immutable `let`s of Sendable types, so Sendable is safe.
    final class Part: Decodable, Sendable {
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
        /// The record's own history id — a valid `startHistoryId`, which is
        /// what lets the engine commit progress mid-catch-up.
        let id: String
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
    case keychainUnavailable(String, OSStatus)
    /// Some message gets failed after retries (429/5xx/network). Caller must
    /// **not** advance historyId past this sync — replaying history is safe.
    case partialFetch(failedCount: Int)

    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Gmail API error \(code): \(body.prefix(300))"
        case .historyExpired: return "Sync history expired; a full resync is needed."
        case .noRefreshToken(let email): return "No saved sign-in for \(email). Reauthorize the account in Settings → Accounts."
        case .keychainUnavailable(let email, let status):
            return "MishMail couldn't read the saved sign-in for \(email) (Keychain error \(status)). Unlock your Mac and try syncing again."
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
    /// Per-user quota exceeded. Gmail reports this as 403 with a
    /// `usageLimits` reason (or 429). Retry, but only after whole seconds.
    case rateLimited
    case fatal

    var isRetryable: Bool {
        switch self {
        case .retryable, .rateLimited: return true
        case .notFound, .fatal: return false
        }
    }

    static func classify(_ error: Error) -> MessageFetchFailureKind {
        let nsError = error as NSError
        if error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || (nsError.domain == NSURLErrorDomain
                && nsError.code == URLError.Code.cancelled.rawValue) {
            return .fatal
        }
        if let g = error as? GmailError {
            switch g {
            case .http(let code, let body):
                if code == 404 { return .notFound }
                if code == 429 { return .rateLimited }
                if code == 403, isRateLimitBody(body) { return .rateLimited }
                if (500...599).contains(code) { return .retryable }
                return .fatal
            case .historyExpired, .noRefreshToken, .keychainUnavailable, .partialFetch:
                return .fatal
            }
        }
        // URLSession / decoding errors retry next sync. Cancellation is fatal
        // above so a cancelled sync cannot turn into a background retry.
        return .retryable
    }

    /// A fatal get error that belongs to one message rather than the whole
    /// account, so the id can be skipped without pinning history. 401/403
    /// (auth, scope, disabled API), keychain and cancellation failures hit
    /// every id alike; skipping them would advance history past real mail.
    static func isPerMessagePermanent(_ error: Error) -> Bool {
        guard case GmailError.http(let code, _) = error else { return false }
        return (400..<500).contains(code) && ![401, 403, 404, 408, 429].contains(code)
    }

    /// Gmail's quota errors carry `"reason":"rateLimitExceeded"` or
    /// `"reason":"userRateLimitExceeded"` under `usageLimits`.
    static func isRateLimitBody(_ body: String) -> Bool {
        body.contains("rateLimitExceeded") || body.contains("RateLimitExceeded")
    }
}

/// Result of multi-get with permanent vs retryable misses separated.
struct MessageFetchReport: Sendable {
    init(messages: [GMessage] = [], notFoundIds: [String] = [],
         retryExhaustedIds: [String] = [], skippedIds: [String] = []) {
        self.messages = messages
        self.notFoundIds = notFoundIds
        self.retryExhaustedIds = retryExhaustedIds
        self.skippedIds = skippedIds
    }

    var messages: [GMessage]
    /// 404 — do not retry; treat as deleted for this cycle.
    var notFoundIds: [String]
    /// Still failing after retries — do not advance historyId.
    var retryExhaustedIds: [String]
    /// Permanent per-message failures (400/403 non-quota, etc.). These are
    /// omitted deliberately so one bad message cannot pin the whole history.
    var skippedIds: [String]

    var hasRetryExhausted: Bool { !retryExhaustedIds.isEmpty }
}

// MARK: - Client

/// Thin async client over the Gmail REST API for a single account.
/// Owns access-token refresh; the refresh token comes from the Keychain.
actor GmailClient {
    private let accountEmail: String
    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast
    private var tokenRefreshTask: Task<(String, Int), Error>?

    init(accountEmail: String) {
        self.accountEmail = accountEmail
    }

    /// One client per mailbox. SyncEngine and MailStore both use this entry
    /// point so quota state, access tokens, and penalty windows are shared.
    private static let registry = ClientRegistry()

    static func shared(accountEmail: String) -> GmailClient {
        registry.client(accountEmail: accountEmail)
    }

    private var base: String { "https://gmail.googleapis.com/gmail/v1/users/me" }

    private func validToken() async throws -> String {
        if let t = accessToken, tokenExpiry > Date().addingTimeInterval(60) { return t }
        let refresh: String
        switch Keychain.read("refreshToken.\(accountEmail)") {
        case .value(let value):
            refresh = value
        case .notFound:
            throw GmailError.noRefreshToken(accountEmail)
        case .unavailable(let status):
            throw GmailError.keychainUnavailable(accountEmail, status)
        }
        if let task = tokenRefreshTask {
            let (token, expiresIn) = try await task.value
            accessToken = token
            tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
            return token
        }
        let task: Task<(String, Int), Error> = Task {
            let result = try await OAuthService.refreshAccessToken(refreshToken: refresh)
            return (result.token, result.expiresIn)
        }
        tokenRefreshTask = task
        defer { tokenRefreshTask = nil }
        let (token, expiresIn) = try await task.value
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(TimeInterval(expiresIn))
        return token
    }

    private func request<T: Decodable>(_ method: String, _ path: String,
                                       query: [String: String] = [:],
                                       jsonBody: [String: Any]? = nil,
                                       retryRateLimit: Bool = true) async throws -> T {
        let data = try await requestData(method, path, query: query, jsonBody: jsonBody,
                                         retryRateLimit: retryRateLimit)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// For endpoints with empty responses (DELETE).
    private func requestVoid(_ method: String, _ path: String) async throws {
        _ = try await requestData(method, path)
    }

    private func requestData(_ method: String, _ path: String,
                             query: [String: String] = [:],
                             jsonBody: [String: Any]? = nil,
                             retryRateLimit: Bool = true) async throws -> Data {
        let cost = Self.quotaCost(method: method, path: path)
        var didRefreshAfter401 = false
        var rateAttempt = 0
        while true {
            try await pace(units: cost)
            var comps = URLComponents(string: base + path)!
            if !query.isEmpty {
                comps.queryItems = query.map { .init(name: $0.key, value: $0.value) }
            }
            var req = URLRequest(url: comps.url!)
            req.httpMethod = method
            req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            if let jsonBody {
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: jsonBody)
            }
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            guard !(code == 401 && !didRefreshAfter401) else {
                accessToken = nil
                tokenExpiry = .distantPast
                didRefreshAfter401 = true
                continue
            }
            guard (200..<300).contains(code) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                if method == "GET",
                   MessageFetchFailureKind.classify(GmailError.http(code, body)) == .rateLimited {
                    guard retryRateLimit else {
                        // The caller owns retries; still record the penalty.
                        let delay = GmailRetryBackoff.delay(
                            attempt: 0, kind: .rateLimited,
                            retryAfter: Self.retryAfter(body: body, response: http))
                        quota.block(until: Self.quotaNow().addingTimeInterval(delay))
                        var detail = body
                        if let header = http?.value(forHTTPHeaderField: "Retry-After") {
                            detail += "\nRetry-After: \(header)"
                        }
                        throw GmailError.http(code, detail)
                    }
                    let retryAfter = Self.retryAfter(body: body, response: http)
                    let delay = GmailRetryBackoff.delay(
                        attempt: rateAttempt, kind: .rateLimited,
                        retryAfter: retryAfter, jitter: GmailRetryBackoff.jitter())
                    quota.block(until: Self.quotaNow().addingTimeInterval(delay))
                    guard rateAttempt + 1 < Self.requestRetryAttempts else {
                        throw GmailError.http(code, body)
                    }
                    rateAttempt += 1
                    try await Self.sleep(delay)
                    continue
                }
                if code == 404, path.hasPrefix("/history") { throw GmailError.historyExpired }
                throw GmailError.http(code, body)
            }
            return data
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
        struct Info: Decodable { let name: String? }
        var didRefreshAfter401 = false
        while true {
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
            try await pace(units: 1)
            req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, !didRefreshAfter401 {
                accessToken = nil
                tokenExpiry = .distantPast
                didRefreshAfter401 = true
                continue
            }
            guard (200..<300).contains(code) else {
                throw GmailError.http(code, String(data: data, encoding: .utf8) ?? "")
            }
            return try JSONDecoder().decode(Info.self, from: data).name
        }
    }

    /// Largest page `messages.list` and `history.list` accept. A list call
    /// costs the same quota whatever its size, so id-only paging uses this.
    static let maxListPageSize = 500

    /// `includeSpamTrash` must be true to list TRASH or SPAM: without it
    /// Gmail can answer a `labelIds=TRASH` + `q` listing with nothing, and a
    /// reconcile then reads every cached trash/spam row as deleted.
    func listMessages(query: String? = nil, labelIds: [String] = [],
                      pageToken: String? = nil, maxResults: Int = 100,
                      includeSpamTrash: Bool = false) async throws -> GMessageList {
        let q = Self.listMessagesQuery(
            query: query, labelIds: labelIds, pageToken: pageToken,
            maxResults: maxResults, includeSpamTrash: includeSpamTrash)
        return try await request("GET", "/messages", query: q)
    }

    /// Query items for `messages.list`. Pure — unit-tested. A TRASH or SPAM
    /// label always turns `includeSpamTrash` on, so no caller can forget it.
    nonisolated static func listMessagesQuery(query: String?, labelIds: [String],
                                              pageToken: String?, maxResults: Int,
                                              includeSpamTrash: Bool) -> [String: String] {
        var q: [String: String] = ["maxResults": String(maxResults)]
        if let query { q["q"] = query }
        if !labelIds.isEmpty { q["labelIds"] = labelIds.joined(separator: ",") }
        if let pageToken { q["pageToken"] = pageToken }
        if includeSpamTrash || labelIds.contains(where: { $0 == "TRASH" || $0 == "SPAM" }) {
            q["includeSpamTrash"] = "true"
        }
        return q
    }

    func getMessage(id: String, format: String = "full") async throws -> GMessage {
        try await request("GET", "/messages/\(id)", query: ["format": format])
    }

    /// Single attempt for `fetchOneClassified`, which runs its own retry loop.
    /// Retrying here too would multiply attempts (3 x 3) under a quota penalty.
    private func getMessageOnce(id: String, format: String) async throws -> GMessage {
        try await request("GET", "/messages/\(id)", query: ["format": format],
                          retryRateLimit: false)
    }

    /// Kill-switch for HTTP batch get. Env `MISHMAIL_GMAIL_BATCH=0` or
    /// UserDefaults `gmail.batchGet` = false falls back to concurrent singles.
    nonisolated static var batchGetEnabled: Bool {
        if ProcessInfo.processInfo.environment["MISHMAIL_GMAIL_BATCH"] == "0" { return false }
        if UserDefaults.standard.object(forKey: "gmail.batchGet") as? Bool == false { return false }
        return true
    }

    /// Max messages per `batch/gmail/v1` request (Gmail allows up to 100).
    /// A batch is charged all at once — 5 units per message — against a
    /// 250 units/s moving average, so 25 keeps one batch within the burst cap.
    nonisolated static let batchGetChunkSize = 25

    /// Max attempts for a single get on retryable errors (429/5xx/network).
    nonisolated static let getRetryAttempts = 3
    nonisolated static let requestRetryAttempts = 3

    nonisolated static func quotaCost(method: String, path: String) -> Int {
        if path == "/profile" { return 1 }
        if path == "/labels" { return 1 }
        if path == "/history" { return 2 }
        if path == "/messages" { return 5 }
        if path == "/messages/send" { return 100 }
        if path.contains("/attachments/") { return 5 }
        if path.hasPrefix("/messages/") && path.hasSuffix("/modify") { return 10 }
        if path.hasPrefix("/messages/") { return 5 }
        if path.hasPrefix("/threads/") { return 10 }
        if path == "/drafts" || path.hasPrefix("/drafts/") {
            return method == "GET" ? 1 : 10
        }
        return 1
    }

    /// Fetch many messages. Batch when enabled; gaps filled with concurrent
    /// singles. Returns successes plus notFound vs retry-exhausted ids so
    /// history sync can refuse to advance past transient failures.
    func getMessages(ids: [String], format: String = "full") async throws -> MessageFetchReport {
        var report = try await getMessagesReport(ids: ids, format: format)
        // One bad id is skipped so history can move on. Every id failing the
        // same way is an account-wide problem (e.g. 400 failedPrecondition):
        // report them unfetched so the history id stays put.
        if ids.count >= 3, report.skippedIds.count == ids.count {
            report.retryExhaustedIds += report.skippedIds
            report.skippedIds = []
        }
        return report
    }

    private func getMessagesReport(ids: [String], format: String) async throws -> MessageFetchReport {
        guard !ids.isEmpty else {
            return MessageFetchReport()
        }
        if !Self.batchGetEnabled || ids.count == 1 {
            return try await getMessagesConcurrent(ids: ids, format: format)
        }
        var report = MessageFetchReport()
        report.messages.reserveCapacity(ids.count)
        var i = ids.startIndex
        while i < ids.endIndex {
            let end = ids.index(i, offsetBy: Self.batchGetChunkSize, limitedBy: ids.endIndex) ?? ids.endIndex
            let chunk = Array(ids[i..<end])
            let part: MessageFetchReport
            do {
                part = try await batchWithRateLimitRetry(ids: chunk, format: format)
            } catch {
                if Self.isCancellation(error) { throw error }
                if MessageFetchFailureKind.classify(error) == .rateLimited {
                    // Still limited after backing off: stop spending. Every
                    // remaining id is reported unfetched so the engine keeps
                    // its history id here and resumes next pass. Exploding
                    // the chunk into singles would only draw more 403s.
                    report.retryExhaustedIds += Array(ids[i...])
                    return report
                }
                // Whole batch transport failed — fall back to concurrent for chunk.
                let sub = try await getMessagesConcurrent(ids: chunk, format: format)
                report.messages += sub.messages
                report.notFoundIds += sub.notFoundIds
                report.retryExhaustedIds += sub.retryExhaustedIds
                report.skippedIds += sub.skippedIds
                i = end
                continue
            }
            report.messages += part.messages
            report.notFoundIds += part.notFoundIds
            report.retryExhaustedIds += part.retryExhaustedIds
            report.skippedIds += part.skippedIds
            let handled = Set(part.messages.map(\.id))
                .union(part.notFoundIds)
                .union(part.retryExhaustedIds)
                .union(part.skippedIds)
            let missing = chunk.filter { !handled.contains($0) }
            if part.hasRetryExhausted {
                // A per-part quota failure means the remaining chunks would
                // spend into the same penalty window. Leave them unfetched
                // and let the engine stop before advancing history.
                report.retryExhaustedIds += missing
                report.retryExhaustedIds += Array(ids[end...])
                return report
            }
            if !missing.isEmpty {
                let sub = try await getMessagesConcurrent(ids: missing, format: format)
                report.messages += sub.messages
                report.notFoundIds += sub.notFoundIds
                report.retryExhaustedIds += sub.retryExhaustedIds
                report.skippedIds += sub.skippedIds
            }
            i = end
        }
        return report
    }

    private enum ConcurrentItem: Sendable {
        case ok(GMessage)
        case notFound(String)
        case exhausted(String)
        case skipped(String)
    }

    /// Bounded concurrent singles with per-id retry. 404 → notFound (skip).
    /// Retryable failures retry up to `getRetryAttempts`; still failing →
    /// exhausted. Fatal errors (403, etc.) throw and abort the group.
    private func getMessagesConcurrent(ids: [String], format: String) async throws -> MessageFetchReport {
        try await withThrowingTaskGroup(of: ConcurrentItem.self) { group in
            var iterator = ids.makeIterator()
            var pending = 0
            var report = MessageFetchReport()
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
                case .skipped(let id): report.skippedIds.append(id)
                }
                addNext()
            }
            return report
        }
    }

    private func fetchOneClassified(id: String, format: String) async throws -> ConcurrentItem {
        for attempt in 0..<Self.getRetryAttempts {
            do {
                let msg = try await getMessageOnce(id: id, format: format)
                if attempt > 0 {
                    PerfMetrics.measure(.syncGetRetry, meta: "id=\(id) attempt=\(attempt + 1)") { () }
                }
                return .ok(msg)
            } catch {
                let kind = MessageFetchFailureKind.classify(error)
                switch kind {
                case .notFound:
                    return .notFound(id)
                case .fatal:
                    guard MessageFetchFailureKind.isPerMessagePermanent(error) else { throw error }
                    PerfMetrics.measure(
                        .syncGetRetry,
                        meta: "id=\(id) error=\(error.localizedDescription)") { () }
                    return .skipped(id)
                case .retryable, .rateLimited:
                    let delay = GmailRetryBackoff.delay(
                        attempt: attempt, kind: kind, retryAfter: Self.retryAfter(error),
                        jitter: GmailRetryBackoff.jitter())
                    if kind == .rateLimited {
                        quota.block(until: Self.quotaNow().addingTimeInterval(delay))
                    }
                    if attempt + 1 < Self.getRetryAttempts {
                        try await Self.sleep(delay)
                    }
                }
            }
        }
        PerfMetrics.measure(.syncGetRetry, meta: "exhausted id=\(id)") { () }
        return .exhausted(id)
    }

    // MARK: - Quota pacing

    /// Per-account token bucket (Gmail's limit is per user). Sleeping inside
    /// the actor is fine: `Task.sleep` suspends and other calls proceed.
    private var quota = GmailQuotaBucket()

    /// Clock for the quota bucket. System uptime only moves forward, so a
    /// wall-clock change (NTP step, manual set, sleep/wake skew) cannot
    /// stretch a penalty or refill window. Only differences are meaningful.
    private static func quotaNow() -> Date {
        Date(timeIntervalSinceReferenceDate: ProcessInfo.processInfo.systemUptime)
    }

    /// Reserve `units` and wait until the bucket allows the spend.
    ///
    /// While a penalty is active, park until it ends (plus a small per-caller
    /// jitter) and then reserve like any other caller. Reserving only after
    /// the wake keeps a penalty that grew while this caller slept from being
    /// ignored, and the bucket's refill spacing releases parked callers one
    /// by one instead of all together.
    private func pace(units: Int) async throws {
        while true {
            let penalty = quota.penaltyRemaining(now: Self.quotaNow())
            if penalty > 0 {
                try await Self.sleep(
                    min(penalty, GmailRateLimit.maxWait) + GmailRetryBackoff.jitter())
                continue
            }
            let delay = quota.delayBeforeSpending(units: units, now: Self.quotaNow())
            if delay > 0 { try await Self.sleep(delay) }
            return
        }
    }

    private static func sleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    /// A batch is charged 5 units per id, all at once, so pace before sending.
    /// A rate-limited batch is retried after a whole-second backoff rather
    /// than exploded into singles on a connection Gmail has just dropped —
    /// those singles only fail again and pin the history id for the pass.
    private func batchWithRateLimitRetry(ids: [String], format: String) async throws -> MessageFetchReport {
        var pending = ids
        var report = MessageFetchReport()
        for attempt in 0..<Self.getRetryAttempts {
            do {
                let results = try await getMessagesBatch(ids: pending, format: format)
                var rateLimited: [String] = []
                for result in results {
                    guard !result.id.isEmpty else { continue }
                    if let message = result.message, result.isSuccess {
                        report.messages.append(message)
                        continue
                    }
                    // 2xx with an undecodable body, or no status line at all:
                    // leave the id unhandled so the caller retries it singly.
                    if result.statusCode == 0 || (200..<300).contains(result.statusCode) {
                        continue
                    }
                    let error = GmailError.http(result.statusCode, result.body)
                    switch MessageFetchFailureKind.classify(error) {
                    case .notFound:
                        report.notFoundIds.append(result.id)
                    case .rateLimited, .retryable:
                        rateLimited.append(result.id)
                    case .fatal:
                        guard MessageFetchFailureKind.isPerMessagePermanent(error) else {
                            throw error
                        }
                        report.skippedIds.append(result.id)
                        PerfMetrics.measure(
                            .syncGetRetry,
                            meta: "id=\(result.id) status=\(result.statusCode)") { () }
                    }
                }
                guard !rateLimited.isEmpty else { return report }
                pending = rateLimited
                let body = results.first { rateLimited.contains($0.id) }?.body ?? ""
                let delay = GmailRetryBackoff.delay(
                    attempt: attempt, kind: .rateLimited,
                    retryAfter: GmailRateLimit.retryAfter(body: body),
                    jitter: GmailRetryBackoff.jitter())
                quota.block(until: Self.quotaNow().addingTimeInterval(delay))
                guard attempt + 1 < Self.getRetryAttempts else {
                    report.retryExhaustedIds += rateLimited
                    return report
                }
                try await Self.sleep(delay)
            } catch {
                let kind = MessageFetchFailureKind.classify(error)
                guard kind == .rateLimited else { throw error }
                PerfMetrics.measure(.syncGetRetry, meta: "batch rateLimited attempt=\(attempt + 1)") { () }
                let delay = GmailRetryBackoff.delay(
                    attempt: attempt, kind: kind, retryAfter: Self.retryAfter(error),
                    jitter: GmailRetryBackoff.jitter())
                quota.block(until: Self.quotaNow().addingTimeInterval(delay))
                guard attempt + 1 < Self.getRetryAttempts else { throw error }
                try await Self.sleep(delay)
            }
        }
        return report
    }

    private static func retryAfter(_ error: Error) -> TimeInterval? {
        guard case GmailError.http(_, let body) = error else { return nil }
        if let range = body.range(of: #"Retry-After:\s*([0-9.]+)"#, options: .regularExpression) {
            let match = String(body[range])
            if let seconds = match.split(separator: ":").last.flatMap({ TimeInterval($0.trimmingCharacters(in: .whitespaces)) }) {
                return min(max(0, seconds), GmailRateLimit.maxWait)
            }
        }
        return GmailRateLimit.retryAfter(body: body)
    }

    private static func retryAfter(body: String, response: HTTPURLResponse?) -> TimeInterval? {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter) {
            return min(max(0, seconds), GmailRateLimit.maxWait)
        }
        return GmailRateLimit.retryAfter(body: body)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        MessageFetchFailureKind.classify(error) == .fatal
            && (error is CancellationError
                || (error as? URLError)?.code == .cancelled
                || ((error as NSError).domain == NSURLErrorDomain
                    && (error as NSError).code == URLError.Code.cancelled.rawValue))
    }

    /// One multipart batch request. Pure parse of the response body is in
    /// `GmailBatch.parseResponse` for unit tests.
    private func getMessagesBatch(ids: [String], format: String) async throws -> [GmailBatch.PartResult] {
        let boundary = "batch_\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        let body = GmailBatch.buildRequestBody(ids: ids, format: format, boundary: boundary)
        var didRefreshAfter401 = false
        while true {
            try await pace(units: GmailQuotaBucket.units(forMessageGets: ids.count))
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/batch/gmail/v1")!)
            req.httpMethod = "POST"
            req.setValue("Bearer \(try await validToken())", forHTTPHeaderField: "Authorization")
            req.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401, !didRefreshAfter401 {
                accessToken = nil
                tokenExpiry = .distantPast
                didRefreshAfter401 = true
                continue
            }
            guard (200..<300).contains(code) else {
                var body = String(data: data, encoding: .utf8) ?? ""
                if let retryAfter = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") {
                    body += "\nRetry-After: \(retryAfter)"
                }
                throw GmailError.http(code, body)
            }
            let contentType = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            return try GmailBatch.parseResults(data: data, contentType: contentType, ids: ids)
        }
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

    /// `maxResults` defaults to Gmail's cap (500) rather than its implicit
    /// 100: the engine collects every page before slicing, so page size only
    /// sets how many round trips (2 quota units each) a catch-up takes.
    func history(since historyId: String, pageToken: String? = nil,
                 maxResults: Int = GmailClient.maxListPageSize) async throws -> GHistoryList {
        var q = ["startHistoryId": historyId, "maxResults": String(maxResults)]
        if let pageToken { q["pageToken"] = pageToken }
        return try await request("GET", "/history", query: q)
    }

    /// Sends an RFC 2822 message. Pass threadId to reply within a thread.
    /// Empty / whitespace thread ids are omitted (Gmail 404s on `""`).
    func send(raw: Data, threadId: String? = nil) async throws {
        var body: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId, !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body["threadId"] = threadId
        }
        let _: GMessage = try await request("POST", "/messages/send", jsonBody: body)
    }

    /// Saves an RFC 2822 message as a Gmail draft. Returns the draft id and
    /// the message ref so callers can chain replace-autosaves without a full
    /// listDrafts round-trip.
    /// Empty / whitespace thread ids are omitted (Gmail 404s on `""`).
    @discardableResult
    func createDraft(raw: Data, threadId: String? = nil) async throws -> GDraftRef {
        var message: [String: Any] = ["raw": raw.base64URLEncoded()]
        if let threadId, !threadId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message["threadId"] = threadId
        }
        return try await request("POST", "/drafts", jsonBody: ["message": message])
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

private final class ClientRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var clients: [String: GmailClient] = [:]

    func client(accountEmail: String) -> GmailClient {
        lock.lock()
        defer { lock.unlock() }
        if let client = clients[accountEmail] { return client }
        let client = GmailClient(accountEmail: accountEmail)
        clients[accountEmail] = client
        return client
    }
}
