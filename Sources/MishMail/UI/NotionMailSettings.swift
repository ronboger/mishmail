import SwiftUI
import UniformTypeIdentifiers

/// Settings pane for people leaving Notion Mail before the 22 Sep 2026 shutdown.
struct NotionMailSettings: View {
    @Environment(MailStore.self) var store
    @State private var showImporter = false
    @State private var importResult: String?

    static let notionHelpURL = URL(
        string: "https://www.notion.com/help/notion-mail-inbox-is-going-away-what-to-do-next")!

    var body: some View {
        PaneScaffold(
            title: "Moving from Notion Mail",
            subtitle: "Notion Mail shuts down 22 Sep 2026. Your Gmail history stays. Import the pieces that live only in Notion Mail."
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    callout

                    section("1. Save Notion-only data first") {
                        Text("In Notion Mail, export before 21 Sep 2026. Mail already in Gmail does not need an export.")
                        labeled("Drafts") {
                            Text("Use Notion’s “migrate to Gmail” so unsent drafts land in Gmail Drafts. MishMail syncs those on the next poll.")
                        }
                        labeled("Scheduled send") {
                            Text("Migrate scheduled mail to Gmail, or recreate it in MishMail with Send later after you import the draft.")
                        }
                        labeled("Snippets") {
                            Text("Export snippets from Notion Mail → Settings → Snippets. Import the JSON or CSV below. Files attached to a snippet are not in the export — download those by hand.")
                        }
                        labeled("Auto-label instructions") {
                            Text("Export the instructions to a Notion page. Recreate them here as saved views, Gmail filters, or AI triage. MishMail does not run Notion’s auto-label model.")
                        }
                        labeled("Reminders") {
                            Text("Notion Mail reminders do not transfer. MishMail has local follow-up reminders on a conversation (Reminders in the sidebar).")
                        }
                        labeled("Custom views") {
                            Text("Inbox layout does not transfer. Rebuild filters as saved views (sidebar + View editor, or “Split from Inbox”).")
                        }
                        Link("Notion’s shutdown guide", destination: Self.notionHelpURL)
                    }

                    section("2. Import snippets") {
                        Text("MishMail accepts Notion’s snippet export and MishMail’s own JSON. Type / in compose to insert a snippet, the same slash trigger as Notion Mail.")
                        HStack(spacing: 10) {
                            Button("Import snippets…") { showImporter = true }
                                .buttonStyle(.borderedProminent)
                            if let importResult {
                                Text(importResult)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        Text("JSON array, { \"snippets\": […] }, or CSV with name/shortcut and body/content columns.")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }

                    section("3. Connect Gmail in MishMail") {
                        Text("Paste your own Desktop OAuth client under Google API, then add the same Google account you used in Notion Mail. MishMail talks only to Google’s API for mail.")
                    }
                }
                .padding(20)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json, .commaSeparatedText, .tabSeparatedText, .plainText]
            ) { result in
                if let msg = SnippetFileImport.apply(result, store: store) {
                    importResult = msg
                }
            }
        }
    }

    private var callout: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.right.doc.on.clipboard")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.notionAccent)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Highest-value move: bring your snippets")
                    .font(.system(size: 13, weight: .semibold))
                Text("Slash snippets, variables like {first_name}, and move-to-Bcc work the same way. Import once; they stay on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.notionAccent.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: PMRadius.md))
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold))
            content()
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            content()
        }
        .padding(.leading, 2)
    }
}

enum SnippetFileImport {
    @MainActor
    static func apply(_ result: Result<URL, Error>, store: MailStore) -> String? {
        switch result {
        case .success(let url):
            do {
                let counts = try store.importSnippets(from: url)
                var msg = counts.skipped == 0
                    ? "Imported \(counts.added)"
                    : "Imported \(counts.added), skipped \(counts.skipped)"
                if counts.unknownAccountIds > 0 {
                    msg += "; \(counts.unknownAccountIds) unknown account id"
                        + (counts.unknownAccountIds == 1 ? "" : "s")
                        + " (snippet hidden until fixed)"
                }
                if counts.added == 0, counts.skipped == 0 {
                    msg = "No snippets found in that file"
                }
                return msg
            } catch {
                return "Import failed: \(error.localizedDescription)"
            }
        case .failure:
            return nil
        }
    }
}
