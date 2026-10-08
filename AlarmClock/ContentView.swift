import SwiftUI
import UIKit
import AlarmKit
import AlarmClockShared
import UniformTypeIdentifiers
import os.log
import UserNotifications

struct ContentView: View {
    @State private var authorizationModel = AlarmProofOfConceptModel()
    @State private var coordinator = AlarmCoordinator()
    @State private var editorPresentation: EditorPresentation?
    @State private var controlsAlarm: AlarmRecord?
    @State private var showingDiagnostics = false
    @State private var showingAppearance = false
    @State private var showingHistory = false
    @State private var showingSounds = false
    @State private var currentRingSongName: String? = nil
    @State private var pendingEnabled: [UUID: Bool] = [:]
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var smartWakeService = SmartWakeService.shared
    @State private var alarmPlaybackService = AlarmPlaybackService.shared
    // Copy button feedback states
    @State private var smartWakeLogCopied = false
    @State private var smartWakeLogUnavailable = false
    @State private var exportURL: URL?
    @State private var showingImportPicker = false
    // Track foreground state for CC feedback gating
    @State private var isAppInForeground = true
    // Static property accessible from AlarmCoordinator
    static var isAppInForegroundStatic: Bool = true

    var body: some View {
        NavigationStack {
            ZStack {
                List {
                    if authorizationModel.authorizationDescription != "Authorized" {
                        authorizationSection
                    }

                    Section("Alarms") {
                        if coordinator.alarms.isEmpty {
                            Color.clear
                                .frame(maxWidth: .infinity, minHeight: 160)
                                .contentShape(Rectangle())
                                .onTapGesture { editorPresentation = EditorPresentation(id: UUID(), alarm: nil) }
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
                        Button("Sounds") { showingSounds = true }
                    }
                    
                    Section("Backup & Restore") {
                        Button("Export Backup") {
                            Task {
                                do {
                                    let url = try await BackupRestoreService.shared.exportArchive()
                                    exportURL = url
                                } catch {
                                    coordinator.lastError = "Export failed: \(error.localizedDescription)"
                                }
                            }
                        }
                        Button("Import Backup") {
                            showingImportPicker = true
                        }
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
                    
                    // Build fingerprint footer
                    Section {
                        if let buildLine = SmartWakeDebugLog.latestBuildLine() {
                            Text(buildLine)
                                .font(.caption2.monospaced())
                                .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .background(ThemeManager.shared.colors.background)
                .navigationTitle("myNextAlarm")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editorPresentation = EditorPresentation(id: UUID(), alarm: nil)
                        } label: {
                            Image(systemName: "plus")
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
            .sheet(item: $editorPresentation) { presentation in
                AlarmEditorView(
                    existingAlarm: presentation.alarm,
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
            .sheet(isPresented: $showingDiagnostics) {
                diagnosticsView
            }
            .sheet(isPresented: $showingAppearance) {
                AppearanceView()
            }
            .sheet(isPresented: $showingHistory) {
                HistoryView(coordinator: coordinator)
            }
            .sheet(isPresented: $showingSounds) {
                SoundsView(alarms: coordinator.alarms)
            }
            .fileExporter(
                isPresented: Binding(
                    get: { exportURL != nil },
                    set: { if !$0 { exportURL = nil } }
                ),
                document: exportURL.map { ExportDocument(url: $0) } ?? ExportDocument(url: URL(fileURLWithPath: "")),
                contentType: .json,
                defaultFilename: "AlarmClock_Backup"
            ) { result in
                switch result {
                case .success(let url):
                    SmartWakeDebugLog.log("Backup exported to \(url.path)")
                case .failure(let error):
                    coordinator.lastError = "Export failed: \(error.localizedDescription)"
                }
            }
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task {
                            do {
                                try await BackupRestoreService.shared.importArchive(from: url)
                                coordinator.lastError = nil
                            } catch {
                                coordinator.lastError = "Import failed: \(error.localizedDescription)"
                            }
                        }
                    }
                case .failure(let error):
                    coordinator.lastError = "Import failed: \(error.localizedDescription)"
                }
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
                
                // TASK 3: Log bundle icon keys at launch
                let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String ?? "none"
                let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
                let hasIcons = icons != nil
                SmartWakeDebugLog.log("ICON KEYS: CFBundleIconName=\(iconName) CFBundleIcons=\(hasIcons ? "present" : "absent")")
            }
            .onChange(of: scenePhase) { oldPhase, newPhase in
                if newPhase == .active {
                    isAppInForeground = true
                    ContentView.isAppInForegroundStatic = true
                    // Apply any Control Center widget action queued while the
                    // app was closed/backgrounded (app is the sole AlarmKit party).
                    Task {
                        await coordinator.applyPendingWidgetActions()
                        
                        // Purge CC feedback notifications from Notification Center on foreground
                        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["cc-feedback-extension", "cc-feedback"])
                        SmartWakeDebugLog.log("CC FEEDBACK: cleared delivered cc-feedback notifications on foreground")
                    }
                    checkForActiveRing()
                } else if newPhase == .background {
                    isAppInForeground = false
                    ContentView.isAppInForegroundStatic = false
                    // Start Smart Wake when app backgrounds if enabled and alarm armed
                    if smartWakeService.isSmartWakeEnabled {
                        Task {
                            await smartWakeService.startIfAlarmArmed(coordinator: coordinator)
                        }
                    }
                } else if newPhase == .inactive {
                    isAppInForeground = false
                    ContentView.isAppInForegroundStatic = false
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
        let isCompact = ThemeManager.shared.isCompactModeEnabled

        return HStack(spacing: 12) {
            // Alarm details - tapping opens editor
            Button {
                SmartWakeDebugLog.log("EDITOR OPEN: tapped \(alarm.id.uuidString)")
                editorPresentation = EditorPresentation(id: alarm.id, alarm: alarm)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(timeText(alarm.time))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(colors.primaryText)
                    Text(alarm.label.isEmpty ? "Alarm" : alarm.label)
                        .font(.subheadline)
                        .foregroundStyle(colors.primaryText)
                    
                    if !isCompact {
                        Text(alarm.repeatRule.displayName)
                            .font(.caption)
                            .foregroundStyle(colors.accent)
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
                                        .foregroundStyle(colors.accent)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Toggle ONLY changes enabled state
            Toggle("Enabled", isOn: Binding(
                get: { pendingEnabled[alarm.id] ?? alarm.isEnabled },
                set: { enabled in
                    pendingEnabled[alarm.id] = enabled
                    Task {
                        await coordinator.setEnabled(enabled, id: alarm.id)
                        pendingEnabled[alarm.id] = nil
                    }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
        }
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
                    Button {
                        Task { await coordinator.skipNext(id: alarm.id) }
                    } label: {
                        Label("Skip Next", systemImage: "forward.end")
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                    }
                }
            }
            
            Divider()
            
            Button {
                Task { await coordinator.duplicate(id: alarm.id) }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
                    .foregroundStyle(.yellow)
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
    @State private var cacheProcessedCount = 0
    @State private var cacheProcessedMB: Double = 0
    @State private var cacheSoundsCount = 0
    @State private var cacheSoundsMB: Double = 0
    // Imported sounds stats
    @State private var importedSoundsCount = 0
    @State private var importedSoundsMB: Double = 0
    @State private var orphanedFiles: [AudioProcessingService.OrphanedFile] = []
    @State private var armedFileNames: [String] = []
    @State private var lastPruneDate: Date? = nil
    @State private var lastPruneFreedMB: Double = 0
    @State private var showUTCNotice = true
    @State private var buildFingerprint: String? = nil
    @State private var armedRecords: [AlarmCoordinator.ArmedAlarmRecord] = []
    
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // 0. Build Fingerprint (always at top)
                buildFingerprintSection

                Divider()

                // 0b. CAF format experiment
                cafExperimentSection

                Divider()

                // 0c. Alarm sound cache
                alarmSoundCacheSection

                Divider()

                // 0d. Armed right now
                armedRightNowSection

                Divider()

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
            loadBuildFingerprint()
            loadCacheStats()
        }
    }
    
    // MARK: - Section 0: Build Fingerprint
    private var buildFingerprintSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Build Fingerprint")
                .font(.subheadline.weight(.semibold))
            
            if let fingerprint = buildFingerprint {
                Text(fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
            } else {
                Text("Build fingerprint not found in log")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    // MARK: - Section 0b: CAF format experiment
    private var cafExperimentSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAF Format Experiment")
                .font(.subheadline.weight(.semibold))
            Text("Renders the current 60s floor stitch a second time as compressed CAF (IMA4), logs both byte sizes, and schedules a one-shot test alarm 15 s out using the CAF. If it rings with your playlist audio, AlarmKit accepts compressed files; if it rings with the stock system sound, it refused the CAF.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Test CAF floor sound") {
                Task { await AlarmCoordinator.sharedInstance?.scheduleCAFTestAlarm() }
            }
        }
    }

    // MARK: - Section 0c: Alarm sound cache
    private var alarmSoundCacheSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Alarm Sound Cache")
                .font(.subheadline.weight(.semibold))
            
            // Stitched files (playlist cache)
            Text("Stitched playlist files:")
                .font(.caption.weight(.semibold))
            Text("Library/ProcessedSounds: \(cacheProcessedCount) files (\(String(format: "%.1f", cacheProcessedMB)) MB)")
                .font(.caption.monospaced())
            Text("Library/Sounds (playlist_): \(cacheSoundsCount) files (\(String(format: "%.1f", cacheSoundsMB)) MB)")
                .font(.caption.monospaced())
            
            Divider()
            
            // Imported sounds
            Text("Imported sound files (Library/Sounds):")
                .font(.caption.weight(.semibold))
            Text("Total: \(importedSoundsCount) files (\(String(format: "%.1f", importedSoundsMB)) MB)")
                .font(.caption.monospaced())
            
            // Orphaned files
            if !orphanedFiles.isEmpty {
                Text("Orphaned files (no library entry):")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                ForEach(orphanedFiles, id: \.fileName) { orphan in
                    Text("\(orphan.fileName) — \(String(format: "%.1f", Double(orphan.sizeBytes) / 1_048_576.0)) MB")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }
            
            if let lastPruneDate {
                Text("Last cleanup: \(lastPruneDate.formatted(date: .abbreviated, time: .shortened)) (freed \(String(format: "%.1f", lastPruneFreedMB)) MB)")
                    .font(.caption.monospaced())
            } else {
                Text("Last cleanup: never")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            
            HStack {
                Button("Clear unused cached sounds") {
                    AlarmCoordinator.sharedInstance?.pruneStitchCacheNow()
                    loadCacheStats()
                }
                
                if !orphanedFiles.isEmpty {
                    Button("Clean orphaned sound files") {
                        let _ = AudioProcessingService.shared.cleanOrphanedSoundFiles()
                        loadCacheStats()
                    }
                    .foregroundStyle(.red)
                }
            }
        }
    }

    private func loadCacheStats() {
        let stats = AudioProcessingService.shared.stitchCacheStats()
        cacheProcessedCount = stats.processed.fileCount
        cacheProcessedMB = Double(stats.processed.totalBytes) / 1_048_576.0
        cacheSoundsCount = stats.sounds.fileCount
        cacheSoundsMB = Double(stats.sounds.totalBytes) / 1_048_576.0
        
        // Load imported sounds stats including orphaned files
        let importedStats = AudioProcessingService.shared.importedSoundsStats()
        importedSoundsCount = importedStats.fileCount
        importedSoundsMB = Double(importedStats.totalBytes) / 1_048_576.0
        orphanedFiles = importedStats.orphanedFiles
        
        armedFileNames = AlarmCoordinator.sharedInstance?.lastArmedSoundFileNames.sorted() ?? []
        lastPruneDate = AlarmCoordinator.sharedInstance?.lastStitchPruneDate
        lastPruneFreedMB = Double(AlarmCoordinator.sharedInstance?.lastStitchPruneFreedBytes ?? 0) / 1_048_576.0
        loadArmedRecords()
    }
    
    private func loadArmedRecords() {
        armedRecords = AlarmCoordinator.sharedInstance?.lastArmedRecords ?? []
    }
    
    // MARK: - Section 0d: Armed right now
    private var armedRightNowSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Armed Right Now")
                .font(.subheadline.weight(.semibold))
            
            if armedRecords.isEmpty {
                Text("No alarms currently armed")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            } else {
                ForEach(armedRecords, id: \.alarmID) { record in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(record.kind.uppercased())
                                .font(.caption2.monospaced())
                                .foregroundStyle(record.kind == "primary" ? .green : .orange)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color(.systemGray5))
                                .cornerRadius(3)
                            Text(record.soundFileName)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                            Spacer()
                            Text(record.format)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                            if record.isCapped {
                                Text("CAPPED")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 3)
                                    .padding(.vertical, 1)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(3)
                            }
                        }
                        Text("Fire: \(record.effectiveDate.formatted(date: .abbreviated, time: .standard))  Duration: \(String(format: "%.1f", record.duration))s  Bytes: \(record.bytes)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        if record.firedAt != nil {
                            Text("FIRED at \(record.firedAt!.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.red)
                        } else if record.reArmedAt != nil {
                            Text("Re-armed at \(record.reArmedAt!.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.blue)
                        } else if record.skipped {
                            Text("SKIPPED")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.orange)
                        } else {
                            Text("Armed at \(record.armedAt.formatted(date: .abbreviated, time: .standard))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
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
                        if let date = ISO8601DateFormatter().date(from: String(timestampStr.dropFirst().dropLast())) {
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
    
    private func loadBuildFingerprint() {
        self.buildFingerprint = SmartWakeDebugLog.latestBuildLine()
    }
}

// MARK: - Editor Presentation (item-based, travels with sheet)
struct EditorPresentation: Identifiable {
    let id: UUID
    let alarm: AlarmRecord?  // nil = Add new alarm
}

// MARK: - Sounds View (Sound Manager)
struct SoundsView: View {
    @Environment(\.dismiss) private var dismiss
    let alarms: [AlarmRecord]
    
    @State private var showingDocumentPicker = false
    @State private var importError: String?
    @State private var pickerMode: PickerMode = .files
    private enum PickerMode { case files, folder }
    
    @AppStorage("soundSortOption") private var sortOptionRaw: String = SoundSortOption.name.rawValue
    private var sortOption: SoundSortOption {
        get { SoundSortOption(rawValue: sortOptionRaw) ?? .name }
        set { sortOptionRaw = newValue.rawValue }
    }
    private enum SoundSortOption: String, CaseIterable, Identifiable {
        case name = "Name"
        case dateAdded = "Date Added"
        case size = "Size"
        case folder = "Folder"
        case duration = "Duration"
        
        var id: String { rawValue }
    }
    
    private let preview = SoundPreviewService.shared
    
    private var sortedSounds: [ImportedSound] {
        let sounds = SoundLibrary.shared.importedSounds
        switch sortOption {
        case .name:
            return sounds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .dateAdded:
            return sounds.sorted { $0.dateAdded > $1.dateAdded }
        case .size:
            // Size requires reading file attributes - for now sort by filename as proxy
            return sounds.sorted { $0.fileName.localizedCaseInsensitiveCompare($1.fileName) == .orderedAscending }
        case .folder:
            return sounds.sorted { 
                let f1 = $0.folder ?? ""
                let f2 = $1.folder ?? ""
                return f1.localizedCaseInsensitiveCompare(f2) == .orderedAscending
            }
        case .duration:
            return sounds.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Import actions at top for easy access
                Section("Import") {
                    Button {
                        pickerMode = .files
                        showingDocumentPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Import MP3 from Files")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                        }
                    }

                    Button {
                        pickerMode = .folder
                        showingDocumentPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Import MP3 Folder as Playlist")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                        }
                    }
                }
                
                Section("Imported Sounds") {
                    if SoundLibrary.shared.importedSounds.isEmpty {
                        Text("No imported sounds yet. Tap 'Import MP3 from Files' to add sounds.")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    } else {
                        ForEach(sortedSounds) { sound in
                            soundRow(sound: sound)
                        }
                    }
                }
                
                if let importError {
                    Section("Import Error") {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(ThemeManager.shared.colors.destructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Sounds")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Picker("Sort by", selection: $sortOptionRaw) {
                            ForEach(SoundSortOption.allCases) { option in
                                Text(option.rawValue).tag(option.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                    }
                }
            }
            .fileImporter(
                isPresented: $showingDocumentPicker,
                allowedContentTypes: pickerMode == .files ? [.mp3, .audio, .movie] : [.folder],
                allowsMultipleSelection: pickerMode == .files
            ) { result in
                switch result {
                case .success(let urls):
                    if pickerMode == .files {
                        guard !urls.isEmpty else { return }
                        for url in urls {
                            Task { await importSound(from: url) }
                        }
                    } else {
                        // Folder mode
                        guard let url = urls.first else { return }
                        Task { await importFolder(from: url) }
                    }
                case .failure(let error):
                    importError = "Picker failed: \(error.localizedDescription)"
                }
            }
            .onDisappear {
                preview.stop()
            }
        }
    }
    
    private func soundRow(sound: ImportedSound) -> some View {
        let previewURL = sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
        let isPlayingThis = preview.playingSoundID == sound.fileName
        let isReferenced = isSoundReferenced(sound)
        
        return HStack(spacing: 12) {
            // Play/Pause toggle on the left
            if let previewURL {
                Button {
                    if preview.playingSoundID == sound.fileName {
                        preview.stop()
                    } else {
                        preview.play(url: previewURL, id: sound.fileName)
                    }
                } label: {
                    Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.accent)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "speaker.slash")
                    .font(.title3)
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    .frame(width: 36, height: 36)
            }
            
            VStack(alignment: .leading, spacing: 1) {
                Text(sound.name)
                    .font(.body)
                    .foregroundStyle(ThemeManager.shared.colors.primaryText)
                Text(sound.duration.map { String(format: "%.1f seconds", $0) } ?? "Unknown duration")
                    .font(.caption)
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            
            Spacer()
            
            if isPlayingThis {
                Image(systemName: "waveform.circle.fill")
                    .foregroundStyle(ThemeManager.shared.colors.accent)
                    .font(.title3)
            }
            
            // Delete button - always enabled, performs full cleanup directly
            Button(role: .destructive) {
                // Always do full cleanup: remove from playlists, reset alarms, delete file
                SoundLibrary.shared.removeSoundFromAllPlaylists(sound.id)
                SoundLibrary.shared.deleteSoundFileByID(sound.id)
                SmartWakeDebugLog.log("SOUND DELETE UI: id=\(sound.id.uuidString) referenced=\(isReferenced ? "yes" : "no") confirmed=yes")
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(ThemeManager.shared.colors.destructive)
                    .font(.title3)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                // Always do full cleanup: remove from playlists, reset alarms, delete file
                SoundLibrary.shared.removeSoundFromAllPlaylists(sound.id)
                SoundLibrary.shared.deleteSoundFileByID(sound.id)
                SmartWakeDebugLog.log("SOUND DELETE UI: id=\(sound.id.uuidString) referenced=\(isReferenced ? "yes" : "no") confirmed=yes")
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
    
    private func getReferencesForSound(_ sound: ImportedSound) -> String {
        var refs: [String] = []
        
        // Check alarms
        for alarm in alarms {
            if case .imported(let id) = alarm.sound, id == sound.id {
                refs.append("alarm \"\(alarm.label.isEmpty ? "Alarm" : alarm.label)\"")
            }
            if case .random(let pid) = alarm.sound {
                if let playlist = try? SoundLibrary.shared.playlist(for: pid),
                   playlist.soundIDs.contains(sound.id) || playlist.selectedSoundIDs.contains(sound.id) {
                    refs.append("playlist \"\(playlist.name)\" (random)")
                }
            }
            if case .precomposedPlaylist(let pid, _) = alarm.sound {
                if let playlist = try? SoundLibrary.shared.playlist(for: pid),
                   playlist.soundIDs.contains(sound.id) || playlist.selectedSoundIDs.contains(sound.id) {
                    refs.append("playlist \"\(playlist.name)\" (precomposed)")
                }
            }
        }
        
        // Check playlists
        for playlist in SoundLibrary.shared.playlists {
            if playlist.soundIDs.contains(sound.id) || playlist.selectedSoundIDs.contains(sound.id) {
                if !refs.contains("playlist \"\(playlist.name)\"") {
                    refs.append("playlist \"\(playlist.name)\"")
                }
            }
        }
        
        return refs.isEmpty ? "nothing" : refs.joined(separator: ", ")
    }
    
    private func isSoundReferenced(_ sound: ImportedSound) -> Bool {
        // Check alarms
        for alarm in alarms {
            if case .imported(let id) = alarm.sound, id == sound.id {
                return true
            }
            if case .random(let pid) = alarm.sound {
                let playlist = try? SoundLibrary.shared.playlist(for: pid)
                if playlist?.soundIDs.contains(sound.id) == true || playlist?.selectedSoundIDs.contains(sound.id) == true {
                    return true
                }
            }
            if case .precomposedPlaylist(let pid, _) = alarm.sound {
                let playlist = try? SoundLibrary.shared.playlist(for: pid)
                if playlist?.soundIDs.contains(sound.id) == true || playlist?.selectedSoundIDs.contains(sound.id) == true {
                    return true
                }
            }
        }
        // Check all playlists
        for playlist in SoundLibrary.shared.playlists {
            if playlist.soundIDs.contains(sound.id) || playlist.selectedSoundIDs.contains(sound.id) {
                return true
            }
        }
        return false
    }
    
    private func importSound(from url: URL) async {
        do {
            let _ = try await SoundLibrary.shared.importMP3(from: url)
            importError = nil
        } catch {
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
    
    private func importFolder(from url: URL) async {
        do {
            let _ = try await SoundLibrary.shared.importFolder(from: url)
            importError = nil
        } catch {
            importError = "Folder import failed: \(error.localizedDescription)"
        }
    }
}
