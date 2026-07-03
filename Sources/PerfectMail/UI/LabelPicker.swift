import SwiftUI

/// Gmail-style "l" label picker for the selected thread: type to filter,
/// Enter or click to toggle, Esc to close.
struct LabelPicker: View {
    @EnvironmentObject var store: MailStore
    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { store.showLabelPicker = false }

            if let thread = store.selectedThread {
                VStack(spacing: 0) {
                    TextField("Label as…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(12)
                        .focused($focused)
                        .onSubmit {
                            if let label = filtered(for: thread)[safe: highlighted] {
                                store.toggleLabel(thread, labelId: label.gmailLabelId)
                            }
                        }
                        .onChange(of: query) { highlighted = 0 }
                    Divider()
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(filtered(for: thread).enumerated()), id: \.element.id) { idx, label in
                                let applied = thread.labels.contains(label.gmailLabelId)
                                HStack(spacing: 8) {
                                    Image(systemName: applied ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(applied ? Color.accentColor : .secondary)
                                    Circle().fill(Color.stable(for: label.name))
                                        .frame(width: 8, height: 8)
                                    Text(label.name).font(.system(size: 13))
                                    Spacer()
                                }
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(idx == highlighted ? Color.accentColor.opacity(0.18) : .clear)
                                .contentShape(Rectangle())
                                .onTapGesture { store.toggleLabel(thread, labelId: label.gmailLabelId) }
                                .onHover { if $0 { highlighted = idx } }
                            }
                            if filtered(for: thread).isEmpty {
                                Text("No labels").font(.caption).foregroundStyle(.secondary)
                                    .padding(12)
                            }
                        }
                    }
                    .frame(maxHeight: 260)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(width: 380)
                .shadow(radius: 24)
                .padding(.top, 130)
                .onAppear { focused = true }
                .onKeyPress(.downArrow) {
                    highlighted = min(highlighted + 1, filtered(for: thread).count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlighted = max(highlighted - 1, 0)
                    return .handled
                }
            }
        }
    }

    private func filtered(for thread: MailThread) -> [LabelRow] {
        let labels = store.userLabels(forAccount: thread.accountId)
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return labels }
        return labels.filter { $0.name.lowercased().contains(q) }
    }
}
