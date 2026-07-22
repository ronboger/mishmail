import SwiftUI

/// Emerging design-token system. The app grew a lot of inline `font(.system(
/// size: 12.5))`-style magic numbers; new code should reach for these so the
/// type scale stays consistent (and header-gap-style tweaks become one edit).
enum PMFont {
    static func title(_ scale: CGFloat = 1) -> Font { .system(size: 19 * scale, weight: .semibold) }
    static func body(_ scale: CGFloat = 1) -> Font { .system(size: 14 * scale) }
    static func secondary(_ scale: CGFloat = 1) -> Font { .system(size: 12.5 * scale) }
    static func caption(_ scale: CGFloat = 1) -> Font { .system(size: 11 * scale) }
}

enum PMSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

/// Shared motion vocabulary. Navigation and list triage intentionally use no
/// animation; these tokens are for small, interruptible disclosure/feedback.
enum PMMotion {
    static let quick = Animation.easeOut(duration: 0.08)
    static let interactive = Animation.easeOut(duration: 0.12)
    static let feedback = Animation.easeOut(duration: 0.15)
}

/// Corner radii. Prefer `outer(inner:padding:)` when nesting rounded surfaces
/// so the outer arc stays concentric with the inner one.
enum PMRadius {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 6
    static let md: CGFloat = 8
    static let lg: CGFloat = 12
    static let xl: CGFloat = 16

    /// `outerRadius = innerRadius + padding` — the usual fix for nested cards
    /// that otherwise look "off" with matching radii.
    static func outer(inner: CGFloat, padding: CGFloat) -> CGFloat {
        inner + padding
    }
}

/// Tactile press: scale to 0.96 (never below 0.95 — anything smaller feels exaggerated).
struct PressScaleButtonStyle: ButtonStyle {
    var enabled = true

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(enabled && configuration.isPressed ? 0.96 : 1)
            .animation(PMMotion.interactive, value: configuration.isPressed)
    }
}

extension View {
    /// Enlarge the interactive hit region without changing layout size.
    ///
    /// Positive padding + `contentShape` expands hit testing; negative padding
    /// cancels the layout growth so parents (search HStacks, dense rows) don't
    /// jump when the control appears. `extra` is half the padding on each side
    /// (≈ total hit ≈ visual + 2×extra).
    func pmHitTarget(extra: CGFloat = 8) -> some View {
        self
            .padding(extra)
            .contentShape(Rectangle())
            .padding(-extra)
    }

    /// Soft layered elevation for cards/popovers. Depth comes from dual
    /// shadows (ambient + contact); a hairline pure primary ring at 6–8%
    /// stands in for CSS `box-shadow: 0 0 0 1px` since SwiftUI has no spread.
    /// Layout separators stay as `Divider` / `.separator` — not this helper.
    func pmCardElevation(cornerRadius: CGFloat, intense: Bool = false) -> some View {
        self
            .shadow(color: .black.opacity(intense ? 0.18 : 0.10),
                    radius: intense ? 18 : 8, y: intense ? 8 : 3)
            .shadow(color: .black.opacity(intense ? 0.08 : 0.04),
                    radius: intense ? 3 : 1.5, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(Color.primary.opacity(intense ? 0.08 : 0.06), lineWidth: 0.5)
            }
    }

    /// Neutral 1px image outline. `Color.primary` at 10% is pure black in light
    /// mode and pure white in dark — never a tinted slate/zinc that dirties edges.
    func pmImageOutline(cornerRadius: CGFloat = 0) -> some View {
        self.overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        }
    }
}

extension ToolbarContent {
    /// Hide the macOS 26 liquid-glass shared capsule on a toolbar item so
    /// adjacent controls don't merge into one pill that lights up on scroll.
    /// No-op on earlier OSes (deployment target is 14).
    @ToolbarContentBuilder
    func pmHideSharedBackground() -> some ToolbarContent {
        if #available(macOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
    }
}

/// Notion Mail-style switch: a proper pill, larger than the AppKit default.
struct NotionSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                Capsule()
                    .fill(configuration.isOn ? Color.notionAccent : Color.secondary.opacity(0.3))
                    .frame(width: 36, height: 21)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(.white)
                            .frame(width: 17, height: 17)
                            .padding(2)
                            .shadow(radius: 1)
                    }
                    // Expand hit without growing the 36×21 layout footprint.
                    .pmHitTarget(extra: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.12), value: configuration.isOn)
    }
}

/// Notion Mail-style inline search field: magnifier + plain text field on a
/// subtle rounded background, clear button when non-empty. `compact` is the
/// smaller variant for tight spots like the compose snippets panel.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var compact = false
    /// Optional external focus binding so callers can move keyboard focus into
    /// the field programmatically (e.g. Gmail's `/`).
    var focused: FocusState<Bool>.Binding? = nil
    /// Expanded look while the field is active (accent ring, brighter fill,
    /// roomier padding) so the search target is unmistakable when focused.
    var emphasized = false
    var onSubmit: () -> Void = {}

    var body: some View {
        HStack(spacing: compact ? 4 : 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: compact ? 9 : 12)).foregroundStyle(.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(compact ? .system(size: 11.5) : .body)
                .onSubmit(onSubmit)
                .focused(optional: focused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: compact ? 9 : 11)).foregroundStyle(.secondary)
                        // Hit expands; layout stays icon-sized so the field doesn't jump.
                        .pmHitTarget(extra: compact ? 6 : 8)
                }
                .buttonStyle(PressScaleButtonStyle())
                .help("Clear")
            }
        }
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : (emphasized ? 7 : 5))
        .background(Color.primary.opacity(emphasized ? 0.09 : 0.06),
                    in: RoundedRectangle(cornerRadius: compact ? PMRadius.xs + 1 : PMRadius.sm))
        .overlay {
            if emphasized {
                RoundedRectangle(cornerRadius: compact ? PMRadius.xs + 1 : PMRadius.sm)
                    .strokeBorder(Color.notionAccent.opacity(0.7), lineWidth: 1.5)
            }
        }
        .animation(.easeOut(duration: 0.08), value: emphasized)
    }
}

extension View {
    /// Applies `.focused` only when a binding is supplied, so a view can accept
    /// an optional focus binding without duplicating its body.
    @ViewBuilder
    func focused(optional binding: FocusState<Bool>.Binding?) -> some View {
        if let binding {
            focused(binding)
        } else {
            self
        }
    }
}

/// Notion Mail-style checkbox: bigger rounded square with a bold check.
struct NotionCheckStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 8) {
                // Visible box stays 18×18. The whole row is the hit target via
                // contentShape below — no layout-inflating frame on the box.
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Color.notionAccent : Color.secondary.opacity(0.18))
                    .frame(width: 18, height: 18)
                    .overlay {
                        // Keep the check in the tree so enter/exit can animate
                        // (opacity + scale only — blur is costly for list rows).
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .opacity(configuration.isOn ? 1 : 0)
                            .scaleEffect(configuration.isOn ? 1 : 0.25)
                    }
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.15), value: configuration.isOn)
    }
}
