import Foundation

/// Dark-mode styling for HTML email in the reading pane.
///
/// Two shapes of mail need opposite treatment:
/// - **Plain** (no author background): text often hardcodes `color:#000` with a
///   transparent bg, so we force light text over our dark chrome.
/// - **Designed** (author brings a light panel): cream/white wrappers were
///   authored with dark text — force-lighting text produces light-on-cream.
///   Leave author colors alone and only set a dark default for unstyled text.
enum HTMLBodyDarkMode {
    /// True when the HTML declares a light-ish background on some container
    /// (`bgcolor`, `background-color`, or `background:`). Used to pick the
    /// "leave alone" path so newsletters keep their cream panels readable.
    static func hasOwnBackground(_ html: String) -> Bool {
        let range = fullRange(html)
        if bgcolorLightValue.numberOfMatches(in: html, options: [], range: range) > 0 {
            return true
        }
        if styleBackgroundLightValue.numberOfMatches(in: html, options: [], range: range) > 0 {
            return true
        }
        return false
    }

    /// Injected stylesheet contents (no outer `<style>` tags) for the message pane.
    static func injectedCSS(fontScale: Double, collapseQuote: Bool, html: String) -> String {
        let font = Int(14.5 * fontScale)
        let quote = collapseQuote ? QuotedReply.hideQuoteCSS : ""
        if hasOwnBackground(html) {
            // Designed / newsletter path: author owns the color world.
            // color-scheme: light keeps WebKit from auto-inverting their panel.
            // Non-!important dark default only fills in unstyled text.
            return """
            :root { color-scheme: light; }
            html, body { height: auto !important; min-height: 0 !important; }
            body { font: \(font)px -apple-system, sans-serif; color: #222; margin: 0; background: transparent; }
            img { max-width: 100%; height: auto; }
            \(quote)
            """
        }
        // Plain path: force light text over dark chrome (beats inline black).
        return """
        :root { color-scheme: light dark; }
        html, body { height: auto !important; min-height: 0 !important; }
        body { font: \(font)px -apple-system, sans-serif; color: canvastext; margin: 0; background: transparent; }
        img { max-width: 100%; height: auto; }
        @media (prefers-color-scheme: dark) {
          body, body :not(a):not(a *) { color: #e6e6e6 !important; }
          a, a * { color: #6cb2ff !important; }
          body [style*="background-color:white" i],
          body [style*="background-color: white" i],
          body [style*="background-color:#fff" i],
          body [style*="background-color: #fff" i],
          body [style*="background-color:#ffffff" i],
          body [style*="background-color: #ffffff" i],
          body [style*="background:white" i],
          body [style*="background: white" i],
          body [style*="background:#fff" i],
          body [style*="background: #fff" i],
          body [style*="background:#ffffff" i],
          body [style*="background: #ffffff" i],
          body [bgcolor="white" i],
          body [bgcolor="#fff" i],
          body [bgcolor="#ffffff" i] {
            background-color: transparent !important;
            background-image: none !important;
          }
        }
        \(quote)
        """
    }

    // MARK: - Detection

    // Light color token: hex with first channel nibble d–f (covers #fff, #eee,
    // #faf8f5, cream, etc.), common light names, or high-channel rgb().
    // Kept as one line so we never trip (?x) comment-on-# rules.
    private static let lightColor =
        #"(?:#[d-fD-F][0-9a-fA-F]{2}(?:[d-fD-F][0-9a-fA-F]{2}[d-fD-F][0-9a-fA-F]{2})?|#[d-fD-F]{3}|white|ivory|snow|beige|linen|seashell|oldlace|cornsilk|whitesmoke|ghostwhite|floralwhite|honeydew|mintcream|azure|aliceblue|lavenderblush|lightyellow|lightcyan|lemonchiffon|papayawhip|blanchedalmond|antiquewhite|mistyrose|rgb\(\s*(?:2[0-5]\d|1\d\d)\s*,\s*(?:2[0-5]\d|1\d\d)\s*,\s*(?:2[0-5]\d|1\d\d)\s*\))"#

    private static let bgcolorLightValue: NSRegularExpression = {
        // Case-insensitive; optional quotes around the value.
        try! NSRegularExpression(
            pattern: #"\bbgcolor\s*=\s*["']?\s*"# + lightColor,
            options: [.caseInsensitive])
    }()

    private static let styleBackgroundLightValue: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"\bbackground(?:-color)?\s*:\s*"# + lightColor,
            options: [.caseInsensitive])
    }()

    private static func fullRange(_ s: String) -> NSRange {
        NSRange(s.startIndex..., in: s)
    }
}
