import Foundation

/// Cheap identity and bounded-render helpers for HTML email.
///
/// Gmail message bodies are immutable once sent, so the message id is the
/// content revision for reading-pane cards. Mutable content must supply a new
/// `contentID` when it changes.
struct HTMLBodyLoadKey: Equatable {
    let contentID: String
    let allowRemoteImages: Bool
    let fontScale: Double

    /// Stable identity for pool claim / pre-render slots (not the raw HTML).
    var poolKey: String {
        let scale = String(format: "%.3f", fontScale)
        return "\(contentID)|r=\(allowRemoteImages ? 1 : 0)|f=\(scale)"
    }
}

/// Bounded LRU of settled HTML body heights keyed by render `contentID`
/// (`messageId` plus `:authored` / `:full`). Re-open uses the cached height
/// immediately so the card frame does not jump after paint.
struct HTMLBodyHeightCache {
    let capacity: Int
    private(set) var heights: [String: CGFloat] = [:]
    private(set) var order: [String] = []

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    mutating func height(for contentID: String) -> CGFloat? {
        guard let height = heights[contentID] else { return nil }
        touch(contentID)
        return height
    }

    mutating func store(_ height: CGFloat, for contentID: String) {
        guard height > 0 else { return }
        heights[contentID] = height
        touch(contentID)
        while order.count > capacity, let evicted = order.first {
            order.removeFirst()
            heights.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        heights.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Shared process-wide height cache used by `HTMLBodyView`.
enum HTMLBodyHeightCacheStore {
    private static let lock = NSLock()
    private static var cache = HTMLBodyHeightCache()

    static func height(for contentID: String) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return cache.height(for: contentID)
    }

    static func store(_ height: CGFloat, for contentID: String) {
        lock.lock()
        defer { lock.unlock() }
        cache.store(height, for: contentID)
    }
}

/// Pure bookkeeping for free + pre-rendered WebView slots. Extracted so
/// eviction is hostless-testable without constructing `WKWebView`s.
struct HTMLWebViewPoolLedger {
    let capacity: Int
    private(set) var freeCount = 0
    /// LRU order: index 0 is least recently parked.
    private(set) var prerenderOrder: [String] = []

    init(capacity: Int) {
        self.capacity = max(1, capacity)
    }

    var parkedCount: Int { freeCount + prerenderOrder.count }

    /// Room for another parked view without dropping anything.
    var hasRoom: Bool { parkedCount < capacity }

    mutating func parkFree() {
        freeCount += 1
        trimToCapacity(preferDroppingFree: false)
    }

    mutating func takeFree() -> Bool {
        guard freeCount > 0 else { return false }
        freeCount -= 1
        return true
    }

    /// Park a pre-rendered key. Returns any key that was dropped to make room.
    @discardableResult
    mutating func parkPrerender(key: String) -> String? {
        prerenderOrder.removeAll { $0 == key }
        prerenderOrder.append(key)
        return trimToCapacity(preferDroppingFree: true)
    }

    mutating func claimPrerender(key: String) -> Bool {
        guard let idx = prerenderOrder.firstIndex(of: key) else { return false }
        prerenderOrder.remove(at: idx)
        return true
    }

    /// Free a slot for a new live view: prefer an empty free slot, else steal
    /// the oldest pre-render. Returns what was taken.
    enum Acquire: Equatable {
        case free
        case stolenPrerender(String)
        case createNew
    }

    mutating func acquireForDequeue() -> Acquire {
        if takeFree() { return .free }
        if let oldest = prerenderOrder.first {
            prerenderOrder.removeFirst()
            return .stolenPrerender(oldest)
        }
        return .createNew
    }

    mutating func discardAllPrerenders() {
        prerenderOrder.removeAll(keepingCapacity: true)
    }

    mutating func drain() {
        freeCount = 0
        prerenderOrder.removeAll(keepingCapacity: true)
    }

    /// Drop parked views until `parkedCount <= capacity`. When
    /// `preferDroppingFree`, empty free slots go first so pre-renders keep
    /// their painted DOM; otherwise oldest pre-renders go first.
    @discardableResult
    private mutating func trimToCapacity(preferDroppingFree: Bool) -> String? {
        var droppedKey: String?
        while parkedCount > capacity {
            if preferDroppingFree, freeCount > 0 {
                freeCount -= 1
            } else if let oldest = prerenderOrder.first {
                prerenderOrder.removeFirst()
                droppedKey = oldest
            } else if freeCount > 0 {
                freeCount -= 1
            } else {
                break
            }
        }
        return droppedKey
    }
}

/// Pure decision: which HTML fragment (if any) to pre-render for a neighbor.
enum HTMLBodyPrerenderSelection {
    struct Candidate: Equatable {
        let contentID: String
        let html: String
        let byteCount: Int
    }

    /// Prefer the authored head when present and under the automatic byte
    /// budget; otherwise the full body. Oversized markup is skipped entirely.
    static func candidate(messageId: String, bodyHTML: String?) -> Candidate? {
        guard let html = bodyHTML, !html.isEmpty else { return nil }
        let fullBytes = html.utf8.count

        if fullBytes <= HTMLBodyRenderPolicy.maximumAutomaticBytes,
           let head = QuotedReply.authoredHTMLHead(html) {
            let headBytes = head.utf8.count
            if !HTMLBodyRenderPolicy.requiresExplicitLoad(
                byteCount: headBytes, userApproved: false) {
                return Candidate(
                    contentID: messageId + ":authored",
                    html: head,
                    byteCount: headBytes)
            }
        }

        if HTMLBodyRenderPolicy.requiresExplicitLoad(
            byteCount: fullBytes, userApproved: false) {
            return nil
        }
        return Candidate(
            contentID: messageId + ":full",
            html: html,
            byteCount: fullBytes)
    }
}

enum HTMLBodyRenderPolicy {
    /// Large transactional mail and recursively quoted threads can contain
    /// megabytes of markup. Do not feed that to WebKit without an explicit
    /// click; a smaller authored head is still safe to render automatically.
    static let maximumAutomaticBytes = 2 * 1_024 * 1_024
    /// Oversized bodies still get a bounded quote-marker scan so a small
    /// authored reply can render without loading megabytes of repeated history.
    static let oversizedQuoteScanCharacterLimit = 256_000
    static let previewCharacterLimit = 4_000

    static func requiresExplicitLoad(byteCount: Int, userApproved: Bool) -> Bool {
        !userApproved && byteCount > maximumAutomaticBytes
    }

    /// Clicking "show quoted text" is an explicit request for the full body,
    /// so it also approves an oversized quoted trail.
    static func quoteExpansionApprovesFullBody(byteCount: Int) -> Bool {
        byteCount > maximumAutomaticBytes
    }
}

/// Separates "a navigation has not started yet" from WebKit starting one
/// without returning its optional WKNavigation identity.
struct HTMLNavigationIdentityGate {
    private enum State {
        case awaitingStart
        case identified(ObjectIdentifier)
        case identityUnavailable
    }

    private var state: State = .awaitingStart

    mutating func reset() {
        state = .awaitingStart
    }

    mutating func didStart(_ navigation: AnyObject?) {
        if let navigation {
            state = .identified(ObjectIdentifier(navigation))
        } else {
            state = .identityUnavailable
        }
    }

    func accepts(_ navigation: AnyObject?) -> Bool {
        switch state {
        case .awaitingStart:
            return false
        case .identified(let expected):
            guard let navigation else { return false }
            return ObjectIdentifier(navigation) == expected
        case .identityUnavailable:
            return true
        }
    }
}

/// Suppresses no-op WebView height publications and declares an initial render
/// stable after the same size has been observed repeatedly. ResizeObserver can
/// remain installed for real later changes (for example, an image load).
struct HTMLHeightStability {
    struct Observation: Equatable {
        let shouldPublish: Bool
        let isStable: Bool
    }

    var tolerance: CGFloat = 1
    /// One repeat means two consecutive observations agreed.
    var requiredStableSamples = 1

    private(set) var lastHeight: CGFloat?
    private(set) var stableSamples = 0

    mutating func reset() {
        lastHeight = nil
        stableSamples = 0
    }

    mutating func observe(_ height: CGFloat) -> Observation {
        guard let lastHeight else {
            self.lastHeight = height
            stableSamples = 0
            return Observation(shouldPublish: true, isStable: false)
        }

        if abs(lastHeight - height) <= tolerance {
            stableSamples += 1
            return Observation(
                shouldPublish: false,
                isStable: stableSamples >= requiredStableSamples)
        }

        self.lastHeight = height
        stableSamples = 0
        return Observation(shouldPublish: true, isStable: false)
    }
}
