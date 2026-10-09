import SwiftUI
import UIKit
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
    @State private var showingShareSheet = false
    @State private var shareURL: URL?
    @State private var showingExportSheet = false
    @State private var pendingExportName: String?
    let coordinator: AlarmCoordinator
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
                        showingExportSheet = true
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
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
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
                SoundsView(coordinator: coordinator)
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
            .sheet(isPresented: $showingShareSheet) {
                if let shareURL = shareURL {
                    ShareSheet(activityItems: [shareURL])
                }
            }
            .sheet(isPresented: $showingExportSheet, onDismiss: runPendingExport) {
                ExportBackupSheet { name in
                    pendingExportName = name
                    showingExportSheet = false
                }
            }
        }
    }
    
    private func runPendingExport() {
        guard let name = pendingExportName else { return }
        pendingExportName = nil
        Task {
            do {
                let url = try await BackupRestoreService.shared.exportArchive(fileName: name)
                shareURL = url
                showingShareSheet = true
            } catch {
                coordinator.lastError = "Export failed: \(error.localizedDescription)"
            }
        }
    }
    
    init(coordinator: AlarmCoordinator) {
        self.coordinator = coordinator
    }
}

// Export Backup Sheet
private struct ExportBackupSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onName: (String) -> Void
    @State private var name: String = ""
    
    var body: some View {
        NavigationStack {
            Form {
                Section("File Name") {
                    TextField("Backup name", text: $name)
                        .autocorrectionDisabled()
                }
                Text("Next: choose 'Save to Files' to pick a folder, or share it anywhere.")
                    .font(.footnote)
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            .navigationTitle("Export Backup")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [.icon("Cancel", systemImage: "xmark") { dismiss() }],
                    trailingActions: [.icon("Save", systemImage: "checkmark",
                                            isEnabled: !name.trimmingCharacters(in: .whitespaces).isEmpty) {
                        onName(name)
                        dismiss()
                    }]
                )
            }
            .onAppear {
                if name.isEmpty {
                    let f = DateFormatter()
                    f.dateFormat = "yyyy-MM-dd"
                    name = "AlarmClock_Backup_\(f.string(from: Date()))"
                }
            }
        }
    }
}

#Preview {
    SettingsView(coordinator: AlarmCoordinator())
}

/// SwiftUI wrapper for UIActivityViewController (system share sheet)
struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]
    let applicationActivities: [UIActivity]? = nil
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        // Exclude activities that don't make sense for a backup file
        controller.excludedActivityTypes = [
            .assignToContact,
            .saveToCameraRoll,
            .postToFlickr,
            .postToVimeo,
            .postToWeibo,
            .postToTencentWeibo
        ]
        return controller
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}