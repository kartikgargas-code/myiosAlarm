import SwiftUI
import UIKit
import AlarmKit
import AlarmClockShared
import WidgetKit

/// Reads/writes the widget settings in the shared App Group container, so the
/// Lock Screen battery widget sees the same values the app writes here.
enum WidgetSettingsStore {
    static var defaults: UserDefaults {
        let configured = Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String
            ?? "group.com.example.alarmclock"
        let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let group = resigned.first { $0 == configured || $0.hasPrefix(configured + ".") } ?? configured
        return UserDefaults(suiteName: group) ?? .standard
    }
}

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
    @State private var showingExportAlert = false
    @State private var exportName = ""
    @AppStorage("widgetBatteryShowCircle", store: WidgetSettingsStore.defaults) private var batteryShowCircle = true
    @AppStorage("widgetBatteryShowText", store: WidgetSettingsStore.defaults) private var batteryShowText = true
    @AppStorage("widgetBatteryCircleScale", store: WidgetSettingsStore.defaults) private var batteryCircleScale = 1.0
    @AppStorage("widgetBatteryTextScale", store: WidgetSettingsStore.defaults) private var batteryTextScale = 1.0
    @AppStorage("widgetBatteryShowPercentSign", store: WidgetSettingsStore.defaults) private var batteryShowPercentSign = true
    @AppStorage("widgetInlineShowBattery", store: WidgetSettingsStore.defaults) private var inlineShowBattery = false
    let coordinator: AlarmCoordinator
    @State private var smartWakeService = SmartWakeService.shared
    
    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    Button("Appearance") { showingAppearance = true }
                }
                Section("Lock Screen battery") {
                    Toggle("Show the circle", isOn: $batteryShowCircle)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    Toggle("Show the percentage", isOn: $batteryShowText)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    if batteryShowText {
                        Toggle("Show the % sign", isOn: $batteryShowPercentSign)
                            .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Circle thickness: " + String(format: "%.1f", batteryCircleScale) + "\u{00d7}")
                            .font(.caption)
                        Slider(value: $batteryCircleScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Percentage size: " + String(format: "%.1f", batteryTextScale) + "\u{00d7}")
                            .font(.caption)
                        Slider(value: $batteryTextScale, in: 0.5...3.0)
                    }
                }


                Section("One-line widget") {
                    Toggle("Also show the battery", isOn: $inlineShowBattery)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
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
                        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
                        exportName = "AlarmClock_Backup_\(f.string(from: Date()))"
                        showingExportAlert = true
                    }
                    Button("Import Backup") {
                        showingImportPicker = true
                    }
                }
                
                Section("Smart Wake") {
                    Toggle("Keep app active overnight (Smart Wake)", isOn: $smartWakeService.isSmartWakeEnabled)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
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
            .onChange(of: "\(batteryShowCircle)|\(batteryShowText)|\(batteryCircleScale)|\(batteryTextScale)|\(batteryShowPercentSign)|\(inlineShowBattery)") { _, _ in
                WidgetCenter.shared.reloadAllTimelines()
            }
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
            .alert("Export Backup", isPresented: $showingExportAlert) {
                TextField("Backup name", text: $exportName)
                Button("Cancel", role: .cancel) {}
                Button("Export") { runExport(named: exportName) }
            } message: {
                Text("Saves your alarms and settings (no audio). You'll choose where to save it next.")
            }
        }
    }
    
    private func runExport(named name: String) {
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