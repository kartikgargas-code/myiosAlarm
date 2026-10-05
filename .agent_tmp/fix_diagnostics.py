import re

with open(r'D:\myiosAlarm\AlarmClock\ContentView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# Find the old diagnosticsView and replace it
old_diagnostics = '''    private var diagnosticsView: some View {
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
                            Text("Label: \\(alarm.label.isEmpty ? "Alarm" : alarm.label)")
                            Text("ID: \\(alarm.id.uuidString)")
                            Text("Sound: \\(alarm.sound.displayName)")
                            Text("Sound ID: \\(alarm.sound.id)")
                            
                            // Show sound filename for AlarmKit
                            if case .imported(let id) = alarm.sound {
                                if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                                    Text("AlarmKit Sound File: \\(sound.fileName)")
                                        .foregroundStyle(ThemeManager.shared.colors.accent)
                                } else {
                                    Text("AlarmKit Sound File: MISSING (sound id no longer in library)")
                                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                                }
                            }
                            
                            Text("Next Fire: \\(next.effectiveDate.formatted(date: .complete, time: .standard))")
                            Text("Base Time: \\(next.baseDate.formatted(date: .complete, time: .standard))")
                            Text("Adjusted: \\(next.isAdjusted ? "Yes" : "No")")
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
                
                // Play History Section
                if !coordinator.playHistory.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Play History")
                            .font(.headline)
                        
                        ForEach(coordinator.playHistory) { entry in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.songName)
                                        .font(.subheadline)
                                    Text("Alarm: \\(entry.alarmLabel) \u2022 \\(entry.timestamp.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                
                                Spacer()
                                
                                // Toggle play/stop button for this history entry
                                Button {
                                    coordinator.playHistoryEntry(entry)
                                } label: {
                                    Image(systemName: SoundPreviewService.shared.playingSoundID == "history-\\(entry.id.uuidString)" ? "stop.circle.fill" : "play.circle.fill")
                                        .font(.title2)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                    }
                    .padding()
                }
            }
            .font(.caption.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .navigationTitle("Diagnostics")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy All Diagnostics") { 
                        let widgetDiagnosticsText = generateWidgetDiagnosticsText()
                        let smartWakeLogText = smartWakeLogForDiagnostics()
                        let combined = authorizationModel.diagnosticsText + "\n\n" + coordinator.playlistDiagnostics.diagnosticsText + "\n\n" + widgetDiagnosticsText + "\n\n" + readLiveActivityDebugLog() + "\n\n" + smartWakeLogText
                        UIPasteboard.general.string = combined
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { showingDiagnostics = false }
                }
            }
        }
    }
    }'''

new_diagnostics = '''    private var diagnosticsView: some View {
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
    }'''

content = content.replace(old_diagnostics, new_diagnostics)

# Now add the new DiagnosticsScreen struct before the final closing brace
# Find the widgetDiagnosticsSection and replace it
old_widget_section = '''    var widgetDiagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Current snapshot in memory
            if let snapshot = coordinator.nextAlarmSnapshot {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current In-Memory Snapshot")
                        .font(.subheadline.weight(.semibold))
                    Text("Alarm ID: \\(snapshot.alarmID.uuidString)")
                    Text("Label: \\(snapshot.label)")
                    Text("Next Occurrence: \\(snapshot.nextOccurrenceDate.formatted(date: .complete, time: .standard))")
                    Text("Enabled: \\(snapshot.isEnabled ? "Yes" : "No")")
                    Text("Adjusted: \\(snapshot.isAdjusted ? "Yes" : "No")")
                    if let adj = snapshot.adjustmentDescription {
                        Text("Adjustment: \\(adj)")
                    }
                    Text("Sound: \\(snapshot.sound.displayName)")
                    Text("Loudness: \\(snapshot.loudness.percentage)%")
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
                Text("Success: \\(result.success ? "YES" : "NO")")
                if let error = result.error {
                    Text("Error: \\(error)")
                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                }
                if let timestamp = result.timestamp {
                    Text("Timestamp: \\(timestamp.formatted(date: .complete, time: .standard))")
                }
            }
            .font(.caption.monospaced())
            
            Divider()
            
            // Last widget reload request
            VStack(alignment: .leading, spacing: 4) {
                Text("Last WidgetCenter Reload Request")
                    .font(.subheadline.weight(.semibold))
                if let timestamp = coordinator.lastWidgetReloadRequest {
                    Text("Timestamp: \\(timestamp.formatted(date: .complete, time: .standard))")
                    Text("Age: \\(Int(Date().timeIntervalSince(timestamp))) seconds ago")
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
                    Text("Configured: \\(configured)")
                }
                if let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], !resigned.isEmpty {
                    Text("ALTAppGroups: \\(resigned.joined(separator: ", "))")
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
            
            // Smart Wake Debug Log
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Smart Wake Debug Log")
                        .font(.headline)
                    Spacer()
                    Button("Refresh") {
                        // Force re-read from file - triggers view update via @State
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    Button("Clear Smart Wake Log") {
                        SmartWakeDebugLog.clear()
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                    Button {
                        let text = SmartWakeDebugLog.readFilteredForCopy()
                        if let text {
                            UIPasteboard.general.string = text
                            smartWakeLogCopied = true
                            smartWakeLogUnavailable = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                smartWakeLogCopied = false
                            }
                        } else {
                            smartWakeLogUnavailable = true
                            smartWakeLogCopied = false
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                smartWakeLogUnavailable = false
                            }
                        }
                    } label: {
                        Label(
                            smartWakeLogCopied ? "Copied \u2713" : (smartWakeLogUnavailable ? "Log unavailable" : "Copy Smart Wake Log"),
                            systemImage: smartWakeLogCopied ? "checkmark" : "doc.on.doc"
                        )
                    }
                    .buttonStyle(.bordered)
                    .font(.caption)
                }
                
                Text(SmartWakeDebugLog.read() ?? "No Smart Wake log entries yet.")
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
    
    
    
    
    func readLiveActivityDebugLog() -> String {
        let fileManager = FileManager.default
        guard let appGroupURL = AppGroupResolver.resolve().flatMap({
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }) else { return "App Group not available" }
        
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
            return "Error reading log: \\(error.localizedDescription)"
        }
    }
    
    func generateWidgetDiagnosticsText() -> String {
        var text = "=== WIDGET PIPELINE DIAGNOSTICS ===\n\n"
        
        // Current snapshot in memory
        if let snapshot = coordinator.nextAlarmSnapshot {
            text += "Current In-Memory Snapshot:\n"
            text += "Alarm ID: \\(snapshot.alarmID.uuidString)\n"
            text += "Label: \\(snapshot.label)\n"
            text += "Next Occurrence: \\(snapshot.nextOccurrenceDate.formatted(date: .complete, time: .standard))\n"
            text += "Enabled: \\(snapshot.isEnabled ? "Yes" : "No")\n"
            text += "Adjusted: \\(snapshot.isAdjusted ? "Yes" : "No")\n"
            if let adj = snapshot.adjustmentDescription {
                text += "Adjustment: \\(adj)\n"
            }
            text += "Sound: \\(snapshot.sound.displayName)\n"
            text += "Loudness: \\(snapshot.loudness.percentage)%\n\n"
        } else {
            text += "Current In-Memory Snapshot: NONE (no upcoming alarm)\n\n"
        }
        
        // Last write result
        let result = coordinator.lastSnapshotWriteResult
        text += "Last Snapshot Write:\n"
        text += "Success: \\(result.success ? "YES" : "NO")\n"
        if let error = result.error {
            text += "Error: \\(error)\n"
        }
        if let timestamp = result.timestamp {
            text += "Timestamp: \\(timestamp.formatted(date: .complete, time: .standard))\n"
        }
        text += "\n"
        
        // Last widget reload request
        text += "Last WidgetCenter Reload Request:\n"
        if let timestamp = coordinator.lastWidgetReloadRequest {
            text += "Timestamp: \\(timestamp.formatted(date: .complete, time: .standard))\n"
            text += "Age: \\(Int(Date().timeIntervalSince(timestamp))) seconds ago\n\n"
        } else {
            text += "Never requested\n\n"
        }
        
        // App Group configuration
        text += "App Group Configuration:\n"
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String {
            text += "Configured: \\(configured)\n"
        }
        if let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], !resigned.isEmpty {
            text += "ALTAppGroups: \\(resigned.joined(separator: ", "))\n"
        } else {
            text += "ALTAppGroups: (none)\n"
        }
        text += "\n"
        
        return text
    }
    
    // MARK: - Smart Wake Log for copy-all diagnostics
    func smartWakeLogForDiagnostics() -> String {
        let log = SmartWakeDebugLog.read() ?? "No Smart Wake log entries yet."
        return "=== SMART WAKE LOG ===\n\\(log)\n"
    }
}'''

new_code = '''    var widgetDiagnosticsSection: some View {
        // Not used - replaced by new DiagnosticsScreen
        EmptyView()
    }
    
    func readLiveActivityDebugLog() -> String {
        let fileManager = FileManager.default
        guard let appGroupURL = AppGroupResolver.resolve().flatMap({
            fileManager.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }) else { return "App Group not available" }
        
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
            return "Error reading log: \\(error.localizedDescription)"
        }
    }
    
    func generateWidgetDiagnosticsText() -> String {
        var text = "=== WIDGET PIPELINE DIAGNOSTICS ===\n\n"
        
        // Current snapshot in memory
        if let snapshot = coordinator.nextAlarmSnapshot {
            text += "Current In-Memory Snapshot:\n"
            text += "Alarm ID: \\(snapshot.alarmID.uuidString)\n"
            text += "Label: \\(snapshot.label)\n"
            text += "Next Occurrence: \\(snapshot.nextOccurrenceDate.formatted(date: .complete, time: .standard))\n"
            text += "Enabled: \\(snapshot.isEnabled ? "Yes" : "No")\n"
            text += "Adjusted: \\(snapshot.isAdjusted ? "Yes" : "No")\n"
            if let adj = snapshot.adjustmentDescription {
                text += "Adjustment: \\(adj)\n"
            }
            text += "Sound: \\(snapshot.sound.displayName)\n"
            text += "Loudness: \\(snapshot.loudness.percentage)%\n\n"
        } else {
            text += "Current In-Memory Snapshot: NONE (no upcoming alarm)\n\n"
        }
        
        // Last write result
        let result = coordinator.lastSnapshotWriteResult
        text += "Last Snapshot Write:\n"
        text += "Success: \\(result.success ? "YES" : "NO")\n"
        if let error = result.error {
            text += "Error: \\(error)\n"
        }
        if let timestamp = result.timestamp {
            text += "Timestamp: \\(timestamp.formatted(date: .complete, time: .standard))\n"
        }
        text += "\n"
        
        // Last widget reload request
        text += "Last WidgetCenter Reload Request:\n"
        if let timestamp = coordinator.lastWidgetReloadRequest {
            text += "Timestamp: \\(timestamp.formatted(date: .complete, time: .standard))\n"
            text += "Age: \\(Int(Date().timeIntervalSince(timestamp))) seconds ago\n\n"
        } else {
            text += "Never requested\n\n"
        }
        
        // App Group configuration
        text += "App Group Configuration:\n"
        if let configured = Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String {
            text += "Configured: \\(configured)\n"
        }
        if let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String], !resigned.isEmpty {
            text += "ALTAppGroups: \\(resigned.joined(separator: ", "))\n"
        } else {
            text += "ALTAppGroups: (none)\n"
        }
        text += "\n"
        
        return text
    }
    
    // MARK: - Smart Wake Log for copy-all diagnostics
    func smartWakeLogForDiagnostics() -> String {
        let log = SmartWakeDebugLog.read() ?? "No Smart Wake log entries yet."
        return "=== SMART WAKE LOG ===\n\\(log)\n"
    }
}

// MARK: - New Clean Diagnostics Screen
struct DiagnosticsScreen: View {
    @State private var logLines: [String] = []
    @State private var isLoading = false
    @State private var showUTCNotice = true
    
    @Environment(\\.dismiss) private var dismiss
    
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
                    Text("At: \\(lastEvent.timestamp.formatted(date: .abbreviated, time: .standard))")
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
                    Text("Label: \\(alarm.label.isEmpty ? "Alarm" : alarm.label)")
                    Text("ID: \\(alarm.id.uuidString.prefix(8))")
                    Text("Sound: \\(alarm.sound.displayName)")
                    Text("Next Fire: \\(next.effectiveDate.formatted(date: .complete, time: .standard))")
                    Text("Adjusted: \\(next.isAdjusted ? "Yes" : "No")")
                    if next.isAdjusted {
                        let minutes = Int(next.effectiveDate.timeIntervalSince(next.baseDate) / 60)
                        Text("Adjustment: \\(minutes > 0 ? "+" : "")\\(minutes) min")
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
            
            let status = SmartWakeService.shared.isRunning ? "ALIVE \u2014 silent loop running" : "DEAD \u2014 no silent loop"
            let color = SmartWakeService.shared.isRunning ? Color.green : Color.red
            
            Text(status)
                .font(.caption.monospaced())
                .foregroundStyle(color)
            
            Text("Status tick: \\(SmartWakeService.shared.statusTextPublished)")
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
                    ForEach(logLines, id: \\.self) { line in
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
                            return line.replacingOccurrences(of: timestampStr, with: "[\\(localStr) LOCAL]")
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
}'''

content = content.replace(old_widget_section, new_code)

with open(r'D:\myiosAlarm\AlarmClock\ContentView.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print('Done')