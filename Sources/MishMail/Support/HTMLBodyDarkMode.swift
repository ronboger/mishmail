import Foundation

/// Dark-mode styling for HTML email in the reading pane.
///
/// One stylesheet for all mail (not a plain-vs-designed branch):
/// 1. Force light text over our dark chrome — beats Outlook/Word inline black.
/// 2. Force dark text only where the *effective* background is light (white
///    sig cards, cream panels, full-bleed white transactional mail).
/// 3. Force light text again where a nested section paints a dark fill
///    (Google welcome mail: white wrapper + black body sections + blue CTAs).
///
/// Light-vs-dark is resolved by app-injected JS: walk the DOM, track the
/// nearest opaque `background-color` ancestor, and stamp a per-element
/// foreground class. CSS must **not** use descendant combinators from light
/// wrappers — that forced `#222` onto dark nested sections (dark-on-dark).
///
/// Attribute selectors remain a first-paint fast path for the element that
/// owns a light bgcolor/style only (inheritance covers transparent kids
/// until JS retags every node).
enum HTMLBodyDarkMode {
    /// Dark text (`#222`) — effective background is light.
    static let fgOnLightClass = "mm-fg-on-light"
    /// Light text (`#e6e6e6`) — effective background is dark, or transparent
    /// over the reading-pane chrome.
    static let fgOnDarkClass = "mm-fg-on-dark"

    /// Relative luminance above this (sRGB 0–1) counts as a light surface.
    /// ~0.72 is mid-cream; pure white is 1.0, `#faf8f5` is ~0.97.
    static let luminanceThreshold = 0.72

    /// Alpha below this is treated as transparent (plain mail over dark chrome
    /// must not be treated as a light fill).
    static let alphaFloor = 0.5

    /// Injected stylesheet contents (no outer `<style>` tags) for the message pane.
    static func injectedCSS(fontScale: Double, collapseQuote: Bool, html: String = "") -> String {
        // `html` kept for API stability / future per-message tweaks; unused now.
        _ = html
        let font = Int(14.5 * fontScale)
        let quote = collapseQuote ? QuotedReply.hideQuoteCSS : ""
        // Attribute light surfaces: style the element only (no descendant
        // combinator). Nested dark sections must not inherit force-dark text
        // from a white outer table — JS stamps per-node fg classes for that.
        let light = lightSurfaceSelector
        let onLight = fgOnLightClass
        let onDark = fgOnDarkClass
        return """
        :root { color-scheme: light dark; }
        html, body { height: auto !important; min-height: 0 !important; }
        body { font: \(font)px -apple-system, sans-serif; color: canvastext; margin: 0; background: transparent; }
        img { max-width: 100%; height: auto; }
        @media (prefers-color-scheme: dark) {
          body, body :not(a):not(a *) { color: #e6e6e6 !important; }
          a, a * { color: #6cb2ff !important; }
          /* First-paint fast path: light bgcolor/style on the node itself only
             (no descendant force — nested dark sections must not go dark-on-dark). */
          :is(\(light)) { color: #222 !important; }
          /* JS effective-bg classes: every node stamped from nearest opaque fill. */
          .\(onLight) { color: #222 !important; }
          .\(onDark) { color: #e6e6e6 !important; }
          /* Links last so nested spans inside CTAs keep link blue, not body fg. */
          a.\(onLight), a.\(onLight) * { color: #0b57d0 !important; }
          a.\(onDark), a.\(onDark) * { color: #6cb2ff !important; }
        }
        \(quote)
        """
    }

    /// Whether a solid fill with the given sRGB channels should use dark text.
    ///
    /// Shared by unit tests and the JS tagger (constants are interpolated into
    /// `applyContrastJS` so thresholds cannot drift). Channels are 0–255;
    /// alpha is 0–1.
    ///
    /// Note: only solid `background-color` is considered. A light PNG/gradient
    /// `background-image` over a transparent `background-color` is a known
    /// false negative (still light-on-image); attribute selectors also miss it.
    static func isLightBackground(r: Double, g: Double, b: Double, a: Double = 1) -> Bool {
        guard a >= alphaFloor else { return false }
        let luminance = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
        return luminance > luminanceThreshold
    }

