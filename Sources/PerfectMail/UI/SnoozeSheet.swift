import SwiftUI

/// Gmail-style snooze picker: one-click presets, an exact date & time
/// fallback, and Unsnooze when the thread is already sleeping.
/// Passing nil to `snooze` unsnoozes.
struct SnoozeSheet: View {
    @Environment(\.dismiss) private var dismiss
    let current: Date?
    let snooze: (Date?) -> Void

    @State private var date = MailStore.snoozeDate(hour: 8, addDays: 1)
    @State private var showCustom = false

    private static func nextWeekday(_ weekday: Int, hour: Int) -> Date {
        let cal = Calendar.current
        let day = cal.nextDate(after: Date(), matching: DateComponents(weekday: weekday),
                               matchingPolicy: .nextTime)!
        return cal.date(bySettingHour: hour, minute: 0, second: 0, of: day)!
    }

    private var presets: [(String, Date)] {
        var list: [(String, Date)] = []
        let evening = MailStore.snoozeDate(hour: 18)
        if evening > Date() { list.append(("This evening", evening)) }
        list.append(("Tomorrow morning", MailStore.snoozeDate(hour: 8, addDays: 1)))
        list.append(("This weekend", Self.nextWeekday(7, hour: 8)))   // Saturday
        list.append(("Next week", Self.nextWeekday(2, hour: 8)))      // Monday
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Snooze until")
                .font(.system(size: 13, weight: .semibold))

            VStack(spacing: 2) {
                ForEach(presets, id: \.0) { name, when in
                    Button {
                        snooze(when)
                        dismiss()
                    } label: {
                        HStack {
                            Text(name).font(.system(size: 13))
                            Spacer()
                            Text(when.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.001))  // keep hit area
                }
            }

            Divider()

            DisclosureGroup("Pick date & time", isExpanded: $showCustom) {
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
                    Button("Snooze") {
                        snooze(date)
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(date <= Date())
                }
            }
            .font(.system(size: 13))

            Divider()

            HStack {
                if let current {
                    Text("Snoozed until \(current.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Unsnooze") {
                        snooze(nil)
                        dismiss()
                    }
                } else {
                    Spacer()
                }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
