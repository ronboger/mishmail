import Foundation

/// Content-Security-Policy for sandboxed HTML email rendering.
/// Kept free of AppKit so unit tests can pin the policy string.
enum HTMLBodyCSP {
    /// Meta tag injected into the message pane document head.
    ///
    /// - `base-uri 'none'` blocks phishing via a crafted `<base href>`.
    /// - `form-action` / `frame-src` / `object-src` are explicit even though
    ///   `default-src 'none'` covers them (defense in depth across WebKit revisions).
    /// - Remote images, when opted in, are HTTPS-only — no cleartext tracking pixels.
    static func metaTag(allowRemoteImages: Bool) -> String {
        let imgSrc = allowRemoteImages ? "data: cid: https:" : "data: cid:"
        let policy = [
            "default-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
            "frame-src 'none'",
            "object-src 'none'",
            "img-src \(imgSrc)",
            "style-src 'unsafe-inline'",
        ].joined(separator: "; ")
        return "<meta http-equiv=\"Content-Security-Policy\" content=\"\(policy)\">"
    }
}