    static func isLightBackground(r: Int, g: Int, b: Int, a: Double = 1) -> Bool {
        isLightBackground(r: Double(r), g: Double(g), b: Double(b), a: a)
    }

    /// App-injected JS (page scripts stay disabled). For every element, finds
    /// the nearest opaque computed `background-color` (self or ancestor) and
    /// stamps `fgOnLightClass` or `fgOnDarkClass` so text contrasts with that
    /// fill — not with a distant white wrapper.
    ///
    /// Installed as a `WKUserScript` at `.atDocumentEnd` (before first paint)
    /// and re-run from `didFinish`. Safe to re-run; replaces prior fg classes.
    static var applyContrastJS: String {
        let onLight = fgOnLightClass
        let onDark = fgOnDarkClass
        let lum = luminanceThreshold
        let alpha = alphaFloor
        return """
        (function(){
          var ON_LIGHT='\(onLight)';
          var ON_DARK='\(onDark)';
          var LUM=\(lum);
          var AMIN=\(alpha);
          function parseBg(bg){
            if(!bg||bg==='transparent') return null;
            var m=bg.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\)/i);
            if(!m) return null;
            var a=m[4]===undefined?1:parseFloat(m[4]);
            if(a<AMIN) return null;
            return {r:+m[1],g:+m[2],b:+m[3],a:a};
          }
          function isLight(c){
            if(!c) return false;
            return (0.2126*c.r+0.7152*c.g+0.0722*c.b)/255>LUM;
          }
          function walk(el, inherited){
            var own=null;
            try{ own=parseBg(getComputedStyle(el).backgroundColor); }catch(e){}
            var effective=own||inherited;
            try{
              el.classList.remove(ON_LIGHT, ON_DARK);
              if(isLight(effective)) el.classList.add(ON_LIGHT);
              else el.classList.add(ON_DARK);
            }catch(e){}
            var next=own||inherited;
            var kids=el.children;
            for(var i=0;i<kids.length;i++) walk(kids[i], next);
          }
          if(document.documentElement) walk(document.documentElement, null);
        })();
        """
    }

    /// Back-compat alias used by older call sites / tests.
    static var tagLightSurfacesJS: String { applyContrastJS }

    /// True when the authored head declares a light background. Kept for tests
    /// and diagnostics; styling no longer branches on this.
    static func hasOwnBackground(_ html: String) -> Bool {
        let sample = authoredHead(of: html)
        let range = fullRange(sample)
        if bgcolorLightValue.numberOfMatches(in: sample, options: [], range: range) > 0 {
            return true
        }
        if styleBackgroundLightValue.numberOfMatches(in: sample, options: [], range: range) > 0 {
            return true
        }
        return false
    }

    /// HTML above the first reply/forward quote container, or the full string
    /// when there is no recognized trail.
    static func authoredHead(of html: String) -> String {
        let ns = html as NSString
        guard let match = quoteMarker.firstMatch(
            in: html, range: NSRange(location: 0, length: ns.length))
        else { return html }
        let head = ns.substring(to: match.range.location)
        let stripped = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? html : head
    }

    // MARK: - Light surface CSS selectors

