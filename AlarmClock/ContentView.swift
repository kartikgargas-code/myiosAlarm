import SwiftUI

struct ContentView: View {
    @State private var authorizationModel = AlarmProofOfConceptModel()
    @State private var coordinator = AlarmCoordinator()
    @State private var editorAlarm: AlarmRecord?
    @State private var showingEditor = false
    @State private var controlsAlarm: AlarmRecord?
    @State private var showingDiagnostics = false

    var body: some View {
        NavigationStack {
            List {
                if authorizationModel.authorizationDescription != "Authorized" {
                    authorizationSection
                }

                if let next = coordinator.nextOccurrence,
                   let alarm = coordinator.alarms.first(where: { $0.id == next.alarmID }) {
                    nextAlarmSection(alarm: alarm, occurrence: next)
                }

                Section("Alarms") {
                    if coordinator.alarms.isEmpty {
                        ContentUnavailableView("No Alarms", systemImage: "alarm", description: Text("Tap + to create one."))
                    }
                    ForEach(coordinator.alarms) { alarm in
                        alarmRow(alarm)
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            let id = coordinator.alarms[offset].id
                            Task { await coordinator.delete(id: id) }
                        }
                    }
                }

                if let error = coordinator.lastError {
                    Section("Scheduling Error") {
                        Text(error).foregroundStyle(.red)
                    }
                }

                Section {
                    Button("AlarmKit Diagnostics") { showingDiagnostics = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.black)
            .navigationTitle("Alarm Clock")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        editorAlarm = nil
                        showingEditor = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                AlarmEditorView(existingAlarm: editorAlarm) { alarm in
                    await coordinator.save(alarm)
                }
            }
            .sheet(item: $controlsAlarm) { alarm in
                NextOccurrenceControlsView(
                    alarm: alarm,
                    coordinator: coordinator
                )
            }
            .sheet(isPresented: $showingDiagnostics) {
                diagnosticsView
            }
            .task {
                if authorizationModel.authorizationDescription == "Authorized" {
                    await coordinator.synchronize()
                }
            }
        }
        .tint(.orange)
    }

    private var authorizationSection: some View {
        Section("Alarm Access") {
            Text("Authorization: \(authorizationModel.authorizationDescription)")
            Button("Request Alarm Access") {
                Task {
                    await authorizationModel.authorizationButtonTapped()
                    if authorizationModel.authorizationDescription == "Authorized" {
                        await coordinator.synchronize()
                    }
                }
            }
        }
    }

    private func nextAlarmSection(alarm: AlarmRecord, occurrence: AlarmOccurrence) -> some View {
        Section("Next Alarm") {
            Button {
                controlsAlarm = alarm
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(occurrence.effectiveDate.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 42, weight: .medium))
                        .foregroundStyle(.primary)
                    Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                        .font(.headline)
                    if occurrence.isAdjusted {
                        Text("Normally \(occurrence.baseDate.formatted(date: .omitted, time: .shortened)) · \(adjustmentDescription(occurrence))")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
        }
    }

    private func alarmRow(_ alarm: AlarmRecord) -> some View {
        HStack {
            Button {
                editorAlarm = alarm
                showingEditor = true
            } label: {
                VStack(alignment: .leading) {
                    Text(timeText(alarm.time))
                        .font(.title2)
                        .foregroundStyle(.primary)
                    Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                        .foregroundStyle(.primary)
                    Text(alarm.repeatRule.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let occurrence = coordinator.occurrence(for: alarm.id), occurrence.isAdjusted {
                        Text("Next: \(occurrence.effectiveDate.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                controlsAlarm = alarm
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(.borderless)

            Toggle("Enabled", isOn: Binding(
                get: { alarm.isEnabled },
                set: { enabled in Task { await coordinator.setEnabled(enabled, id: alarm.id) } }
            ))
            .labelsHidden()
        }
    }

    private var diagnosticsView: some View {
        NavigationStack {
            ScrollView {
                Text(authorizationModel.diagnosticsText)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy") { authorizationModel.copyDiagnostics() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingDiagnostics = false }
                }
            }
        }
    }

    private func timeText(_ time: AlarmTime) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func adjustmentDescription(_ occurrence: AlarmOccurrence) -> String {
        let minutes = Int(occurrence.effectiveDate.timeIntervalSince(occurrence.baseDate) / 60)
        return minutes >= 0 ? "Adjusted +\(minutes) minutes" : "Adjusted \(minutes) minutes"
    }
}
