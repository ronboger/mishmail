import SwiftUI

/// Gmail-style "l" label picker for the selected thread: type to filter,
/// up/down to move, Enter or click to toggle, Esc to close.
///
/// The highlight index lives in MailStore and is driven by the window-level
/// key monitor in ContentView — the text field's field editor consumes arrow
/// key events before SwiftUI's onKeyPress ever sees them, so handling arrows
/// here doesn't work while the field is focused.
struct LabelPicker: View {
    @EnvironmentObject var store: MailStore
    @State private var query = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { store.showLabelPicker = false }

            if let thread = store.selectedThread {
                let labels = filtered(for: thread)
                let highlighted = min(store.labelPickerHighlight, max(labels.count - 1, 0))
                VStack(spacing: 0) {
                    TextField("Label as…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(12)
                        .focused($focused)
                        .onSubmit {
                            if let label = labels[safe: highlighted] {
                                store.toggleLabel(thread, labelId: label.gmailLabelId)
                            }
                        }
                        .onChange(of: query) { store.labelPickerHighlight = 0 }
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(labels.enumerated()), id: \.element.id) { idx, label in
                                    let applied = thread.labels.contains(label.gmailLabelId)
                                    HStack(spacing: 8) {
                                        Image(systemName: applied ? "checkmark.square.fill" : "square")
                                            .foregroundStyle(applied ? Color.notionAccent : .secondary)
                                        Circle().fill(store.labelTint(label.name, account: label.accountId))
                                            .frame(width: 8, height: 8)
                                        Text(label.name).font(.system(size: 13))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(idx == highlighted ? Color.notionAccent.opacity(0.18) : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.toggleLabel(thread, labelId: label.gmailLabelId) }
                                    .onHover { if $0 { store.labelPickerHighlight = idx } }
                                    .id(idx)
                                }
                                if labels.isEmpty {
                                    Text("No labels").font(.caption).foregroundStyle(.secondary)
                                        .padding(12)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                        .onChange(of: store.labelPickerHighlight) {
                            // Keep the monitor-driven index in bounds and visible.
                            if store.labelPickerHighlight > max(labels.count - 1, 0) {
                                store.labelPickerHighlight = max(labels.count - 1, 0)
                            }
                            proxy.scrollTo(store.labelPickerHighlight, anchor: .center)
                        }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(width: 380)
                .shadow(radius: 24)
                .padding(.top, 130)
                .onAppear { focused = true }
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
