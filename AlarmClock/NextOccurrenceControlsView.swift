import SwiftUI

struct NextOccurrenceControlsView: View {
    let alarm: AlarmRecord
    let coordinator: AlarmCoordinator

    @Environment(\.dismiss) private var dismiss
    @State private var customDate = Date.now.addingTimeInterval(600)

    private var occurrence: AlarmOccurrence? {
        coordinator.occurrence(for: alarm.id)
    }

    var body: some View {
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
                        HStack {
                            Button("−\(alarm.adjustmentStepMinutes)") {
                                Task { await coordinator.adjustNext(id: alarm.id, minutes: -alarm.adjustmentStepMinutes) }
                            }
                            Spacer()
                            Button("Reset") {
                                Task { await coordinator.resetNext(id: alarm.id) }
                            }
                            Spacer()
                            Button("+\(alarm.adjustmentStepMinutes)") {
                                Task { await coordinator.adjustNext(id: alarm.id, minutes: alarm.adjustmentStepMinutes) }
                            }
                        }
                        DatePicker("Custom Time", selection: $customDate, in: Date.now...)
                        Button("Apply Custom Time") {
                            Task { await coordinator.setNextTime(id: alarm.id, date: customDate) }
                        }
                        Button("Skip Next", role: .destructive) {
                            Task { await coordinator.skipNext(id: alarm.id) }
                        }
                        Button("Undo Skip") {
                            Task { await coordinator.undoSkip(id: alarm.id) }
                        }
                    }
                } else {
                    ContentUnavailableView("No Upcoming Occurrence", systemImage: "alarm.waves.left.and.right.slash")
                    Button("Undo Skip") {
                        Task { await coordinator.undoSkip(id: alarm.id) }
                    }
                }

                if let error = coordinator.lastError {
                    Section("Scheduling Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(alarm.label.isEmpty ? "Alarm" : alarm.label)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
