import SwiftUI
import UIKit
import AlarmClockShared

struct ContentView: View {
    @State private var authorizationModel = AlarmProofOfConceptModel()
    @State private var coordinator = AlarmCoordinator()
    @State private var editorAlarm: AlarmRecord?
    @State private var showingEditor = false
    @State private var controlsAlarm: AlarmRecord?
    @State private var showingDiagnostics = false
    @State private var showingAppearance = false
    @State private var showingNextAlarmControl = false
    @State private var showingHistory = false
    @State private var currentRingSongName: String? = nil
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var smartWakeService = SmartWakeService.shared
    @State private var alarmPlaybackService = AlarmPlaybackService.shared

    var body: some View {
        NavigationStack {
            List {
                // Show currently ringing song banner if active
                if let songName = alarmPlaybackService.currentTrackName ?? currentRingSongName {
                    Section {
                        HStack {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Now Ringing: \(songName)")
                                .font(.subheadline)
                                .foregroundStyle(ThemeManager.shared.colors.primaryText)
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(ThemeManager.shared.colors.accent.opacity(0.15))
                    }
                }
                
                if authorizationModel.authorizationDescription != "Authorized" {
                    authorizationSection
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
                    Button("Play History") { showingHistory = true }
                }

                Section("Smart Wake") {
                    Toggle("Keep app active overnight (Smart Wake)", isOn: $smartWakeService.isSmartWakeEnabled)
                    if smartWakeService.isSmartWakeEnabled {
                        Text("A silent audio loop will run in background to keep app alive for real song playback at alarm time.")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        if smartWakeService.isRunning {
                            Label("Active", systemImage: "waveform.badge.checkmark")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else {
                            Label("Waiting for armed alarm...", systemImage: "clock.badge.questionmark")
                                .font(.caption)
                                .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        }
                    }
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
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        showingNextAlarmControl = true
                    } label: {
                        Label("Next Alarm", systemImage: "alarm.waves.left.and.right")
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                AlarmEditorView(
                    existingAlarm: editorAlarm,
                    alarms: coordinator.alarms,
                    onSave: { alarm in
                        await coordinator.save(alarm)
                    },
                    onTestAlarm: { alarm, delay in
                        await coordinator.scheduleTestAlarm(alarm, delay: delay)
                    }
                )
            }
            .sheet(item: $controlsAlarm) { alarm in
                NextOccurrenceControlsView(
                    alarm: alarm,
                    coordinator: coordinator
                )
            }
            .sheet(isPresented: $showingNextAlarmControl) {
                NextAlarmControlView()
                    .environmentObject(NextAlarmProvider(coordinator: coordinator))
            }
            .sheet(isPresented: $showingDiagnostics) {
                diagnosticsView
            }
            .sheet(isPresented: $showingAppearance) {
                AppearanceView()
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView(coordinator: coordinator)
            }
            .task {
                if authorizationModel.authorizationDescription == "Authorized" {
                    await coordinator.synchronize()
                }
                // Set shared instance for AlarmPlaybackService access
                AlarmCoordinator.sharedInstance = coordinator
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    checkForActiveRing()
                } else if newPhase == .background {
                    // Start Smart Wake when app backgrounds if enabled and alarm armed
                    if smartWakeService.isSmartWakeEnabled {
                        Task {
                            await smartWakeService.startIfAlarmArmed(coordinator: coordinator)
                        }
                    }
                }
            }
        }
        .tint(ThemeManager.shared.colors.accent)
    }
    
    /// Check if an alarm is currently ringing and record play history
    private func checkForActiveRing() {
        // Get the currently resolved song name for the active ring
        if let songName = coordinator.currentRingSongName() {
            currentRingSongName = songName
            
            // Record in play history if we have an active occurrence
            if let occurrence = coordinator.nextOccurrence,
               occurrence.effectiveDate <= Date(),
               let alarm = coordinator.alarms.first(where: { $0.id == occurrence.alarmID }) {
                coordinator.recordPlayHistory(
                    songName: songName,
                    alarmID: alarm.id,
                    alarmLabel: alarm.label.isEmpty ? "Alarm" : alarm.label
                )
            }
        } else {
            currentRingSongName = nil
        }
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

    private func alarmRow(_ alarm: AlarmRecord) -> some View {
        let colors = ThemeManager.shared.colors
        let occurrence = coordinator.occurrence(for: alarm.id)
        let skippedOccurrence = skippedOccurrenceForAlarm(alarm)

        return HStack(spacing: 12) {
            // Alarm details - tapping opens editor
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

            // Explicit Edit button
            Button {
                editorAlarm = alarm
                showingEditor = true
            } label: {
                Text("Edit")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(colors.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())

            // Toggle ONLY changes enabled state
            Toggle("Enabled", isOn: Binding(
                get: { alarm.isEnabled },
                set: { enabled in Task { await coordinator.setEnabled(enabled, id: alarm.id) } }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .contentShape(Rectangle())
        .contextMenu {
            // Secondary actions
            if let occurrence {
                Button("Custom Time…") {
                    controlsAlarm = alarm
                }
                
                Divider()
                
                HStack {
                    Button {
                        Task { await coordinator.adjustNext(id: alarm.id, minutes: -10) }
                    } label: {
                        Label("−10 min", systemImage: "minus")
                    }
                    Button {
                        Task { await coordinator.resetNext(id: alarm.id) }
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    Button {
                        Task { await coordinator.adjustNext(id: alarm.id, minutes: 10) }
                    } label: {
                        Label("+10 min", systemImage: "plus")
                    }
                }
                
                Divider()
                
                if let skipped = skippedOccurrence {
                    Button("Undo Skip") {
                        Task { await coordinator.undoSkip(id: alarm.id) }
                    }
                } else {
                    Button("Skip Next", role: .destructive) {
                        Task { await coordinator.skipNext(id: alarm.id) }
                    }
                }
            }
            
            Divider()
            
            Button("Delete", role: .destructive) {
                Task { await coordinator.delete(id: alarm.id) }
            }
        }
    }

    private func skippedOccurrenceForAlarm(_ alarm: AlarmRecord) -> AlarmOccurrence? {
        let now = Date()
        let overrides = alarm.overrides
        let calendar = Calendar.autoupdatingCurrent
        
        for (key, override) in overrides where override.isSkipped {
            let keyParts = key.split(separator: "-").compactMap { Int($0) }
            guard keyParts.count == 3 else { continue }
            
            var dateComponents = DateComponents()
            dateComponents.calendar = calendar
            dateComponents.timeZone = calendar.timeZone
            dateComponents.year = keyParts[0]
            dateComponents.month = keyParts[1]
            dateComponents.day = keyParts[2]
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

    private func timeText(_ time: AlarmTime) -> String {
        let date = Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func adjustmentDescription(_ occurrence: AlarmOccurrence) -> String {
        let minutes = Int(occurrence.effectiveDate.timeIntervalSince(occurrence.baseDate) / 60)
        if minutes == 0 { return "No adjustment" }
        return minutes > 0 ? "Adjusted +\(minutes) min" : "Adjusted \(minutes) min"
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
                            
                            // Show sound filename for AlarmKit
                            if case .imported(let id) = alarm.sound {
                                if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                                    Text("AlarmKit Sound File: \(sound.fileName)")
                                        .foregroundStyle(ThemeManager.shared.colors.accent)
                                } else {
                                    Text("AlarmKit Sound File: MISSING (sound id no longer in library)")
                                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                                }
                            }
                            
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
                    
                    Divider()
                    
                    Text("Widget Pipeline Diagnostics")
                        .font(.headline)
                    
                    widgetDiagnosticsSection
                    
                    Divider()
                    
                    Text("Playlist Diagnostics")
                        .font(.headline)
                    
                    Text(coordinator.playlistDiagnostics.diagnosticsText)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy All Diagnostics") { 
                        let widgetDiagnosticsText = generateWidgetDiagnosticsText()
                        let combined = authorizationModel.diagnosticsText + "\n\n" + coordinator.playlistDiagnostics.diagnosticsText + "\n\n" + widgetDiagnosticsText + "\n\n" + readLiveActivityDebugLog()
                        UIPasteboard.general.string = combined
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingDiagnostics = false }
                }
            }
        }
    }
    
    private var widgetDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current snapshot in memory
            if let snapshot = coordinator.nextAlarmSnapshot {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current In-Memory Snapshot")
                        .font(.subheadline.weight(.semibold))
                    Text("Alarm ID: \(snapshot.alarmID.uuidString)")
                    Text("Label: \(snapshot.label)")
                    Text("Next Occurrence: \(snapshot.nextOccurrenceDate.formatted(date: .complete, time: .standard))")
                    Text("Enabled: \(snapshot.isEnabled ? "Yes" : "No")")
                    Text("Adjusted: \(snapshot.isAdjusted ? "Yes" : "No")")
                    if let adj = snapshot.adjustmentDescription {
                        Text("Adjustment: \(adj)")
                    }
                    Text("Sound: \(snapshot.sound.displayName)")
                    Text("Loudness: \(snapshot.loudness.percentage)%")
                }
                .font(.caption.monospaced())
            } else {
                Text("Current In-Memory Snapshot: NONE (no upcoming alarm)")
                    .font(.caption.monospaced())
            }
            
            Divider()
            
            // Last write result
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Snapshot Write")
                    .font(.subheadline.weight(.semibold))
                let result = coordinator.lastSnapshotWriteResult
                Text("Success: \(result.success ? "YES" : "NO")")
                if let error = result.error {
                    Text("Error: \(error)")
                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                }
                if let timestamp = result.timestamp {
                    Text("Timestamp: \(timestamp.formatted(date: .complete, time: .standard))")
                }
            }
            .font(.caption.monospaced())
            
            Divider()
            
            // Last widget reload request
            VStack(alignment: .leading, spacing: 4) {
                Text("Last WidgetCenter Reload Request")
                    .font(.subheadline.weight(.semibold))
                if let timestamp = coordinator.lastWidgetReloadRequest {
                    Text("Timestamp: \(timestamp.formatted(date: .complete, time: .standard))")
                    Text("Age: \(Int(Date().timeIntervalSince(timestamp))) seconds ago")
                } else {
                    Text("Never requested")
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
            }
            .font(.caption.monospaced())
            
            Divider()
            
            // App Group configuration
            VStack(alignment: .leading, spacing: 4) {
                Text("App Group Configuration")
                    .font(.subheadline.weight(.semibold))
                if let configured = Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String {
                    Text("Configured: \(configured)")
                }
                if let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], !resigned.isEmpty {
                    Text("ALTAppGroups: \(resigned.joined(separator: ", "))")
                } else {
                    Text("ALTAppGroups: (none)")
                }
            }
            .font(.caption.monospaced())
            
            Divider()

            // Live Activity Debug Log
            VStack(alignment: .leading, spacing: 8) {
                Text("Live Activity Debug Log")
                    .font(.headline)
                
                Button("Refresh Log") {
                    // Force view to refresh by toggling state
                }
                .buttonStyle(.bordered)
                .font(.caption)
                
                Text(readLiveActivityDebugLog())
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .frame(maxHeight: 200, alignment: .top)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }
            .font(.caption.monospaced())
            
            Divider()
            
            // Instructions for device log access
            VStack(alignment: .leading, spacing: 4) {
                Text("Device Log Access")
                    .font(.subheadline.weight(.semibold))
                Text("Filter Console.app / Console on macOS or Xcode device log with:")
                    .font(.caption)
                Text("subsystem:com.example.alarmclock.widget-diagnostics")
                    .font(.caption.monospaced())
                    .foregroundStyle(ThemeManager.shared.colors.accent)
                Text("Or grep for: MYNEXTALARM_APP_DIAG or MYNEXTALARM_WIDGET_DIAG")
                    .font(.caption.monospaced())
                    .foregroundStyle(ThemeManager.shared.colors.accent)
            }
            .font(.caption.monospaced())
        }
}
    



    private func readLiveActivityDebugLog() -> String {
        let fileManager = FileManager.default
        guard let appGroupURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: "group.com.example.alarmclock"
        ) else { return "App Group not available" }
        
        let logURL = appGroupURL.appendingPathComponent("live_activity_debug.log")
        
        guard fileManager.fileExists(atPath: logURL.path) else {
            return "No debug log file found yet.\nTap a Dynamic Island button to generate log entries."
        }
        
        do {
            let content = try String(contentsOf: logURL, encoding: .utf8)
            let lines = content.components(separatedBy: .newlines)
            let last50 = lines.suffix(50)
            return last50.joined(separator: "\n")
        } catch {
            return "Error reading log: \(error.localizedDescription)"
        }
    }
    
    private func generateWidgetDiagnosticsText() -> String {
        var text = "=== WIDGET PIPELINE DIAGNOSTICS ===\n\n"
        
        // Current snapshot in memory
        if let snapshot = coordinator.nextAlarmSnapshot {
            text += "Current In-Memory Snapshot:\n"
            text += "Alarm ID: \(snapshot.alarmID.uuidString)\n"
            text += "Label: \(snapshot.label)\n"
            text += "Next Occurrence: \(snapshot.nextOccurrenceDate.formatted(date: .complete, time: .standard))\n"
            text += "Enabled: \(snapshot.isEnabled ? "Yes" : "No")\n"
            text += "Adjusted: \(snapshot.isAdjusted ? "Yes" : "No")\n"
            if let adj = snapshot.adjustmentDescription {
                text += "Adjustment: \(adj)\n"
            }
            text += "Sound: \(snapshot.sound.displayName)\n"
            text += "Loudness: \(snapshot.loudness.percentage)%\n\n"
        } else {
            text += "Current In-Memory Snapshot: NONE (no upcoming alarm)\n\n"
        }
        
        // Last write result
        let result = coordinator.lastSnapshotWriteResult
        text += "Last Snapshot Write:\n"
        text += "Success: \(result.success ? "YES" : "NO")\n"
        if let error = result.error {
            text += "Error: \(error)\n"
        }
        if let timestamp = result.timestamp {
            text += "Timestamp: \(timestamp.formatted(date: .complete, time: .standard))\n"
        }
        text += "\n"
        
        // Last widget reload request
        text += "Last WidgetCenter Reload Request:\n"
        if let timestamp = coordinator.lastWidgetReloadRequest {
            text += "Timestamp: \(timestamp.formatted(date: .complete, time: .standard))\n"
            text += "Age: \(Int(Date().timeIntervalSince(timestamp))) seconds ago\n\n"
        } else {
            text += "Never requested\n\n"
        }
        
        // App Group configuration
        text += "App Group Configuration:\n"
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String {
            text += "Configured: \(configured)\n"
        }
        if let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], !resigned.isEmpty {
            text += "ALTAppGroups: \(resigned.joined(separator: ", "))\n"
        } else {
            text += "ALTAppGroups: (none)\n"
        }
        text += "\n"
        
        return text
    }
}