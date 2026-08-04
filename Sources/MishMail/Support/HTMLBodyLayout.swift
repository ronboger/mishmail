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
/// ## Height feedback loops
/// The reading pane sizes each `WKWebView` to the measured content height so
/// the outer SwiftUI `ScrollView` owns scrolling. Marketing templates
/// (Thumbtack, newsletters) often set `min-height: 100vh`, `height="100%"`,
/// or percentage CSS heights (`height: 100%`) on wrappers. Those resolve
/// against the WebView viewport: measure → grow frame → viewport grows →
/// measure grows → infinite scroll. Caps and neutralization below break that
/// loop without trapping the wheel inside the WebView.
///
/// Freezing reports after consecutive dH≈dVH samples stops genuine runaway
/// growth, but early-load false freezes can pin a tiny pre-streak height
/// (especially when remote images stay blocked and never unfreeze). Recovery
/// re-measures while frozen and adopts a taller height only when the viewport
/// is stable — still bounded by an adoption budget and `maxContentHeight`.
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
    /// Class stamped on nodes whose viewport-tied height/min-height was neutralized.
    static let heightNeutralizedClass = "mm-h-neutralized"

    /// `WKScriptMessageHandler` name for continuous height reports.
    static let heightHandlerName = "mmHeight"

    /// Max preserved width (px) for blocked-image layout boxes.
    static let maxPreservedWidth = 1200
    /// Max preserved height (px) for blocked-image layout boxes.
    static let maxPreservedHeight = 2000

    /// Minimum reported content height (matches prior measure floor).
    static let minContentHeight = 40

    /// Hard ceiling on reported content height (px). Pathological markup or a
    /// residual feedback loop must not create an unbounded SwiftUI frame.
    /// ~50k px ≈ many screens of mail; still scrollable via the outer pane.
    static let maxContentHeight = 50_000

    // MARK: - Feedback freeze (pure; mirrored in JS)

    /// Consecutive dH≈dVH samples required before freezing. One-shot matches
    /// can be concurrent font reflow + frame catch-up (false positive that
    /// would clip real content under the outer ScrollView).
    static let feedbackHitsToFreeze = 2
    /// Minimum positive deltas (px) to count as growth on either axis.
    static let feedbackMinDelta: CGFloat = 2
    /// |dH − dVH| tolerance for "content height tracks viewport growth".
    static let feedbackDeltaTolerance: CGFloat = 4

    /// Consecutive unchanged-viewport samples required before adopting a taller
    /// measured height while frozen (false-freeze recovery). Mirrors
    /// `feedbackHitsToFreeze` so a single reflow cannot unstick a real freeze.
    static let freezeRecoveryStableViewportSamples = 2
    /// Measured height must exceed frozen height by more than this (px) to adopt.
    static let freezeRecoveryHeightTolerance: CGFloat = 8
    /// Max false-freeze adoptions per document; after this the freeze is permanent.
    static let freezeRecoveryMaxAdoptions = 3

    /// Result of one feedback observation step (unit-tested; JS mirrors).
    struct FeedbackStep: Equatable {
        /// Updated consecutive feedback-hit count (0 when this sample is not feedback).
        var consecutiveHits: Int
        /// Height recorded at the start of the current feedback streak.
        var streakBaseHeight: CGFloat?
        /// Viewport recorded at the start of the current feedback streak.
        var streakBaseViewport: CGFloat?
        /// When non-nil, freeze publishing at this height.
        var freezeAt: CGFloat?
    }

    /// Result of one freeze-recovery observation step (unit-tested; JS mirrors).
    struct FreezeRecoveryStep: Equatable {
        /// When non-nil, clear freeze and publish this clamped height.
        var adoptHeight: CGFloat?
        /// Updated consecutive samples with unchanged viewport while frozen.
        var stableViewportSamples: Int
        /// Adoptions consumed after this step (budget is per document).
        var adoptionsUsed: Int
    }

    /// True when content height grew by roughly the same amount as the viewport
    /// — the signature of a measure→frame→vh feedback loop.
    static func isFeedbackGrowth(
        previousHeight: CGFloat,
        previousViewport: CGFloat,
        height: CGFloat,
        viewport: CGFloat
    ) -> Bool {
        guard previousHeight > 0, previousViewport > 0, viewport > 0 else { return false }
        let dH = height - previousHeight
        let dVH = viewport - previousViewport
        return dH > feedbackMinDelta
            && dVH > feedbackMinDelta
            && abs(dH - dVH) <= feedbackDeltaTolerance
    }

    /// Advance the freeze state machine for one measure sample.
    ///
    /// Freezes only after `feedbackHitsToFreeze` consecutive feedback samples,
    /// at the content height from *before* the streak began (so SwiftUI does
    /// not expand into the loop). A non-feedback sample clears the streak.
    ///
    /// A genuine measure→frame→viewport runaway implies content is at least as
    /// tall as the viewport it was driving when the streak started. Refuse to
    /// freeze when the streak base is below the *streak-start* viewport
    /// (within `feedbackDeltaTolerance`). Anchor to that fixed viewport — not
    /// the live one — so a runaway that grows both height and viewport each
    /// sample cannot drift past the tolerance and block freeze forever.
    /// When the guard blocks, keep counting the streak so a later legitimately
    /// large base (new streak) can still freeze.
    static func observeFeedback(
        previousHeight: CGFloat,
        previousViewport: CGFloat,
        height: CGFloat,
        viewport: CGFloat,
        consecutiveHits: Int,
        streakBaseHeight: CGFloat?,
        streakBaseViewport: CGFloat?
    ) -> FeedbackStep {
        guard isFeedbackGrowth(
            previousHeight: previousHeight,
            previousViewport: previousViewport,
            height: height,
            viewport: viewport
        ) else {
            return FeedbackStep(
                consecutiveHits: 0,
                streakBaseHeight: nil,
                streakBaseViewport: nil,
                freezeAt: nil)
        }
        let base = streakBaseHeight ?? previousHeight
        let baseVH = streakBaseViewport ?? previousViewport
        let hits = consecutiveHits + 1
        var freeze: CGFloat? = nil
        if hits >= feedbackHitsToFreeze {
            // base >= streak-start viewport − tolerance
            //  ⇔  base + tolerance >= streakBaseViewport
            if base + feedbackDeltaTolerance >= baseVH {
                freeze = base
            }
            // else: below-viewport guard — keep hits/base/baseVH, do not freeze yet
        }
        return FeedbackStep(
            consecutiveHits: hits,
            streakBaseHeight: base,
            streakBaseViewport: baseVH,
            freezeAt: freeze)
    }

    /// Decide whether a frozen height should be abandoned for a taller measure.
    ///
    /// Early-load false freezes pin a tiny pre-streak height; blocked remote
    /// images never fire the load-path unfreeze. Recovery requires:
    /// - viewport unchanged across `freezeRecoveryStableViewportSamples` samples
    ///   (still growing ⇒ real feedback loop; do not unstick)
    /// - measured height exceeds frozen by more than `freezeRecoveryHeightTolerance`
    /// - adoption budget remaining (`freezeRecoveryMaxAdoptions` per document)
    ///
    /// Heights are clamped to `[minContentHeight, maxContentHeight]` on adopt.
    static func observeFreezeRecovery(
        frozenHeight: CGFloat,
        measuredHeight: CGFloat,
        previousViewport: CGFloat,
        viewport: CGFloat,
        stableViewportSamples: Int,
        adoptionsUsed: Int
    ) -> FreezeRecoveryStep {
        guard frozenHeight > 0, adoptionsUsed < freezeRecoveryMaxAdoptions else {
            return FreezeRecoveryStep(
                adoptHeight: nil,
                stableViewportSamples: 0,
                adoptionsUsed: adoptionsUsed)
        }
        let viewportUnchanged = previousViewport > 0 && viewport == previousViewport
        let nextStable = viewportUnchanged ? stableViewportSamples + 1 : 0
        let measured = clampContentHeight(measuredHeight)
        let frozen = clampContentHeight(frozenHeight)
        if nextStable >= freezeRecoveryStableViewportSamples
            && measured > frozen + freezeRecoveryHeightTolerance {
            return FreezeRecoveryStep(
                adoptHeight: measured,
                stableViewportSamples: 0,
                adoptionsUsed: adoptionsUsed + 1)
        }
        return FreezeRecoveryStep(
            adoptHeight: nil,
            stableViewportSamples: nextStable,
            adoptionsUsed: adoptionsUsed)
    }

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

    /// Clamp a measured content height into the publishable range.
    static func clampContentHeight(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return CGFloat(minContentHeight) }
        let lo = CGFloat(minContentHeight)
        let hi = CGFloat(maxContentHeight)
        return min(max(raw, lo), hi)
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

    /// Break measure→frame→viewport feedback common in marketing HTML.
    ///
    /// Complements `html, body { height: auto; min-height: 0 }` in dark-mode
    /// CSS. Attribute selectors catch the bulk of email markup; JS still
    /// neutralizes computed ≈-viewport min-heights and percentage-authored
    /// heights from stylesheets / inline styles that attribute CSS misses.
    static var antiFeedbackCSS: String {
        let neutral = heightNeutralizedClass
        // Declaration-anchored substrings (with and without space after colon)
        // so we do not match bare "100vh" inside e.g. 1100vh. Covers the four
        // CSS viewport units common in modern marketing templates.
        let vhUnits = ["vh", "dvh", "svh", "lvh"]
        var vhRules: [String] = []
        for unit in vhUnits {
            for prop in ["min-height", "height"] {
                vhRules.append("[style*=\"\(prop):100\(unit)\" i]")
                vhRules.append("[style*=\"\(prop): 100\(unit)\" i]")
            }
        }
        let vhSelector = vhRules.joined(separator: ",\n        ")
        // Same declaration-anchored approach for percentage heights (not bare
        // height="100" attributes — those are 100px spacers in transactional mail).
        var pctRules: [String] = []
        for prop in ["min-height", "height"] {
            pctRules.append("[style*=\"\(prop):100%\" i]")
            pctRules.append("[style*=\"\(prop): 100%\" i]")
        }
        let pctSelector = pctRules.joined(separator: ",\n        ")
        return """
        /* Full-bleed height="100%" tables fill the WKWebView viewport; when
           the host frame tracks content height that creates infinite grow.
           Only the percent form — bare height="100" means 100px spacers
           (transactional templates) and must not be collapsed. */
        table[height="100%"], tbody[height="100%"], tr[height="100%"],
        td[height="100%"], th[height="100%"], div[height="100%"] {
          height: auto !important;
        }
        /* Inline viewport units — declaration-anchored (not bare 100vh). */
        \(vhSelector) {
          min-height: 0 !important;
          height: auto !important;
        }
        /* Inline percentage heights couple content to the host viewport the
           same way 100vh does when the frame tracks measured height. Bare
           height="100" (no %) is 100px and must not match. */
        \(pctSelector) {
          height: auto !important;
          min-height: 0 !important;
        }
        .\(neutral) {
          min-height: 0 !important;
        }
        """
    }

    // MARK: - JavaScript (app-injected; page scripts stay disabled)

    /// Preserve capped authored dimensions on blocked/failed images; restore
    /// author inline styles when an image loads successfully. Installs
    /// load/error listeners and a `ResizeObserver` that reflows placeholders
    /// to the viewport and posts measured height to `mmHeight`.
    ///
    /// Also neutralizes viewport-tied min-heights and percentage heights, and
    /// freezes reports that track frame growth so marketing mail cannot
    /// infinite-scroll the pane. False freezes recover when the viewport is
    /// stable and measured height clearly exceeds the freeze floor (budgeted).
    ///
    /// Safe to re-run: disconnects any prior observer and rebinds listeners.
    /// Idempotent class/style updates.
    static var installLayoutAndMeasureJS: String {
        let layout = layoutImageClass
        let failed = failedImageClass
        let neutral = heightNeutralizedClass
        let maxW = maxPreservedWidth
        let maxH = maxPreservedHeight
        let minH = minContentHeight
        let maxContent = maxContentHeight
        let handler = heightHandlerName
        let hitsToFreeze = feedbackHitsToFreeze
        let minDelta = Int(feedbackMinDelta.rounded())
        let deltaTol = Int(feedbackDeltaTolerance.rounded())
        let recoveryStable = freezeRecoveryStableViewportSamples
        let recoveryTol = Int(freezeRecoveryHeightTolerance.rounded())
        let recoveryMax = freezeRecoveryMaxAdoptions
        return """
        (function(){
          var LAYOUT='\(layout)';
          var FAILED='\(failed)';
          var NEUTRAL='\(neutral)';
          var MAX_W=\(maxW);
          var MAX_H=\(maxH);
          var MIN_H=\(minH);
          var MAX_CONTENT_H=\(maxContent);
          var HANDLER='\(handler)';
          var HITS_TO_FREEZE=\(hitsToFreeze);
          var MIN_DELTA=\(minDelta);
          var DELTA_TOL=\(deltaTol);
          var RECOVERY_STABLE_VH=\(recoveryStable);
          var RECOVERY_TOL=\(recoveryTol);
          var RECOVERY_MAX_ADOPTIONS=\(recoveryMax);

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

          function viewportHeight(){
            var h = 0;
            try {
              if (typeof window !== 'undefined' && window.innerHeight) {
                h = window.innerHeight;
              }
              if ((!h || h <= 0) && document.documentElement) {
                h = document.documentElement.clientHeight || 0;
              }
            } catch (e) {}
            return h > 0 ? h : 0;
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

          /* Kill computed *min-heights* that track the WKWebView viewport, and
             computed *heights* whose authored value is percentage-based and
             resolves ≈ viewport. Email stylesheets often set min-height:100vh
             or height:100% on wrappers; attribute CSS cannot see stylesheet
             rules. Fixed px heights (e.g. height:600px hero that briefly
             equals the viewport) must not be permanently collapsed — only
             percentage-authored heights are sticky-neutralized on the height
             axis. Min-height threshold: within 2px of the current viewport
             and at least 200px. */
          function neutralizeViewportHeights(){
            var vh = viewportHeight();
            if (vh < 200) return false;
            if (typeof window.__mmLastNeutralVH === 'number'
                && window.__mmLastNeutralVH === vh) {
              /* Viewport height unchanged — skip O(n) getComputedStyle walk. */
              return false;
            }
            window.__mmLastNeutralVH = vh;
            var changed = false;
            var nodes = document.querySelectorAll('body, body *');
            for (var i = 0; i < nodes.length; i++) {
              var el = nodes[i];
              if (el.classList && el.classList.contains(NEUTRAL)) continue;
              var tag = (el.tagName || '').toLowerCase();
              if (tag === 'img' || tag === 'svg' || tag === 'video' || tag === 'canvas') continue;
              var cs;
              try { cs = window.getComputedStyle(el); } catch (e) { continue; }
              if (!cs) continue;
              var mh = parseFloat(cs.minHeight);
              var killMin = (mh === mh) && mh >= 200 && Math.abs(mh - vh) <= 2;
              /* Percentage-authored height only — never fixed px heroes. */
              var styleH = '';
              try { styleH = (el.style && el.style.height) ? el.style.height : ''; } catch (e) {}
              var attrH = '';
              try { attrH = el.getAttribute('height') || ''; } catch (e) {}
              var authoredPct =
                (styleH && styleH.charAt(styleH.length - 1) === '%')
                || (attrH && String(attrH).charAt(String(attrH).length - 1) === '%');
              var ch = parseFloat(cs.height);
              var killHeight = authoredPct && (ch === ch) && Math.abs(ch - vh) <= 2;
              if (!killMin && !killHeight) continue;
              if (killMin) el.style.setProperty('min-height', '0', 'important');
              if (killHeight) el.style.setProperty('height', 'auto', 'important');
              if (el.classList) el.classList.add(NEUTRAL);
              changed = true;
            }
            return changed;
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
            return Math.ceil(Math.max(Math.min(content, MAX_CONTENT_H), MIN_H));
          }

          function postHeight(h){
            h = Math.min(Math.max(h, MIN_H), MAX_CONTENT_H);
            try {
              if (window.webkit && webkit.messageHandlers && webkit.messageHandlers[HANDLER]) {
                webkit.messageHandlers[HANDLER].postMessage(h);
              }
            } catch (e) {}
            return h;
          }

          /* Anti-feedback state (mirrors HTMLBodyLayout.observeFeedback /
             observeFreezeRecovery). Freezes only after HITS_TO_FREEZE
             consecutive dH≈dVH samples so a one-shot concurrent reflow does
             not clip real content. Refuses freeze when base < streak-start
             viewport (__mmFeedbackBaseVH) — anchored at streak begin so a
             runaway cannot drift the live viewport past the tolerance.
             While frozen, re-measure and recover if viewport is stable and
             content is clearly taller (budgeted adoptions). */
          if (typeof window.__mmLastH !== 'number') window.__mmLastH = 0;
          if (typeof window.__mmLastVH !== 'number') window.__mmLastVH = 0;
          if (typeof window.__mmFrozenH !== 'number') window.__mmFrozenH = 0;
          if (typeof window.__mmFeedbackHits !== 'number') window.__mmFeedbackHits = 0;
          if (typeof window.__mmFeedbackBase !== 'number') window.__mmFeedbackBase = 0;
          if (typeof window.__mmFeedbackBaseVH !== 'number') window.__mmFeedbackBaseVH = 0;
          if (typeof window.__mmFreezeStableVH !== 'number') window.__mmFreezeStableVH = 0;
          if (typeof window.__mmFreezeAdoptions !== 'number') window.__mmFreezeAdoptions = 0;

          function isFeedbackGrowth(lastH, lastVH, h, vh){
            if (!(lastH > 0 && lastVH > 0 && vh > 0)) return false;
            var dH = h - lastH;
            var dVH = vh - lastVH;
            return dH > MIN_DELTA && dVH > MIN_DELTA && Math.abs(dH - dVH) <= DELTA_TOL;
          }

          /* Mirrors HTMLBodyLayout.observeFreezeRecovery. */
          function observeFreezeRecovery(frozenH, measuredH, lastVH, vh, stableSamples, adoptionsUsed){
            if (!(frozenH > 0) || adoptionsUsed >= RECOVERY_MAX_ADOPTIONS) {
              return { adopt: 0, stable: 0, adoptions: adoptionsUsed };
            }
            var nextStable = (lastVH > 0 && vh === lastVH) ? (stableSamples + 1) : 0;
            var measured = Math.min(Math.max(measuredH, MIN_H), MAX_CONTENT_H);
            var frozen = Math.min(Math.max(frozenH, MIN_H), MAX_CONTENT_H);
            if (nextStable >= RECOVERY_STABLE_VH && measured > frozen + RECOVERY_TOL) {
              return { adopt: measured, stable: 0, adoptions: adoptionsUsed + 1 };
            }
            return { adopt: 0, stable: nextStable, adoptions: adoptionsUsed };
          }

          function report(){
            var h = measure();
            var vh = viewportHeight();
            if (window.__mmFrozenH > 0) {
              /* Keep measuring while frozen — recover false positives without
                 depending on image loads (remote images are often blocked). */
              var rec = observeFreezeRecovery(
                window.__mmFrozenH, h, window.__mmLastVH, vh,
                window.__mmFreezeStableVH || 0,
                window.__mmFreezeAdoptions || 0);
              window.__mmFreezeStableVH = rec.stable;
              window.__mmFreezeAdoptions = rec.adoptions;
              window.__mmLastVH = vh;
              if (rec.adopt > 0) {
                window.__mmFrozenH = 0;
                window.__mmFeedbackHits = 0;
                window.__mmFeedbackBase = 0;
                window.__mmFeedbackBaseVH = 0;
                window.__mmLastH = rec.adopt;
                return postHeight(rec.adopt);
              }
              return postHeight(window.__mmFrozenH);
            }
            var lastH = window.__mmLastH;
            var lastVH = window.__mmLastVH;
            if (isFeedbackGrowth(lastH, lastVH, h, vh)) {
              if (!window.__mmFeedbackBase) {
                window.__mmFeedbackBase = lastH;
                window.__mmFeedbackBaseVH = lastVH;
              }
              window.__mmFeedbackHits = (window.__mmFeedbackHits || 0) + 1;
              if (window.__mmFeedbackHits >= HITS_TO_FREEZE) {
                /* Refuse freeze when base < streak-start viewport (early-load
                   false positive). Compare against __mmFeedbackBaseVH, not
                   live vh, so runaway growth cannot drift past the guard.
                   Keep the streak so a later legitimately large base can freeze. */
                var base = window.__mmFeedbackBase;
                var baseVH = window.__mmFeedbackBaseVH;
                if (base + DELTA_TOL >= baseVH) {
                  window.__mmFrozenH = base;
                  window.__mmFreezeStableVH = 0;
                  h = window.__mmFrozenH;
                }
              }
            } else {
              window.__mmFeedbackHits = 0;
              window.__mmFeedbackBase = 0;
              window.__mmFeedbackBaseVH = 0;
            }
            if (window.__mmFrozenH <= 0) {
              window.__mmLastH = h;
              window.__mmLastVH = vh;
            }
            return postHeight(h);
          }

          function onImgEvent(ev){
            var img = ev.target;
            applyImage(img);
            /* Only real geometry changes should unfreeze. Blocked/error images
               already have placeholders applied — clearing freeze on every
               error restarts the measure→frame loop and can oscillate. */
            if (img && img.complete && img.naturalWidth > 0) {
              window.__mmFrozenH = 0;
              window.__mmFeedbackHits = 0;
              window.__mmFeedbackBase = 0;
              window.__mmFeedbackBaseVH = 0;
              window.__mmFreezeStableVH = 0;
            }
            report();
          }

          /* Fresh install: clear freeze from a previous document on this view. */
          window.__mmLastH = 0;
          window.__mmLastVH = 0;
          window.__mmFrozenH = 0;
          window.__mmLastNeutralVH = 0;
          window.__mmFeedbackHits = 0;
          window.__mmFeedbackBase = 0;
          window.__mmFeedbackBaseVH = 0;
          window.__mmFreezeStableVH = 0;
          window.__mmFreezeAdoptions = 0;

          neutralizeViewportHeights();

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
              /* Re-check after host frame changes — new viewport px can make
                 previously sub-threshold min-heights match 100vh. */
              neutralizeViewportHeights();
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

    /// Disconnect ResizeObserver and clear freeze/feedback globals. Called on
    /// every recycle path so parked views never keep prior callbacks/state.
    static var teardownJS: String {
        """
        (function(){
          try {
            if (window.__mmRO) { window.__mmRO.disconnect(); window.__mmRO = null; }
          } catch (e) {}
          try {
            window.__mmLastH = 0;
            window.__mmLastVH = 0;
            window.__mmFrozenH = 0;
            window.__mmLastNeutralVH = 0;
            window.__mmFeedbackHits = 0;
            window.__mmFeedbackBase = 0;
            window.__mmFeedbackBaseVH = 0;
            window.__mmFreezeStableVH = 0;
            window.__mmFreezeAdoptions = 0;
          } catch (e) {}
        })();
        """
    }
}
