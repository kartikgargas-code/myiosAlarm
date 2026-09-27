import SwiftUI

struct ContentView: View {
    @State private var authorizationModel = AlarmProofOfConceptModel()
    @State private var coordinator = AlarmCoordinator()
    @State private var editorAlarm: AlarmRecord?
    @State private var showingEditor = false
    @State private var controlsAlarm: AlarmRecord?
    @State private var showingDiagnostics = false
    @State private var showingAppearance = false

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
                        Text(error).foregroundStyle(ThemeManager.shared.colors.destructive)
                    }
                }

                Section {
                    Button("AlarmKit Diagnostics") { showingDiagnostics = true }
                    Button("Appearance") { showingAppearance = true }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
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
            .sheet(isPresented: $showingAppearance) {
                AppearanceView()
            }
            .task {
                if authorizationModel.authorizationDescription == "Authorized" {
                    await coordinator.synchronize()
                }
            }
        }
        .tint(ThemeManager.shared.colors.accent)
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
        let colors = ThemeManager.shared.colors
        let skippedOccurrence = skippedOccurrenceForAlarm(alarm)

        return Section("Next Alarm") {
            VStack(alignment: .leading, spacing: 8) {
                Text(occurrence.effectiveDate.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(colors.primaryText)
                Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                    .font(.headline)
                    .foregroundStyle(colors.primaryText)

                if occurrence.isAdjusted {
                    Text("Normally \(occurrence.baseDate.formatted(date: .omitted, time: .shortened)) · \(adjustmentDescription(occurrence))")
                        .foregroundStyle(colors.secondaryText)
                }

                if let skipped = skippedOccurrence {
                    Text("Skipped: \(skipped.baseDate.formatted(date: .abbreviated, time: .shortened))")
                        .foregroundStyle(colors.accent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
    }

    private func alarmRow(_ alarm: AlarmRecord) -> some View {
        let colors = ThemeManager.shared.colors
        let occurrence = coordinator.occurrence(for: alarm.id)
        let skippedOccurrence = skippedOccurrenceForAlarm(alarm)

        return HStack(spacing: 12) {
            Button {
                editorAlarm = alarm
                showingEditor = true
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeText(alarm.time))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.primaryText)
                    Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                        .font(.subheadline)
                        .foregroundStyle(colors.primaryText)
                    Text(alarm.repeatRule.displayName)
                        .font(.caption)
                        .foregroundStyle(colors.secondaryText)
                    if let occurrence {
                        HStack(spacing: 4) {
                            if let skipped = skippedOccurrence {
                                Label("Skipped", systemImage: "slash.circle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(colors.accent)
                            } else if occurrence.isAdjusted {
                                Label(adjustmentDescription(occurrence), systemImage: "clock.badge.checkmark.fill")
                                    .font(.caption2)
                                    .foregroundStyle(colors.accent)
                            } else {
                                Text("Next: \(occurrence.effectiveDate.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(colors.secondaryText)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                controlsAlarm = alarm
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundStyle(colors.secondaryText)
            }
            .buttonStyle(.borderless)

            Toggle("Enabled", isOn: Binding(
                get: { alarm.isEnabled },
                set: { enabled in Task { await coordinator.setEnabled(enabled, id: alarm.id) } }
            ))
            .labelsHidden()
        }
    }

    private func skippedOccurrenceForAlarm(_ alarm: AlarmRecord) -> AlarmOccurrence? {
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

    private var diagnosticsView: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Authorization Diagnostics")
                        .font(.headline)
                    Text(authorizationModel.diagnosticsText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    Text("Scheduling Diagnostics")
                        .font(.headline)

                    if let next = coordinator.nextOccurrence,
                       let alarm = coordinator.alarms.first(where: { $0.id == next.alarmID }) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Next Scheduled Alarm")
                                .font(.subheadline.weight(.semibold))
                            Text("Label: \(alarm.label.isEmpty ? "Alarm" : alarm.label)")
                            Text("ID: \(alarm.id.uuidString)")
                            Text("Sound: \(alarm.sound.displayName)")
                            Text("Sound ID: \(alarm.sound.id)")
                            Text("Next Fire: \(next.effectiveDate.formatted(date: .complete, time: .standard))")
                            Text("Base Time: \(next.baseDate.formatted(date: .complete, time: .standard))")
                            Text("Adjusted: \(next.isAdjusted ? "Yes" : "No")")
                        }
                    } else {
                        Text("No next occurrence scheduled")
                    }

                    if let error = coordinator.lastError {
                        Divider()
                        Text("Last Error")
                            .font(.subheadline.weight(.semibold))
                        Text(error)
                            .foregroundStyle(ThemeManager.shared.colors.destructive)
                    }
                }
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
        if minutes == 0 { return "No adjustment" }
        return minutes > 0 ? "Adjusted +\(minutes) min" : "Adjusted \(minutes) min"
    }
}
