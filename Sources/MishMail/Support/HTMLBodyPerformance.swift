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

/// Bounded LRU of settled HTML body heights. Re-open uses the cached height
/// immediately so the card frame does not jump after paint.
///
/// Height depends on layout inputs, not just content: the key includes
/// `fontScale` (like `HTMLBodyLoadKey.poolKey`) and each entry records the
/// container width it was measured at. A lookup that knows its width rejects
/// entries measured at a different width (split was resized); a lookup that
/// does not (pre-layout placeholder) accepts the entry best-effort and is
/// corrected by the real measurement.
struct HTMLBodyHeightCache {
    struct Entry: Equatable {
        var height: CGFloat
        var width: CGFloat
    }

    /// Widths within this many points reuse the cached height (autoresize /
    /// pixel-alignment rounding); anything larger reflows the layout.
    static let widthTolerance: CGFloat = 1

    let capacity: Int
    private(set) var entries: [String: Entry] = [:]
    private(set) var order: [String] = []

    init(capacity: Int = 64) {
        self.capacity = max(1, capacity)
    }

    static func key(contentID: String, fontScale: Double) -> String {
        "\(contentID)|f=\(String(format: "%.3f", fontScale))"
    }

    mutating func height(for key: String, width: CGFloat?) -> CGFloat? {
        guard let entry = entries[key] else { return nil }
        if let width, abs(entry.width - width) > Self.widthTolerance {
            return nil
        }
        touch(key)
        return entry.height
    }

    mutating func store(_ height: CGFloat, width: CGFloat, for key: String) {
        guard height > 0, width > 0 else { return }
        entries[key] = Entry(height: height, width: width)
        touch(key)
        while order.count > capacity, let evicted = order.first {
            order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    mutating func removeAll() {
        entries.removeAll(keepingCapacity: true)
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

    /// `width` nil means "layout width unknown yet" — the entry is applied as
    /// a pre-paint placeholder and later corrected by a real measurement.
    static func height(contentID: String, fontScale: Double,
                       width: CGFloat?) -> CGFloat? {
        let key = HTMLBodyHeightCache.key(contentID: contentID, fontScale: fontScale)
        lock.lock()
        defer { lock.unlock() }
        return cache.height(for: key, width: width)
    }

    static func store(_ height: CGFloat, contentID: String, fontScale: Double,
                      width: CGFloat) {
        let key = HTMLBodyHeightCache.key(contentID: contentID, fontScale: fontScale)
        lock.lock()
        defer { lock.unlock() }
        cache.store(height, width: width, for: key)
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

/// Neighbor pre-render privacy: never load remote content for a thread the
/// user has not opened. Pool keys include `allowRemoteImages`, so a blocked
/// pre-render cannot satisfy an allowed open (claim miss → cold load).
enum HTMLBodyPrerenderPolicy {
    /// Always false — pre-render is only a warm blocked CSP variant.
    static let allowRemoteImages = false
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
        /// Height the caller should publish/cache — the frozen value while an
        /// oscillation latch is engaged, otherwise the observed height.
        let height: CGFloat
    }

    var tolerance: CGFloat = 1
    /// One repeat means two consecutive observations agreed.
    var requiredStableSamples = 1
    /// A↔B reversals tolerated before freezing. A measure↔frame feedback loop
    /// (publish → SwiftUI resizes the webview → ResizeObserver re-reports)
    /// alternates between two heights that each differ from the previous
    /// sample, so the duplicate filter above never quiets it — one core pegged
    /// until quit. The JS freeze machine only catches monotone co-growth.
    var maxFlips = 3
    /// Consecutive agreeing samples at a genuinely new height (image load,
    /// pane resize) that release the freeze.
    var unlatchSamples = 5

    private(set) var lastHeight: CGFloat?
    /// Two samples ago — an oscillation returns here while differing from last.
    private var previousHeight: CGFloat?
    private(set) var stableSamples = 0
    private var flipCount = 0
    private(set) var latchedHeight: CGFloat?
    private var escapeHeight: CGFloat?
    private var escapeCount = 0

    mutating func reset() {
        lastHeight = nil
        previousHeight = nil
        stableSamples = 0
        flipCount = 0
        latchedHeight = nil
        escapeHeight = nil
        escapeCount = 0
    }

    mutating func observe(_ height: CGFloat) -> Observation {
        if let latched = latchedHeight {
            if abs(height - latched) <= tolerance {
                escapeHeight = nil
                escapeCount = 0
                return Observation(shouldPublish: false, isStable: true,
                                   height: latched)
            }
            if let escape = escapeHeight, abs(height - escape) <= tolerance {
                escapeCount += 1
                if escapeCount >= unlatchSamples {
                    reset()
                    lastHeight = height
                    return Observation(shouldPublish: true, isStable: false,
                                       height: height)
                }
            } else {
                escapeHeight = height
                escapeCount = 1
            }
            return Observation(shouldPublish: false, isStable: true,
                               height: latched)
        }

        guard let last = lastHeight else {
            lastHeight = height
            stableSamples = 0
            return Observation(shouldPublish: true, isStable: false,
                               height: height)
        }

        if abs(last - height) <= tolerance {
            stableSamples += 1
            flipCount = 0
            return Observation(
                shouldPublish: false,
                isStable: stableSamples >= requiredStableSamples,
                height: last)
        }

        if let previous = previousHeight, abs(previous - height) <= tolerance {
            flipCount += 1
        } else {
            flipCount = 0
        }
        previousHeight = last
        lastHeight = height
        stableSamples = 0

        if flipCount >= maxFlips {
            // Freeze on the taller value so no content is clipped; publish it
            // once (stable) and go quiet.
            let latched = max(height, previousHeight ?? height)
            latchedHeight = latched
            lastHeight = latched
            return Observation(shouldPublish: true, isStable: true,
                               height: latched)
        }
        return Observation(shouldPublish: true, isStable: false, height: height)
    }
}
