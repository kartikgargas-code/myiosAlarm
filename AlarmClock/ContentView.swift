import SwiftUI
import UIKit
import AlarmKit
import AlarmClockShared
import os.log

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
    // Copy button feedback states
    @State private var smartWakeLogCopied = false
    @State private var smartWakeLogUnavailable = false

    var body: some View {
        NavigationStack {
            ZStack {
                List {
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
                        Button("Themes") { showingAppearance = true }
                        Button("Play History") { showingHistory = true }
                    }

                    Section("Smart Wake") {
                        Toggle("Keep app active overnight (Smart Wake)", isOn: $smartWakeService.isSmartWakeEnabled)
                        if smartWakeService.isSmartWakeEnabled {
                            Text("A silent audio loop will run in background to keep app alive for real song playback at alarm time.")
                                .font(.caption)
                                .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            // Status from SmartWakeService (only updates when changed)
                            Text(smartWakeService.statusTextPublished)
                                .font(.caption)
                                .foregroundStyle(
                                    smartWakeService.statusTextPublished.contains("Ringing") ? .orange :
                                    smartWakeService.statusTextPublished.contains("Active") ? .green :
                                    ThemeManager.shared.colors.secondaryText
                                )
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
                
                // Now Ringing banner as pinned overlay (stable, not in List)
                // Shows during in-app playback OR system alarm rings (via smartWakeService.alertingSongName)
                let songName = alarmPlaybackService.currentTrackName ?? currentRingSongName ?? smartWakeService.alertingSongName
                if let songName = songName {
                    VStack {
                        HStack {
                            Image(systemName: "speaker.wave.3.fill")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Now Ringing: \(songName)")
                                .font(.subheadline)
                                .foregroundStyle(ThemeManager.shared.colors.primaryText)
                            Spacer()
                            Button {
                                // Stop in-app playback AND cancel all alerting AlarmKit alarms
                                alarmPlaybackService.stop()
                                currentRingSongName = nil
                                
                                // Cancel all alerting alarms (for system rings)
                                Task {
                                    do {
                                        let alerting = try AlarmManager.shared.alarms.filter { $0.state == .alerting }
                                        for kitAlarm in alerting {
                                            try AlarmManager.shared.cancel(id: kitAlarm.id)
                                            SmartWakeDebugLog.log("BANNER STOP: cancelled alerting alarm \(kitAlarm.id.uuidString)")
                                        }
                                        if !alerting.isEmpty {
                                            os_log(.info, log: OSLog(subsystem: "com.example.alarmclock", category: "AlarmPlayback"), "BANNER STOP: cancelled %d alerting alarm(s)", alerting.count)
                                        }
                                    } catch {
                                        os_log(.error, log: OSLog(subsystem: "com.example.alarmclock", category: "AlarmPlayback"), "BANNER STOP failed: %{public}s", error.localizedDescription)
                                    }
                                }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .labelStyle(.iconOnly)
                            }
                            .tint(ThemeManager.shared.colors.accent)
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            ThemeManager.shared.colors.background.opacity(0.95)
                        )
                        .cornerRadius(12)
                        .shadow(radius: 4)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        Spacer()
                    }
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.2), value: alarmPlaybackService.currentTrackName)
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
                // Attach coordinator to SmartWakeService for foreground/background triggers
                await smartWakeService.startIfAlarmArmed(coordinator: coordinator)
                // Start Smart Wake in foreground if enabled (idempotent)
                if smartWakeService.isSmartWakeEnabled {
                    await smartWakeService.startIfReadyForeground()
                }
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
                } else if newPhase == .inactive {
                    // Last foreground moment before lock/suspend — ensure Smart Wake is running
                    if smartWakeService.isSmartWakeEnabled {
                        Task {
                            await smartWakeService.startIfReadyForeground()
                        }
                    }
                }
            }
        }
        .tint(ThemeManager.shared.colors.accent)
    }
    
    /// Check if an alarm is currently ringing and refresh the banner.
    /// History recording lives in AlarmPlaybackService.audioPlayerDidFinishPlaying
    /// (one entry per fully completed song); recording here produced duplicates
    /// and only fired on foreground transitions.
    private func checkForActiveRing() {
        // Black-box recorder: dump full AlarmKit state every time the app comes
        // to foreground. This is how we diagnose the snooze display mystery —
        // after a snooze tap, reopening the app prints the alarm's true state
        // (alerting / countdown / paused) and countdown dates.
        coordinator.logAlarmKitState()

        // SINGLE SOURCE OF TRUTH for ring detection — do not add a second check elsewhere.
        if let result = coordinator.currentlyRingingAlarm() {
            let newSongName = result.songName
            // Only assign if value actually differs to prevent render churn
            if currentRingSongName != newSongName {
                currentRingSongName = newSongName
            }
        } else if currentRingSongName != nil {
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
            DiagnosticsScreen()
                .navigationTitle("Diagnostics")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { showingDiagnostics = false }
                    }
                }
        }
    }

    var widgetDiagnosticsSection: some View {
        // Not used - replaced by new DiagnosticsScreen
        EmptyView()
    }
    
    func generateWidgetDiagnosticsText() -> String {
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
    
    // MARK: - Smart Wake Log for copy-all diagnostics
    func smartWakeLogForDiagnostics() -> String {
        let log = SmartWakeDebugLog.read() ?? "No Smart Wake log entries yet."
        return "=== SMART WAKE LOG ===\n\(log)\n"
    }
}

