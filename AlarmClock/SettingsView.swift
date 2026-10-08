import SwiftUI
import AlarmKit
import AlarmClockShared

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingDiagnostics = false
    @State private var showingAppearance = false
    @State private var showingHistory = false
    @State private var showingSounds = false
    @State private var exportURL: URL?
    @State private var showingImportPicker = false
    @State private var coordinator = AlarmCoordinator()
    @State private var smartWakeService = SmartWakeService.shared
    
    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Button("Appearance") { showingAppearance = true }
                }
                
                Section("Diagnostics") {
                    Button("AlarmKit Diagnostics") { showingDiagnostics = true }
                }
                
                Section("History") {
                    Button("Play History") { showingHistory = true }
                }
                
                Section("Sounds") {
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
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showingDiagnostics) {
                DiagnosticsView(coordinator: coordinator)
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
        }
    }
}

// Need to import DiagnosticsView - it's defined in ContentView
// We'll need to make it accessible or duplicate the code
// For now, let's create a simple wrapper or extract it

struct DiagnosticsView: View {
    let coordinator: AlarmCoordinator
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(diagnosticsText)
                    .font(.system(.caption, design: .monospaced))
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("AlarmKit Diagnostics")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .background(ThemeManager.shared.colors.background)
    }
    
    private var diagnosticsText: String {
        var text = ""
        
        // Snapshot
        if let snapshot = coordinator.nextAlarmSnapshot {
            text += "=== NEXT ALARM SNAPSHOT ===\n"
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
        
        // AlarmKit managed alarms
        text += "=== ALARM KIT MANAGED ALARMS ===\n"
        if coordinator.alarmKitManagedAlarms.isEmpty {
            text += "NONE\n"
        } else {
            for id in coordinator.alarmKitManagedAlarms {
                text += "\(id.uuidString)\n"
            }
        }
        text += "\n"
        
        // All alarms in engine
        text += "=== ENGINE ALARMS ===\n"
        if coordinator.alarms.isEmpty {
            text += "NONE\n"
        } else {
            for alarm in coordinator.alarms {
                text += "\(alarm.id.uuidString.prefix(8)) - \(alarm.label.isEmpty ? "Alarm" : alarm.label) - \(alarm.isEnabled ? "ON" : "OFF")\n"
            }
        }
        
        return text
    }
}

#Preview {
    SettingsView()
}