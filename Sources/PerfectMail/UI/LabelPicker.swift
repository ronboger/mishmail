import SwiftUI

/// Gmail-style "l" label picker for the selected thread: type to filter,
/// up/down to move, Enter/Space or click to toggle, Esc to close.
/// (Space only toggles after arrow navigation; while typing it stays a
/// literal space so multi-word label names remain searchable.)
///
/// The highlight index lives in MailStore and is driven by the window-level
/// key monitor in ContentView — the text field's field editor consumes arrow
/// key events before SwiftUI's onKeyPress ever sees them, so handling arrows
/// here doesn't work while the field is focused.
struct LabelPicker: View {
    @EnvironmentObject var store: MailStore
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { store.showLabelPicker = false }

            if let thread = store.selectedThread {
                let labels = store.labelPickerLabels(for: thread)
                // The "Create …" row sits after the matches and is reachable
                // with the same up/down highlight.
                let createName = store.labelPickerCreateName(for: thread)
                let rowCount = labels.count + (createName != nil ? 1 : 0)
                let highlighted = min(store.labelPickerHighlight, max(rowCount - 1, 0))
                VStack(spacing: 0) {
                    TextField("Label as…", text: $store.labelPickerQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .padding(12)
                        .focused($focused)
                        .onSubmit {
                            if let label = labels[safe: highlighted] {
                                store.toggleLabel(thread, labelId: label.gmailLabelId)
                            } else if let createName {
                                store.createLabelAndApply(name: createName, thread: thread)
                            }
                        }
                        .onChange(of: store.labelPickerQuery) { store.labelPickerHighlight = 0 }
                    if store.accounts.count > 1 {
                        Text(thread.accountId)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.bottom, 6)
                    }
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
                                if let createName {
                                    HStack(spacing: 8) {
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(highlighted == labels.count ? Color.notionAccent : .secondary)
                                        Text("Create “\(createName)”").font(.system(size: 13))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(highlighted == labels.count ? Color.notionAccent.opacity(0.18) : .clear)
                                    .contentShape(Rectangle())
                                    .onTapGesture { store.createLabelAndApply(name: createName, thread: thread) }
                                    .onHover { if $0 { store.labelPickerHighlight = labels.count } }
                                    .id(labels.count)
                                }
                                if labels.isEmpty, createName == nil {
                                    Text("No labels in \(thread.accountId)").font(.caption).foregroundStyle(.secondary)
                                        .padding(12)
                                }
                                // A matching label on another account can't be
                                // applied here — say so instead of silently
                                // dropping it from the results.
                                if let other = store.labelPickerOtherAccountMatch(excluding: thread.accountId) {
                                    Text("“\(other.name)” is a label in \(other.accountId) — labels apply per account")
                                        .font(.caption).foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                }
                            }
                        }
                        .frame(maxHeight: 260)
                        .onChange(of: store.labelPickerHighlight) {
                            // Keep the monitor-driven index in bounds and visible.
                            if store.labelPickerHighlight > max(rowCount - 1, 0) {
                                store.labelPickerHighlight = max(rowCount - 1, 0)
                            }
                            proxy.scrollTo(store.labelPickerHighlight, anchor: .center)
                        }
                    }
                    Divider()
                    // Spell out the keyboard model: what Enter will do depends
                    // on the highlighted row.
                    let enterVerb: String = {
                        if let label = labels[safe: highlighted] {
                            return thread.labels.contains(label.gmailLabelId) ? "remove" : "add"
                        }
                        return createName != nil ? "create" : "add"
                    }()
                    HStack(spacing: 10) {
                        Text("↑↓ select")
                        Text("⏎ \(enterVerb)")
                        Text("␣ toggle")
                        Text("esc close")
                        Spacer()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(width: 380)
                .shadow(radius: 24)
                .padding(.top, 130)
                .onAppear { focused = true }
            }
        }
    }
}
