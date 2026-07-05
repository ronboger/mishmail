import SwiftUI

/// Pick an exact date & time to snooze a thread until (mirrors the compose
/// schedule-send sheet). Snooze is local-only, like the presets.
struct SnoozeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let snooze: (Date) -> Void

    @State private var date = MailStore.snoozeDate(hour: 8, addDays: 1)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Snooze until")
                .font(.system(size: 13, weight: .semibold))

            DatePicker("", selection: $date, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack(spacing: 8) {
                Text("Time")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $date, displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
            }

            Divider()

            HStack {
                Text("Returns \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Snooze") {
                    snooze(date)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(date <= Date())
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