// MARK: - New Clean Diagnostics Screen
struct DiagnosticsScreen: View {
    @State private var logLines: [String] = []
    @State private var isLoading = false
    @State private var showUTCNotice = true
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 1. Last Alarm Result
                lastAlarmResultSection
                
                Divider()
                
                // 2. Next Alarm Time
                nextAlarmTimeSection
                
                Divider()
                
                // 3. Loop Alive/Dead
                loopStatusSection
                
                Divider()
                
                // 4. Last ~20 useful log lines
                logSection
            }
            .padding()
        }
        .navigationTitle("Diagnostics")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Copy (40 lines)") {
                    copyFilteredLog()
                }
                .disabled(logLines.isEmpty)
            }
            ToolbarItem(placement: .cancellationAction) {
                HStack(spacing: 8) {
                    Button("Clear") {
                        clearLog()
                    }
                    .disabled(logLines.isEmpty)
                    Button("Refresh") {
                        loadLog()
                    }
                    .disabled(isLoading)
                }
            }
        }
        .onAppear {
            loadLog()
        }
    }
    
    // MARK: - Section 1: Last Alarm Result
    private var lastAlarmResultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Last Alarm Result")
                .font(.subheadline.weight(.semibold))
            
            // Get last playback event from coordinator
            if let lastEvent = AlarmCoordinator.sharedInstance?.playlistDiagnostics.playbackHistory.last {
                VStack(alignment: .leading, spacing: 4) {
                    Text(lastEvent.eventType)
                        .font(.caption.monospaced())
                        .foregroundStyle(lastEvent.eventType.contains("FAILED") || lastEvent.eventType.contains("ERROR") ? .red : .green)
                    if let details = lastEvent.details {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Text("At: \(lastEvent.timestamp.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("No alarm events recorded yet")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Section 2: Next Alarm Time
    private var nextAlarmTimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Next Alarm Time")
                .font(.subheadline.weight(.semibold))
            
            if let next = AlarmCoordinator.sharedInstance?.nextOccurrence,
               let alarm = AlarmCoordinator.sharedInstance?.alarms.first(where: { $0.id == next.alarmID }) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Label: \(alarm.label.isEmpty ? "Alarm" : alarm.label)")
                    Text("ID: \(alarm.id.uuidString.prefix(8))")
                    Text("Sound: \(alarm.sound.displayName)")
                    Text("Next Fire: \(next.effectiveDate.formatted(date: .complete, time: .standard))")
                    Text("Adjusted: \(next.isAdjusted ? "Yes" : "No")")
                    if next.isAdjusted {
                        let minutes = Int(next.effectiveDate.timeIntervalSince(next.baseDate) / 60)
                        Text("Adjustment: \(minutes > 0 ? "+" : "")\(minutes) min")
                    }
                }
                .font(.caption.monospaced())
            } else {
                Text("No upcoming alarm scheduled")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Section 3: Loop Alive/Dead
    private var loopStatusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Smart Wake Loop Status")
                .font(.subheadline.weight(.semibold))
            
            let status = SmartWakeService.shared.isRunning ? "ALIVE — silent loop running" : "DEAD — no silent loop"
            let color = SmartWakeService.shared.isRunning ? Color.green : Color.red
            
            Text(status)
                .font(.caption.monospaced())
                .foregroundStyle(color)
            
            Text("Status tick: \(SmartWakeService.shared.statusTextPublished)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
    
    // MARK: - Section 4: Log Lines
    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Smart Wake Log (last 20 useful lines)")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if showUTCNotice {
                    Text("Times shown in UTC (device is local)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            
            if isLoading {
                ProgressView("Loading...")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if logLines.isEmpty {
                Text("No log entries yet")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(logLines, id: \.self) { line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.systemGray6))
                .cornerRadius(8)
            }
        }
    }
    
    // MARK: - Helpers
    private func loadLog() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let text = SmartWakeDebugLog.read() ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                // Filter out noise: SESSION DUMP, play() FALSE, STATE DUMP, BACKUP: skipping, lines starting with "  id="
                .filter { line in
                    !line.contains("SESSION DUMP") &&
                    !line.contains("play() FALSE") &&
                    !line.contains("STATE DUMP") &&
                    !line.contains("BACKUP: skipping") &&
                    !line.hasPrefix("  id=")
                }
                .suffix(20)
                .map { line in
                    // Extract timestamp and convert to local time if it's ISO8601
                    if let timestampEnd = line.firstIndex(of: "]") {
                        let timestampStr = String(line[line.startIndex...timestampEnd])
                        if let date = ISO8601DateFormatter().date(from: timestampStr.dropFirst().dropLast()) {
                            let localFormatter = DateFormatter()
                            localFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                            localFormatter.timeZone = TimeZone.current
                            let localStr = localFormatter.string(from: date)
                            return line.replacingOccurrences(of: timestampStr, with: "[\(localStr) LOCAL]")
                        }
                    }
                    return line
                }
            
            DispatchQueue.main.async {
                self.logLines = Array(lines)
                self.isLoading = false
            }
        }
    }
    
    private func clearLog() {
        SmartWakeDebugLog.clear()
        logLines.removeAll()
    }
    
    private func copyFilteredLog() {
        let text = SmartWakeDebugLog.read() ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { line in
                !line.contains("SESSION DUMP") &&
                !line.contains("play() FALSE") &&
                !line.contains("STATE DUMP") &&
                !line.contains("BACKUP: skipping") &&
                !line.hasPrefix("  id=")
            }
            .suffix(40)
            .joined(separator: "\n")
        
        UIPasteboard.general.string = lines
    }
}
