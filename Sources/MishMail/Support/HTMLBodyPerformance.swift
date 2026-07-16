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
