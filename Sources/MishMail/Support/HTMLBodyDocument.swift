import Foundation

/// Assembles the document string loaded into the message-pane `WKWebView`.
///
/// The trusted head (CSP `<meta>` + MishMail `<style>`) is always a synthetic
/// wrapper placed *before the first byte of message markup* — never injected
/// into it. Two payload shapes arrive from Gmail, both wrapped identically:
/// - **Fragments** — body markup only (common for plain/simple mail).
/// - **Complete documents** — full `<!DOCTYPE html>…` (common for
///   transactional / marketing templates).
///
/// Earlier revisions injected the CSP into a complete document's existing
/// `<head>` so author head chrome kept its position. That scanner had to
/// agree with the HTML parser about where the real head is, and a decoy
/// `<head>` inside containers it didn't model — `<template>`, `<iframe>`
/// fallback, `<noscript>` (parsed as markup here because content JS is
/// disabled), `<plaintext>`, SVG/MathML breakout — misdirected the meta into
/// inert content, leaving the message with no CSP at all (Ask-policy remote
/// content bypass). Wrapping is structurally immune: the synthetic head is
/// parsed first, author `<html>`/`<head>` tokens inside the body are ignored
/// by the parser, and author `<style>` elements still apply document-wide
/// wherever they appear, so templates keep their look. A second,
/// attacker-supplied CSP meta can only tighten the effective policy, never
/// loosen it.
enum HTMLBodyDocument {
    /// Build the final HTML string for `loadHTMLString`.
    ///
    /// - Parameters:
    ///   - html: Message body HTML (fragment or complete document) — untrusted.
    ///   - cspMeta: CSP `<meta http-equiv=…>` tag from `HTMLBodyCSP`.
    ///   - styleCSS: Stylesheet *contents* (no outer `<style>` tags) from
    ///     `HTMLBodyDarkMode.injectedCSS` (includes layout image rules).
    ///
    /// Kept as the render call sites' entry point so the name documents the
    /// step ("assemble the document"); `trustedWrapper` is the fail-closed
    /// form blockers/pre-render name directly. Both are one behavior — do not
    /// add a third assembly path.
    static func assemble(html: String, cspMeta: String, styleCSS: String) -> String {
        trustedWrapper(html: html, cspMeta: cspMeta, styleCSS: styleCSS)
    }

    /// Trusted head ahead of untrusted markup. The wrapper's head position
    /// cannot be influenced by message markup, so the CSP always applies —
    /// this is also the fail-closed path used when WebKit's remote-image
    /// content rule cannot be prepared.
    static func trustedWrapper(html: String, cspMeta: String, styleCSS: String) -> String {
        let styleTag = "<style>\n\(styleCSS)\n</style>"
        return "<html><head>\(cspMeta)\(styleTag)</head><body>\(html)</body></html>"
    }
}
