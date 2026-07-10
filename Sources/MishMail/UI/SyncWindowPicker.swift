import SwiftUI

/// How far back mail is downloaded, per account. Changing it triggers a sync
/// right away: widening backfills older mail, narrowing removes local copies
/// outside the window (Gmail is untouched), and "Nothing" removes all of the
/// account's mail from this Mac. SyncEngine reads the same key.
struct SyncWindowPicker: View {
    @EnvironmentObject var store: MailStore
    let accountId: String
    @State private var days: Int

    init(accountId: String) {
        self.accountId = accountId
        _days = State(initialValue: SyncEngine.syncWindowDays(for: accountId))
    }

    var body: some View {
        Picker("Keep mail from", selection: $days) {
            Text("Last 30 days").tag(30)
            Text("Last 90 days").tag(90)
            Text("Last year").tag(365)
            Text("Last 3 years").tag(1095)
            Text("Everything").tag(0)
            Divider()
            Text("Nothing (remove from this Mac)").tag(SyncEngine.windowNothing)
        }
        .onChange(of: days) {
            UserDefaults.standard.set(days, forKey: "syncWindowDays.\(accountId)")
            Task { await store.sync(accountId: accountId) }
        }
    }
}
