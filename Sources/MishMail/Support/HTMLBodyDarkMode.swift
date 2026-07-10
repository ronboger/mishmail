import Foundation

/// Dark-mode styling for HTML email in the reading pane.
///
/// One stylesheet for all mail (not a plain-vs-designed branch):
/// 1. Force light text over our dark chrome — beats Outlook/Word inline black.
/// 2. Force dark text *inside* light surfaces (white sig cards, cream panels,
///    full-bleed white transactional mail) so those islands stay readable
///    without flipping the whole message.
///
/// Light surfaces are found two ways:
/// - **Attribute fast path:** `bgcolor` / inline `style` selectors (no JS).
/// - **Computed path:** a `WKUserScript` at document-end (plus a didFinish
///   re-run) tags elements whose *computed* `background-color` is light with
///   `.mm-light-bg`. That catches backgrounds declared only in `<style>`
///   blocks or CSS classes — Notion Calendar, many marketing templates —
///   which the attribute selectors miss (light-on-white regression).
///
/// Binary classification failed on mixed mail (Ashley @ Gelt): a white
/// signature in the authored head selected the "designed" path, leaving
/// unstyled body text at `#222` on transparent dark chrome.
enum HTMLBodyDarkMode {
    /// Class stamped by `tagLightSurfacesJS` on elements with a light
    /// computed background. Mirrored in CSS so descendants get dark text.
    static let lightSurfaceClass = "mm-light-bg"

    /// Relative luminance above this (sRGB 0–1) counts as a light surface.
    /// ~0.72 is mid-cream; pure white is 1.0, `#faf8f5` is ~0.97.
    static let luminanceThreshold = 0.72

    /// Alpha below this is treated as transparent (plain mail over dark chrome
    /// must not be tagged).
    static let alphaFloor = 0.5

    /// Injected stylesheet contents (no outer `<style>` tags) for the message pane.
    static func injectedCSS(fontScale: Double, collapseQuote: Bool, html: String = "") -> String {
        // `html` kept for API stability / future per-message tweaks; unused now.
        _ = html
        let font = Int(14.5 * fontScale)
        let quote = collapseQuote ? QuotedReply.hideQuoteCSS : ""
        // Light-surface selectors: white + first-nibble d–f hex + common names.
        // Applied to the element and its descendants so sig cards / cream
        // wrappers keep dark text while the surrounding body stays light.
        // Wrap the multi-selector list in :is() so descendant combinators
        // apply to EVERY light surface, not just the last one. Without this,
        // `A, B, C :not(a)` only styles C's children — cream/white wrappers
        // matched A/B but their text still got the body #e6e6e6 force (Urban
        // Adamah light-on-cream regression after 8aac8ea).
        //
        // `.mm-light-bg` is the computed-style twin of those attribute
        // selectors (see `tagLightSurfacesJS`).
        let light = lightSurfaceSelector
        let cls = lightSurfaceClass
        return """
        :root { color-scheme: light dark; }
        html, body { height: auto !important; min-height: 0 !important; }
        body { font: \(font)px -apple-system, sans-serif; color: canvastext; margin: 0; background: transparent; }
        img { max-width: 100%; height: auto; }
        @media (prefers-color-scheme: dark) {
          body, body :not(a):not(a *) { color: #e6e6e6 !important; }
          a, a * { color: #6cb2ff !important; }
          :is(\(light)),
          :is(\(light)) :not(a):not(a *),
          .\(cls),
          .\(cls) :not(a):not(a *) {
            color: #222 !important;
          }
          :is(\(light)) a,
          :is(\(light)) a *,
          .\(cls) a,
          .\(cls) a * {
            color: #0b57d0 !important;
          }
        }
        \(quote)
        """
    }

    /// Whether a solid fill with the given sRGB channels should force dark text.
    ///
    /// Shared by unit tests and the JS tagger (constants are interpolated into
    /// `tagLightSurfacesJS` so thresholds cannot drift). Channels are 0–255;
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

    /// App-injected JS (page scripts stay disabled). Walks the DOM and adds
    /// `lightSurfaceClass` to every element whose *computed* background-color
    /// is light and opaque enough to paint over the reading-pane chrome.
    ///
    /// Installed as a `WKUserScript` at `.atDocumentEnd` so it runs during
    /// initial parse (before first paint), and re-run from `didFinish` as a
    /// belt-and-suspenders pass. Safe to re-run; re-tags without removing
    /// prior classes.
    static var tagLightSurfacesJS: String {
        let cls = lightSurfaceClass
        let lum = luminanceThreshold
        let alpha = alphaFloor
        return """
        (function(){
          var CLS='\(cls)';
          var LUM=\(lum);
          var AMIN=\(alpha);
          function light(bg){
            if(!bg||bg==='transparent') return false;
            var m=bg.match(/rgba?\\((\\d+),\\s*(\\d+),\\s*(\\d+)(?:,\\s*([\\d.]+))?\\)/i);
            if(!m) return false;
            var a=m[4]===undefined?1:parseFloat(m[4]);
            if(a<AMIN) return false;
            var r=+m[1],g=+m[2],b=+m[3];
            return (0.2126*r+0.7152*g+0.0722*b)/255>LUM;
          }
          function walk(el){
            try{
              // background-color only — background-image (light PNG/gradient)
              // with transparent fill is intentionally not tagged.
              if(light(getComputedStyle(el).backgroundColor)) el.classList.add(CLS);
            }catch(e){}
            var kids=el.children;
            for(var i=0;i<kids.length;i++) walk(kids[i]);
          }
          if(document.documentElement) walk(document.documentElement);
        })();
        """
    }

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
