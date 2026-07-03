import SwiftUI

/// Create/edit a custom saved view (Notion Mail-style).
struct ViewEditor: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State var view: SavedView

    private let categories: [(String?, String)] = [
        (nil, "Any"),
        ("CATEGORY_PROMOTIONS", "Promotions"),
        ("CATEGORY_SOCIAL", "Social"),
        ("CATEGORY_UPDATES", "Updates"),
        ("CATEGORY_FORUMS", "Forums"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("View name", text: $view.name)

                Picker("Account", selection: $view.accountId) {
                    Text("All accounts").tag(String?.none)
                    ForEach(store.accounts) { Text($0.id).tag(String?.some($0.id)) }
                }

                Picker("Label", selection: $view.labelId) {
                    Text("Any").tag(String?.none)
                    ForEach(allLabels, id: \.gmailLabelId) { label in
                        Text(label.name).tag(String?.some(label.gmailLabelId))
                    }
                }

                Picker("Category", selection: $view.category) {
                    ForEach(categories, id: \.0) { value, name in
                        Text(name).tag(value)
                    }
                }

                TextField("From contains", text: $view.senderContains, prompt: Text("e.g. angellist.com or Rohan"))

                Toggle("Unread only", isOn: $view.unreadOnly)
                Toggle("Starred only", isOn: $view.starredOnly)
                Toggle("Has attachment", isOn: $view.hasAttachmentOnly)
                Toggle("Include archived", isOn: $view.showArchived)
                Toggle("Exclude Promotions & Social", isOn: $view.excludePromotions)
            }
            .formStyle(.grouped)

            HStack {
                if view.id != nil {
                    Button("Delete", role: .destructive) {
                        store.deleteView(view)
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save View") {
                    store.saveView(view)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(view.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
    }

    private var allLabels: [LabelRow] {
        let labels = store.labelsByAccount.values.flatMap { $0 }
        var seen = Set<String>()
        return labels.filter { seen.insert($0.gmailLabelId).inserted }.sorted { $0.name < $1.name }
    }
}
