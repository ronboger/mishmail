import Foundation

/// Layout helpers for HTML email in the reading pane: bounded image-dimension
/// preservation when remote images are blocked, continuous height measurement,
/// and shared constants/JS used by `HTMLBodyView`.
///
/// ## Why preserve dimensions?
/// Transactional templates (2FA, receipts) often use remote logos / spacer GIFs
/// with HTML `width`/`height` attributes to hold vertical space. MishMail's
/// default privacy policy blocks remote images, and CSS `img { height: auto }`
/// then collapses those boxes — the card looks "vertically compressed" and
/// authored text can bunch up or sit under empty shell chrome.
///
/// ## Security
/// Email HTML is untrusted. Authored dimensions are capped so
/// `<img height="100000">` cannot create an enormous card. Caps apply only to
/// the *layout placeholder* path (blocked / failed images); successfully
/// loaded images drop the override and use proportional `height: auto`.
enum HTMLBodyLayout {
    /// Class stamped on images using preserved authored dimensions.
    static let layoutImageClass = "mm-img-layout"
    /// Class stamped when the image failed or is blocked (no natural size).
    static let failedImageClass = "mm-img-failed"

    /// `WKScriptMessageHandler` name for continuous height reports.
    static let heightHandlerName = "mmHeight"

    /// Max preserved width (px) for blocked-image layout boxes.
    static let maxPreservedWidth = 1200
    /// Max preserved height (px) for blocked-image layout boxes.
    static let maxPreservedHeight = 2000

    /// Minimum reported content height (matches prior measure floor).
    static let minContentHeight = 40

    // MARK: - Dimension cap (pure; mirrored in JS)

    /// Bounded size derived from HTML width/height attributes.
    struct CappedSize: Equatable {
        var width: Int?
        var height: Int?
    }

    /// Cap authored image dimensions for layout placeholders.
    ///
    /// - Both dimensions present: scale proportionally so neither exceeds max.
    /// - One present: clamp that axis only.
    /// - Neither / non-positive: `nil` (no layout override).
    static func cappedSize(width: Int?, height: Int?,
                           maxWidth: Int = maxPreservedWidth,
                           maxHeight: Int = maxPreservedHeight) -> CappedSize? {
        let wIn = width.flatMap { $0 > 0 ? $0 : nil }
        let hIn = height.flatMap { $0 > 0 ? $0 : nil }
        guard wIn != nil || hIn != nil else { return nil }

        var w = wIn.map { Double($0) }
        var h = hIn.map { Double($0) }
        let maxW = Double(maxWidth)
        let maxH = Double(maxHeight)

        if let cw = w, cw > maxW {
            let scale = maxW / cw
            w = maxW
            if let ch = h { h = ch * scale }
        }
        if let ch = h, ch > maxH {
            let scale = maxH / ch
            h = maxH
            if let cw = w { w = cw * scale }
        }
        // Re-clamp width if height scaling pushed it over again.
        if let cw = w, cw > maxW {
            let scale = maxW / cw
            w = maxW
            if let ch = h { h = ch * scale }
        }

        return CappedSize(
            width: w.map { max(1, Int($0.rounded())) },
            height: h.map { max(1, Int($0.rounded())) })
    }

    // MARK: - CSS

    /// Extra stylesheet rules appended after the base `img { max-width… }` rule.
    /// Inline `!important` sizes from JS win over `height: auto` for layout boxes.
    static var imageCSS: String {
        let layout = layoutImageClass
        let failed = failedImageClass
        return """
        img.\(layout) {
          max-width: 100%;
          object-fit: contain;
          box-sizing: border-box;
        }
        img.\(failed) {
          background-color: rgba(127, 127, 127, 0.10);
          outline: 1px dashed rgba(127, 127, 127, 0.35);
          outline-offset: -1px;
        }
        """
    }

    // MARK: - JavaScript (app-injected; page scripts stay disabled)

