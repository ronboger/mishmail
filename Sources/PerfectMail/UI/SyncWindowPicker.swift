import SwiftUI

/// How far back mail is downloaded. Widening triggers a background backfill
/// on the next sync; SyncEngine reads the same key.
struct SyncWindowPicker: View {
    @AppStorage("syncWindowDays") private var syncWindowDays = 90

    var body: some View {
        Picker("Download mail from", selection: $syncWindowDays) {
            Text("Last 90 days").tag(90)
            Text("Last year").tag(365)
            Text("Last 3 years").tag(1095)
            Text("Everything").tag(0)
        }
    }
}
