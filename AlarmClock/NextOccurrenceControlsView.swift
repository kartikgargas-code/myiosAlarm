import SwiftUI
import AlarmClockShared

struct NextOccurrenceControlsView: View {
    let alarm: AlarmRecord
    let coordinator: AlarmCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var customDate = Date.now.addingTimeInterval(600)

    private var occurrence: AlarmOccurrence? {
        coordinator.occurrence(for: alarm.id)
    }

    private var skippedOccurrence: AlarmOccurrence? {
        let now = Date()
        let overrides = alarm.overrides
        for (key, override) in overrides where override.isSkipped {
            let calendar = Calendar.autoupdatingCurrent
            let components = key.split(separator: "-").compactMap { Int($0) }
            guard components.count == 3 else { continue }
            var dateComponents = DateComponents()
            dateComponents.calendar = calendar
            dateComponents.timeZone = calendar.timeZone
            dateComponents.year = components[0]
            dateComponents.month = components[1]
            dateComponents.day = components[2]
            dateComponents.hour = alarm.time.hour
            dateComponents.minute = alarm.time.minute
            if let baseDate = calendar.date(from: dateComponents), baseDate > now {
                return AlarmOccurrence(
                    alarmID: alarm.id,
                    occurrenceKey: key,
                    baseDate: baseDate,
                    effectiveDate: baseDate,
                    isAdjusted: false
                )
            }
        }
        return nil
    }

    var body: some View {
        let colors = ThemeManager.shared.colors

        NavigationStack {
            Form {
                if let occurrence {
                    Section("Next Occurrence") {
                        LabeledContent("Permanent", value: occurrence.baseDate.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Effective", value: occurrence.effectiveDate.formatted(date: .abbreviated, time: .shortened))
                        if occurrence.isAdjusted {
                            LabeledContent("Adjustment", value: adjustmentDescription(occurrence))
                        }
                    }

                    Section("Adjustment") {
                        HStack(spacing: 12) {
                            Button {
                                Task { await coordinator.adjustNext(id: alarm.id, minutes: -10) }
                            } label: {
                                Text("−10")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task { await coordinator.resetNext(id: alarm.id) }
                            } label: {
                                Text("Reset")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)

                            Button {
                                Task { await coordinator.adjustNext(id: alarm.id, minutes: 10) }
                            } label: {
                                Text("+10")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                        }

                        DatePicker("Custom Time", selection: $customDate, in: Date.now...)
                        Button("Apply Custom Time") {
                            Task { await coordinator.setNextTime(id: alarm.id, date: customDate) }
                        }
                        .buttonStyle(.bordered)

                        if let skipped = skippedOccurrence {
                            Section("Skipped Occurrence") {
                                Text("This occurrence is skipped: \(skipped.baseDate.formatted(date: .abbreviated, time: .shortened))")
                                    .foregroundStyle(colors.accent)
                                Button("Undo Skip") {
                                    Task { await coordinator.undoSkip(id: alarm.id) }
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Button("Skip Next", role: .destructive) {
                                Task { await coordinator.skipNext(id: alarm.id) }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No Upcoming Occurrence", systemImage: "alarm.waves.left.and.right.slash")
                    if let skipped = skippedOccurrence {
                        Text("Skipped: \(skipped.baseDate.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(colors.accent)
                        Button("Undo Skip") {
                            Task { await coordinator.undoSkip(id: alarm.id) }
                        }
                        .buttonStyle(.bordered)
                    }
                }

                if let error = coordinator.lastError {
                    Section("Scheduling Error") {
                        Text(error).foregroundStyle(colors.destructive)
                    }
                }
            }
            .navigationTitle(alarm.label.isEmpty ? "Alarm" : alarm.label)
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
            }
            .onAppear {
                if let occurrence {
                    customDate = occurrence.effectiveDate
                }
            }
        }
    }

    private func adjustmentDescription(_ occurrence: AlarmOccurrence) -> String {
        let minutes = Int(occurrence.effectiveDate.timeIntervalSince(occurrence.baseDate) / 60)
        return minutes >= 0 ? "+\(minutes) minutes" : "\(minutes) minutes"
    }
}