    /// Preserve capped authored dimensions on blocked/failed images; clear
    /// overrides when an image loads successfully. Installs load/error
    /// listeners and a `ResizeObserver` that posts measured height to
    /// `webkit.messageHandlers.mmHeight`.
    ///
    /// Safe to re-run: disconnects any prior observer and rebinds listeners.
    /// Idempotent class/style updates.
    static var installLayoutAndMeasureJS: String {
        let layout = layoutImageClass
        let failed = failedImageClass
        let maxW = maxPreservedWidth
        let maxH = maxPreservedHeight
        let minH = minContentHeight
        let handler = heightHandlerName
        return """
        (function(){
          var LAYOUT='\(layout)';
          var FAILED='\(failed)';
          var MAX_W=\(maxW);
          var MAX_H=\(maxH);
          var MIN_H=\(minH);
          var HANDLER='\(handler)';

          function capPair(w, h){
            w = parseInt(w, 10); h = parseInt(h, 10);
            var hasW = w > 0, hasH = h > 0;
            if (!hasW && !hasH) return null;
            if (hasW && w > MAX_W) {
              if (hasH) h = Math.round(h * (MAX_W / w));
              w = MAX_W;
            }
            if (hasH && h > MAX_H) {
              if (hasW) w = Math.round(w * (MAX_H / h));
              h = MAX_H;
            }
            if (hasW && w > MAX_W) {
              if (hasH) h = Math.round(h * (MAX_W / w));
              w = MAX_W;
            }
            return {
              w: hasW ? Math.max(1, w) : null,
              h: hasH ? Math.max(1, h) : null
            };
          }

          function clearLayout(img){
            img.classList.remove(LAYOUT, FAILED);
            img.style.removeProperty('width');
            img.style.removeProperty('height');
            img.style.removeProperty('max-height');
          }

          function applyImage(img){
            if (img.complete && img.naturalWidth > 0) {
              clearLayout(img);
              return;
            }
            var attrW = img.getAttribute('width');
            var attrH = img.getAttribute('height');
            var capped = capPair(attrW, attrH);
            if (!capped) {
              img.classList.add(FAILED);
              return;
            }
            img.classList.add(LAYOUT, FAILED);
            if (capped.w != null) {
              img.style.setProperty('width', capped.w + 'px', 'important');
            }
            if (capped.h != null) {
              img.style.setProperty('height', capped.h + 'px', 'important');
            }
          }

          function measure(){
            var body = document.body;
            if (!body) return MIN_H;
            var bodyTop = body.getBoundingClientRect().top;
            var bottom = bodyTop;
            var kids = body.children;
            for (var i = 0; i < kids.length; i++) {
              var r = kids[i].getBoundingClientRect();
              /* display:none quote containers report height 0 — skip them. */
              if (r.height > 0) bottom = Math.max(bottom, r.bottom);
            }
            var content = bottom - bodyTop;
            if (content < 1) {
              content = Math.max(body.scrollHeight, body.getBoundingClientRect().height);
            }
            return Math.ceil(Math.max(content, MIN_H));
          }

          function report(){
            var h = measure();
            try {
              if (window.webkit && webkit.messageHandlers && webkit.messageHandlers[HANDLER]) {
                webkit.messageHandlers[HANDLER].postMessage(h);
              }
            } catch (e) {}
            return h;
          }

          function onImgEvent(ev){
            applyImage(ev.target);
            report();
          }

          var imgs = document.querySelectorAll('img');
          for (var i = 0; i < imgs.length; i++) {
            var img = imgs[i];
            applyImage(img);
            img.removeEventListener('load', onImgEvent);
            img.removeEventListener('error', onImgEvent);
            img.addEventListener('load', onImgEvent);
            img.addEventListener('error', onImgEvent);
          }

          try {
            if (window.__mmRO) { window.__mmRO.disconnect(); window.__mmRO = null; }
          } catch (e) {}
          if (typeof ResizeObserver !== 'undefined' && document.body) {
            window.__mmRO = new ResizeObserver(function(){ report(); });
            window.__mmRO.observe(document.body);
            try {
              if (document.documentElement) {
                window.__mmRO.observe(document.documentElement);
              }
            } catch (e) {}
          }

          return report();
        })();
        """
    }

    /// Disconnect ResizeObserver and strip layout markers. Called on recycle
    /// before the DOM is cleared so recycled views never keep prior callbacks.
    static var teardownJS: String {
        """
        (function(){
          try {
            if (window.__mmRO) { window.__mmRO.disconnect(); window.__mmRO = null; }
          } catch (e) {}
        })();
        """
    }
}