    /// Comma-separated selector list matching elements with light backgrounds
    /// via bgcolor / style attributes. Intentionally broad on first hex nibble
    /// (d–f) so cream `#faf8f5` and white both hit.
    private static var lightSurfaceSelector: String {
        let bgcolorExact = [
            "[bgcolor=\"#ffffff\" i]",
            "[bgcolor=\"#fff\" i]",
            "[bgcolor=\"white\" i]",
            "[bgcolor=\"ivory\" i]",
            "[bgcolor=\"snow\" i]",
            "[bgcolor=\"beige\" i]",
            "[bgcolor=\"linen\" i]",
            "[bgcolor=\"seashell\" i]",
            "[bgcolor=\"oldlace\" i]",
            "[bgcolor=\"cornsilk\" i]",
            "[bgcolor=\"whitesmoke\" i]",
            "[bgcolor=\"ghostwhite\" i]",
            "[bgcolor=\"floralwhite\" i]",
            "[bgcolor=\"honeydew\" i]",
            "[bgcolor=\"mintcream\" i]",
            "[bgcolor=\"azure\" i]",
            "[bgcolor=\"aliceblue\" i]",
            "[bgcolor=\"lavenderblush\" i]",
            "[bgcolor=\"lightyellow\" i]",
            "[bgcolor=\"lightcyan\" i]",
            "[bgcolor=\"lemonchiffon\" i]",
            "[bgcolor=\"papayawhip\" i]",
            "[bgcolor=\"blanchedalmond\" i]",
            "[bgcolor=\"antiquewhite\" i]",
            "[bgcolor=\"mistyrose\" i]",
            // First nibble d–f covers cream/off-white hexes (#faf8f5, #eee, …).
            "[bgcolor^=\"#d\" i]",
            "[bgcolor^=\"#e\" i]",
            "[bgcolor^=\"#f\" i]",
            "[bgcolor^=\"#D\" i]",
            "[bgcolor^=\"#E\" i]",
            "[bgcolor^=\"#F\" i]",
        ]
        // style="… background-color: …" / background: … — substring match.
        let styleSnippets = [
            "background-color:#fff", "background-color: #fff",
            "background-color:#ffffff", "background-color: #ffffff",
            "background-color:white", "background-color: white",
            "background:#fff", "background: #fff",
            "background:#ffffff", "background: #ffffff",
            "background:white", "background: white",
            "background-color:#d", "background-color: #d",
            "background-color:#e", "background-color: #e",
            "background-color:#f", "background-color: #f",
            "background:#d", "background: #d",
            "background:#e", "background: #e",
            "background:#f", "background: #f",
            "background-color:rgb(25", "background-color: rgb(25",
            "background-color:rgb(24", "background-color: rgb(24",
            "background-color:rgb(23", "background-color: rgb(23",
            "background-color:rgb(22", "background-color: rgb(22",
            "background-color:rgb(21", "background-color: rgb(21",
            "background-color:rgb(20", "background-color: rgb(20",
            "background-color:rgb(19", "background-color: rgb(19",
            "background:rgb(25", "background: rgb(25",
            "background:rgb(24", "background: rgb(24",
            "background:rgb(23", "background: rgb(23",
            "background:rgb(22", "background: rgb(22",
            "background:rgb(21", "background: rgb(21",
            "background:rgb(20", "background: rgb(20",
            "background:rgb(19", "background: rgb(19",
        ]
        let styleSelectors = styleSnippets.map { "[style*=\"\($0)\" i]" }
        return (bgcolorExact + styleSelectors).joined(separator: ",\n          ")
    }

    // MARK: - Detection (tests / diagnostics)

    private static let quoteMarker: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"<[^>]+class\s*=\s*["'][^"']*gmail_quote"# + "|"
                + #"<[^>]+id\s*=\s*["']?divRplyFwdMsg"# + "|"
                + #"<blockquote[^>]*type\s*=\s*["']?cite"#,
            options: [.caseInsensitive])
    }()

    private static let lightColor =
        #"(?:#[d-fD-F][0-9a-fA-F]{2}(?:[d-fD-F][0-9a-fA-F]{2}[d-fD-F][0-9a-fA-F]{2})?|#[d-fD-F]{3}|white|ivory|snow|beige|linen|seashell|oldlace|cornsilk|whitesmoke|ghostwhite|floralwhite|honeydew|mintcream|azure|aliceblue|lavenderblush|lightyellow|lightcyan|lemonchiffon|papayawhip|blanchedalmond|antiquewhite|mistyrose|rgb\(\s*(?:2[0-5]\d|1\d\d)\s*,\s*(?:2[0-5]\d|1\d\d)\s*,\s*(?:2[0-5]\d|1\d\d)\s*\))"#

    private static let bgcolorLightValue: NSRegularExpression = {
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
