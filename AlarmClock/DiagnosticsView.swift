import SwiftUI
import AlarmKit
import AlarmClockShared
import UniformTypeIdentifiers
import os.log

struct DiagnosticsView: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: AlarmCoordinator
    
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
        .safeAreaInset(edge: .bottom) {
            BottomActionsBar(
                leadingActions: [
                    .custom("Copy (40 lines)") { copyFilteredLog() },
                    .custom("Clear") { clearLog() },
                    .custom("Refresh") { loadLog() }
                ],
                trailingActions: [
                    .primary("Done") { dismiss() }
                ]
            )
        }
        .onAppear {
            loadLog()
            loadBuildFingerprint()
            loadCacheStats()
        }
        .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
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
            if let lastEvent = coordinator.playlistDiagnostics.playbackHistory.last {
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
            
            if let next = coordinator.nextOccurrence,
               let alarm = coordinator.alarms.first(where: { $0.id == next.alarmID }) {
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

#Preview {
    DiagnosticsView(coordinator: AlarmCoordinator())
}