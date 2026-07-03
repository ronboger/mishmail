import SwiftUI

// MARK: - Schedule send

/// Notion Mail-style "send later" picker: presets with their concrete
/// times, plus a custom date & time page.
struct SchedulePopover: View {
    let schedule: (Date) -> Void

    @State private var showCustom = false
    @State private var customDate = SendSchedule.tomorrowMorning.date()

    var body: some View {
        Group {
            if showCustom { customPage } else { presetsPage }
        }
        .frame(width: 264)
    }

    private var presetsPage: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Schedule send")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

            ForEach(SendSchedule.allCases, id: \.self) { preset in
                let date = preset.date()
                PopoverRow(action: { schedule(date) }) {
                    Image(systemName: "clock")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text(preset.title)
                        .font(.system(size: 12.5))
                    Spacer()
                    Text(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().padding(.vertical, 4)

            PopoverRow(action: { showCustom = true }) {
                Image(systemName: "calendar")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Pick date & time…")
                    .font(.system(size: 12.5))
                Spacer()
            }

            Text("Sends while PerfectMail is open")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 8)
        }
        .padding(.horizontal, 4)
    }

    private var customPage: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button {
                    showCustom = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Text("Pick date & time")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
            }

            DatePicker("", selection: $customDate, in: Date()...,
                       displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()

            HStack {
                Text("Time")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                DatePicker("", selection: $customDate,
                           displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
                Button("Schedule") { schedule(customDate) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(customDate <= Date())
            }
        }
        .padding(12)
    }
}

// MARK: - Snippets

/// Searchable snippet picker: name + first-line preview, click to insert.
struct SnippetsPopover: View {
    @EnvironmentObject var store: MailStore
    @Environment(\.dismiss) private var dismiss

    let insert: (Snippet) -> Void
    let saveDraftAsSnippet: () -> Void

    @State private var query = ""

    private var snippets: [Snippet] { store.snippets() }
    private var filtered: [Snippet] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return snippets }
        return snippets.filter {
            $0.name.localizedCaseInsensitiveContains(q)
                || $0.body.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Snippets")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)

            if snippets.count > 5 {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("Search snippets", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 6).padding(.bottom, 4)
            }

            if snippets.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("No snippets yet")
                        .font(.system(size: 12.5, weight: .medium))
                    Text("Save reusable text — a sign-off, an intro,\na scheduling reply — and insert it anywhere.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            } else if filtered.isEmpty {
                Text("No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { snippet in
                            PopoverRow(action: { insert(snippet); dismiss() }) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(snippet.name)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .lineLimit(1)
                                    Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            Divider().padding(.vertical, 4)

            PopoverRow(action: { dismiss(); saveDraftAsSnippet() }) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Text("Save draft as snippet…")
                    .font(.system(size: 12.5))
                Spacer()
            }
            SettingsLink {
                HStack(spacing: 6) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                    Text("Manage snippets…")
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(PopoverRowButtonStyle())
            .padding(.bottom, 6)
        }
        .padding(.horizontal, 4)
        .frame(width: 280)
    }
}

// MARK: - Shared row chrome

/// A popover menu row: plain button with a hover highlight.
struct PopoverRow<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { content }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .contentShape(Rectangle())
        }
        .buttonStyle(PopoverRowButtonStyle())
    }
}

struct PopoverRowButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background((hovering || configuration.isPressed) ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
    }
}
