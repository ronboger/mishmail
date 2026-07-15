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
/// loaded images drop the override and restore any author inline styles we
/// temporarily replaced (never `removeProperty` blindly).
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
    /// - Optional `maxViewportWidth`: further scale the pair so width fits the
    ///   reading pane (keeps height proportional — avoids 1200×600 → 400×600).
    static func cappedSize(width: Int?, height: Int?,
                           maxWidth: Int = maxPreservedWidth,
                           maxHeight: Int = maxPreservedHeight,
                           maxViewportWidth: Int? = nil) -> CappedSize? {
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

        if let vp = maxViewportWidth, vp > 0, let cw = w, cw > Double(vp) {
            let scale = Double(vp) / cw
            w = Double(vp)
            if let ch = h { h = ch * scale }
        }

        return CappedSize(
            width: w.map { max(1, Int($0.rounded())) },
            height: h.map { max(1, Int($0.rounded())) })
    }

    // MARK: - CSS

    /// Extra stylesheet rules appended after the base `img { max-width… }` rule.
    /// Inline sizes from JS are set without `!important` when possible; layout
    /// class keeps box-sizing. Viewport fitting is done in JS so height stays
    /// proportional when width is constrained.
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

    /// Preserve capped authored dimensions on blocked/failed images; restore
    /// author inline styles when an image loads successfully. Installs
    /// load/error listeners and a `ResizeObserver` that reflows placeholders
    /// to the viewport and posts measured height to `mmHeight`.
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

          function viewportWidth(){
            /* Prefer the real viewport, not body clientWidth — email CSS often
               sets body min-width:600 while the WKWebView is narrower; maxing
               with body would skip proportional fit. */
            var w = 0;
            try {
              if (typeof window !== 'undefined' && window.innerWidth) {
                w = window.innerWidth;
              }
              if ((!w || w <= 0) && document.documentElement) {
                w = document.documentElement.clientWidth || 0;
              }
              if ((!w || w <= 0) && document.body) {
                w = document.body.clientWidth || 0;
              }
            } catch (e) {}
            return w > 0 ? w : MAX_W;
          }

          /* Scale the capped pair so width fits the reading pane; keep aspect. */
          function fitViewport(capped){
            if (!capped || capped.w == null) return capped;
            var avail = viewportWidth();
            if (avail > 0 && capped.w > avail) {
              var scale = avail / capped.w;
              capped = {
                w: Math.max(1, Math.round(capped.w * scale)),
                h: capped.h != null ? Math.max(1, Math.round(capped.h * scale)) : null
              };
            }
            return capped;
          }

          function snapshotProp(img, snap, name){
            if (snap[name] != null) return; /* already captured before our override */
            var v = img.style.getPropertyValue(name);
            var p = img.style.getPropertyPriority(name);
            snap[name] = { had: !!(v && v.length), value: v || '', priority: p || '' };
          }

          function restoreProp(img, saved, name){
            if (saved == null) return; /* we never overrode this property */
            if (saved.had) {
              img.style.setProperty(name, saved.value, saved.priority);
            } else {
              img.style.removeProperty(name);
            }
          }

          function clearLayout(img){
            img.classList.remove(LAYOUT, FAILED);
            var snap = img.__mmLayoutSnap;
            if (!snap) return; /* never overrode — leave author styles alone */
            restoreProp(img, snap.width, 'width');
            restoreProp(img, snap.height, 'height');
            restoreProp(img, snap['max-height'], 'max-height');
            try { delete img.__mmLayoutSnap; } catch (e) { img.__mmLayoutSnap = null; }
          }

          function applyImage(img){
            if (img.complete && img.naturalWidth > 0) {
              clearLayout(img);
              return;
            }
            var attrW = img.getAttribute('width');
            var attrH = img.getAttribute('height');
            var capped = fitViewport(capPair(attrW, attrH));
            if (!capped) {
              img.classList.add(FAILED);
              return;
            }
            if (!img.__mmLayoutSnap) img.__mmLayoutSnap = {};
            var snap = img.__mmLayoutSnap;
            img.classList.add(LAYOUT, FAILED);
            if (capped.w != null) {
              snapshotProp(img, snap, 'width');
              img.style.setProperty('width', capped.w + 'px', 'important');
            }
            if (capped.h != null) {
              snapshotProp(img, snap, 'height');
              img.style.setProperty('height', capped.h + 'px', 'important');
            }
          }

          function reflowPlaceholders(){
            var imgs = document.querySelectorAll('img');
            for (var i = 0; i < imgs.length; i++) applyImage(imgs[i]);
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
            window.__mmRO = new ResizeObserver(function(){
              reflowPlaceholders();
              report();
            });
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
