import SwiftUI

/// Organize labels: drag to reorder and pick a color per label. The order and
/// colors are local (they don't touch Gmail) and drive the label pills, the
/// Labels filter dropdown, and the "l" picker everywhere in the app.
struct LabelOrganizer: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var selectedAccount: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Organize Labels")
                    .font(.headline)
                Spacer()
                // With more than one account, labels are scoped per account
                // (Gmail ids don't cross accounts).
                if store.accounts.count > 1 {
                    Picker("", selection: $selectedAccount) {
                        ForEach(store.accounts) { account in
                            Text(account.displayName).tag(String?.some(account.id))
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            Text("Drag to reorder. Click a swatch to recolor. Order and colors are local — Gmail isn't changed.")
                .font(.system(size: 11.5)).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 8)

            Divider()

            let account = resolvedAccount
            let labels = account.map { store.userLabels(forAccount: $0) } ?? []
            if labels.isEmpty {
                ContentUnavailableView("No labels",
                                       systemImage: "tag",
                                       description: Text("Labels you create in Gmail show up here."))
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List {
                    ForEach(labels, id: \.id) { label in
                        LabelOrganizerRow(label: label)
                    }
                    .onMove { source, destination in
                        if let account {
                            store.reorderLabels(account: account, from: source, to: destination)
                        }
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 260)
            }

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 420, height: 480)
        .onAppear {
            if selectedAccount == nil {
                selectedAccount = store.activeAccountId ?? store.accounts.first?.id
            }
        }
    }

    private var resolvedAccount: String? {
        selectedAccount ?? store.activeAccountId ?? store.accounts.first?.id
    }
}

/// One organizer row: a color swatch (opens a palette), the label name, and a
/// drag handle courtesy of List's move support.
private struct LabelOrganizerRow: View {
    @EnvironmentObject var store: MailStore
    let label: LabelRow
    @State private var showPalette = false

    var body: some View {
        HStack(spacing: 10) {
            Button { showPalette = true } label: {
                Circle()
                    .fill(store.labelTint(label.name, account: label.accountId))
                    .frame(width: 18, height: 18)
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showPalette, arrowEdge: .bottom) {
                LabelColorPalette(label: label) { showPalette = false }
            }

            Text(label.name).font(.system(size: 13))
            Spacer()
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}

/// The color grid shown when picking a label's color, plus a "default" reset
/// that falls back to the name-stable color.
private struct LabelColorPalette: View {
    @EnvironmentObject var store: MailStore
    let label: LabelRow
    let onPick: () -> Void

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 8), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Color").font(.system(size: 12, weight: .semibold))
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Color.labelPalette, id: \.hex) { swatch in
                    Button {
                        store.setLabelColor(label, hex: swatch.hex)
                        onPick()
                    } label: {
                        Circle()
                            .fill(Color.hexString(swatch.hex) ?? .gray)
                            .frame(width: 24, height: 24)
                            .overlay {
                                if label.color?.caseInsensitiveCompare(swatch.hex) == .orderedSame {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(swatch.name)
                }
            }
            Divider()
            Button {
                store.setLabelColor(label, hex: nil)
                onPick()
            } label: {
                Label("Default color", systemImage: "arrow.uturn.backward")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .frame(width: 232)
    }
}
