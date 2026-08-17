import SwiftUI

/// Suggested-replies strip inside the compose card. Lives where the reply is
/// written (not pinned under the thread), names the model that produced the
/// suggestions, and streams chips in as each line completes so the wait never
/// looks like a dead button.
struct SuggestedRepliesStrip: View {
    let suggestions: [String]
    let loading: Bool
    /// Model that produces the suggestions (from the triage task assignment).
    let modelName: String?
    let error: String?
    var pick: (String) -> Void
    var regenerate: () -> Void
    var dismiss: () -> Void

    private static let slotCount = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                chips
            }
        }
        .padding(10)
        // Concentric with the 6pt chips inside (6 + 10 padding = 16 outer).
        .background(Color.secondary.opacity(0.06),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .animation(.spring(duration: 0.3, bounce: 0), value: suggestions)
        .animation(.spring(duration: 0.3, bounce: 0), value: loading)
    }

    private var header: some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.notionAccent)
            Text("Suggested replies")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            if let modelName {
                Text("· \(modelName)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help("Change the model in Settings → AI → Model per task → Triage")
            }
            if loading {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.leading, 2)
            }
            Spacer(minLength: 8)
            if !loading {
                Button(action: regenerate) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Suggest again")
                .accessibilityLabel("Regenerate suggested replies")
            }
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Hide suggestions")
            .accessibilityLabel("Hide suggested replies")
        }
    }

    private var chips: some View {
        // Wrap-free single row: chips truncate to share the card's width.
        HStack(spacing: 8) {
            ForEach(suggestions.prefix(Self.slotCount), id: \.self) { reply in
                Button {
                    pick(reply)
                } label: {
                    Text(reply)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(PressScaleButtonStyle())
                .help(reply)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
            if loading {
                ForEach(0..<max(0, Self.slotCount - suggestions.count), id: \.self) { _ in
                    placeholderChip
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholderChip: some View {
        Capsule()
            .fill(Color.secondary.opacity(0.08))
            .frame(width: 92, height: 26)
            .modifier(SuggestedReplyShimmer())
            .transition(.opacity)
    }
}

/// Gentle opacity pulse so loading placeholders read as "working", not stuck.
private struct SuggestedReplyShimmer: ViewModifier {
    @State private var dim = false
    func body(content: Content) -> some View {
        content
            .opacity(dim ? 0.45 : 1)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}
