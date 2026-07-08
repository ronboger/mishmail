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
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, compact ? 6 : 7)
        .padding(.vertical, compact ? 3 : (emphasized ? 7 : 5))
        .background(Color.primary.opacity(emphasized ? 0.09 : 0.06),
                    in: RoundedRectangle(cornerRadius: compact ? 5 : 6))
        .overlay {
            if emphasized {
                RoundedRectangle(cornerRadius: compact ? 5 : 6)
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
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isOn ? Color.notionAccent : Color.secondary.opacity(0.18))
                    .frame(width: 18, height: 18)
                    .overlay {
                        if configuration.isOn {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                configuration.label
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.1), value: configuration.isOn)
    }
}
