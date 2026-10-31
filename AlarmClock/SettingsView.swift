import SwiftUI
import UIKit
import AlarmKit
import AlarmClockShared
import WidgetKit

/// TextField that places cursor at the start and scrolls to show the beginning
struct StartCursorTextField: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var isFocused: Binding<Bool>? = nil
    
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.delegate = context.coordinator
        field.clearButtonMode = .whileEditing
        // If we have a focus binding, store a weak reference to auto-focus
        if isFocused != nil {
            context.coordinator.textField = field
        }
        return field
    }
    
    func updateUIView(_ uiView: UITextField, context: Context) {
        if uiView.text != text {
            uiView.text = text
        }
        // Handle auto-focus when sheet appears
        if let isFocused = isFocused, isFocused.wrappedValue, !uiView.isFirstResponder {
            uiView.becomeFirstResponder()
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    final class Coordinator: NSObject, UITextFieldDelegate {
        let parent: StartCursorTextField
        private var didPositionCursor = false
        weak var textField: UITextField?
        
        init(_ parent: StartCursorTextField) {
            self.parent = parent
        }
        
        func textFieldDidBeginEditing(_ textField: UITextField) {
            // Update focus binding if provided
            if let isFocused = parent.isFocused {
                DispatchQueue.main.async {
                    isFocused.wrappedValue = true
                }
            }
            if !didPositionCursor {
                // Place cursor at the start and scroll to beginning
                let startPosition = textField.beginningOfDocument
                textField.selectedTextRange = textField.textRange(from: startPosition, to: startPosition)
                didPositionCursor = true
            }
        }
        
        func textFieldDidEndEditing(_ textField: UITextField) {
            didPositionCursor = false
            if let isFocused = parent.isFocused {
                DispatchQueue.main.async {
                    isFocused.wrappedValue = false
                }
            }
            parent.text = textField.text ?? ""
        }
        
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if let currentText = textField.text,
               let range = Range(range, in: currentText) {
                let updated = currentText.replacingCharacters(in: range, with: string)
                DispatchQueue.main.async {
                    self.parent.text = updated
                }
            }
            return true
        }
    }
}

/// Reads/writes the widget settings in the shared App Group container, so the
/// Lock Screen battery widget sees the same values the app writes here.
enum WidgetSettingsStore {
    static var defaults: UserDefaults {
        guard let group = AppGroupResolver.resolve() else { return .standard }
        return UserDefaults(suiteName: group) ?? .standard
    }
}

/// Settings row with icon tile, title, optional chevron
private struct SettingsRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let showChevron: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Icon tile: 28pt, 7pt corner radius, white SF Symbol
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(iconColor)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                
                Spacer()
                
                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
    @AppStorage("widgetBatteryPlateOpacity", store: WidgetSettingsStore.defaults) private var batteryPlateOpacity = 1.0
    @AppStorage("widgetInlineShowBattery", store: WidgetSettingsStore.defaults) private var inlineShowBattery = false
    @AppStorage("widgetHomeShowCircle", store: WidgetSettingsStore.defaults) private var homeShowCircle = true
    @AppStorage("widgetHomeShowText", store: WidgetSettingsStore.defaults) private var homeShowText = true
    @AppStorage("widgetMemoryShowCircle", store: WidgetSettingsStore.defaults) private var memoryShowCircle = true
    @AppStorage("widgetMemoryShowText", store: WidgetSettingsStore.defaults) private var memoryShowText = true
    @AppStorage("widgetMemoryCircleScale", store: WidgetSettingsStore.defaults) private var memoryCircleScale = 1.0
    @AppStorage("widgetMemoryTextScale", store: WidgetSettingsStore.defaults) private var memoryTextScale = 1.0
    @AppStorage("widgetMemoryPlateOpacity", store: WidgetSettingsStore.defaults) private var memoryPlateOpacity = 1.0
    @State private var memoryText = "Reading..."
    @State private var freedMemoryMB: Int? = nil
    @State private var showClearMemoryToast = false
    @State private var clearMemoryToastMessage = ""
    let coordinator: AlarmCoordinator
    @State private var smartWakeService = SmartWakeService.shared
    
    private var buildNumber: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        let stamp = info?["AlarmClockBuildStamp"] as? String ?? "unknown"
        return "\(version) (\(build)) \(stamp)"
    }
    
    // Track build number taps for hidden Diagnostics entry
    @State private var buildTapTimes: [Date] = []
    
    var body: some View {
        NavigationStack {
            List {
                // Group 1 (no header) - with chevrons
                Section {
                    SettingsRow(
                        icon: "paintbrush",
                        iconColor: .orange,
                        title: "Appearance",
                        showChevron: true,
                        action: { showingAppearance = true }
                    )
                    SettingsRow(
                        icon: "clock.arrow.circlepath",
                        iconColor: .blue,
                        title: "Play History",
                        showChevron: true,
                        action: { showingHistory = true }
                    )
                    SettingsRow(
                        icon: "music.note.list",
                        iconColor: .pink,
                        title: "Sounds",
                        showChevron: true,
                        action: { showingSounds = true }
                    )
                }
                
                // Group "Backup" - no chevrons (run actions directly)
                Section("Backup") {
                    SettingsRow(
                        icon: "square.and.arrow.up",
                        iconColor: .green,
                        title: "Export backup",
                        showChevron: false,
                        action: {
                            exportName = BackupRestoreService.suggestedExportName()
                            showingExportAlert = true
                        }
                    )
                    SettingsRow(
                        icon: "square.and.arrow.down",
                        iconColor: .cyan,
                        title: "Import backup",
                        showChevron: false,
                        action: { showingImportPicker = true }
                    )
                }
                
                // Group "Storage"
                Section("Storage") {
                    SettingsRow(
                        icon: "trash",
                        iconColor: .gray,
                        title: "Clear memory",
                        showChevron: false,
                        action: {
                            let result = coordinator.pruneStitchCacheNowWithResult()
                            if result.freedBytes > 0 {
                                let freedMB = Double(result.freedBytes) / (1_048_576.0)
                                clearMemoryToastMessage = "Freed \(String(format: "%.1f", freedMB)) MB"
                            } else {
                                clearMemoryToastMessage = "Nothing to clear"
                            }
                            showClearMemoryToast = true
                            refreshMemory()
                        }
                    )
                    HStack {
                        Text("In use")
                        Spacer()
                        Text(memoryText)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    }
                }

                Section("Lock Screen circles") {
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plate behind it: " + String(format: "%.0f", batteryPlateOpacity * 100) + "%")
                            .font(.caption)
                        Slider(value: $batteryPlateOpacity, in: 0.0...1.0)
                    }
                }


                Section("One-line widget") {
                    Toggle("Also show the battery", isOn: $inlineShowBattery)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                }

                Section("Home Screen widget") {
                    Toggle("Show the circle", isOn: $homeShowCircle)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    Toggle("Show the percentage", isOn: $homeShowText)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                }
                Section("Memory widget") {
                    Toggle("Show the circle", isOn: $memoryShowCircle)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    Toggle("Show the percentage", isOn: $memoryShowText)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Circle thickness: " + String(format: "%.1f", memoryCircleScale) + "\u{00d7}")
                            .font(.caption)
                        Slider(value: $memoryCircleScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Percentage size: " + String(format: "%.1f", memoryTextScale) + "\u{00d7}")
                            .font(.caption)
                        Slider(value: $memoryTextScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plate behind it: " + String(format: "%.0f", memoryPlateOpacity * 100) + "%")
                            .font(.caption)
                        Slider(value: $memoryPlateOpacity, in: 0.0...1.0)
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
                    // Hidden Diagnostics entry - tap 5 times in 3 seconds
                    Text("myNextAlarm v\(buildNumber)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            let now = Date()
                            buildTapTimes.append(now)
                            // Keep only taps within last 3 seconds
                            buildTapTimes = buildTapTimes.filter { now.timeIntervalSince($0) <= 3 }
                            if buildTapTimes.count >= 5 {
                                buildTapTimes = []
                                showingDiagnostics = true
                                SmartWakeDebugLog.log("DIAGNOSTICS opened via build-tap")
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            }
                        }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .listStyle(.insetGrouped)
            .onChange(of: "\(batteryShowCircle)|\(batteryShowText)|\(batteryCircleScale)|\(batteryTextScale)|\(batteryShowPercentSign)|\(inlineShowBattery)|\(batteryPlateOpacity)|\(homeShowCircle)|\(homeShowText)|\(memoryShowCircle)|\(memoryShowText)|\(memoryCircleScale)|\(memoryTextScale)|\(memoryPlateOpacity)") { _, _ in
                WidgetCenter.shared.reloadAllTimelines()
            }
            .onAppear { refreshMemory() }
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
            .overlay {
                if showClearMemoryToast {
                    VStack {
                        Spacer()
                        Text(clearMemoryToastMessage)
                            .font(.callout)
                            .foregroundStyle(ThemeManager.shared.colors.primaryText)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(ThemeManager.shared.colors.card.opacity(0.95))
                            .clipShape(Capsule())
                            .shadow(radius: 4)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                            .padding(.bottom, 100)
                    }
                    .animation(.easeInOut(duration: 0.2), value: showClearMemoryToast)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            showClearMemoryToast = false
                        }
                    }
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
                SoundsView(coordinator: coordinator)
            }
            .fileImporter(isPresented: $showingImportPicker, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        Task {
                            do {
                                try await BackupRestoreService.shared.importArchive(from: url)
                                SmartWakeDebugLog.log("Backup import finished - alarms rebuilt and rescheduled")
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
            .sheet(isPresented: $showingExportAlert) {
                ExportBackupSheet(exportName: $exportName, onExport: { name in
                    runExport(named: name)
                    showingExportAlert = false
                }, onCancel: {
                    showingExportAlert = false
                })
            }
        }
    }
    
    private func refreshMemory() {
        guard let used = SystemMemory.usedBytes() else {
            memoryText = "unavailable"
            return
        }
        let gb = 1_073_741_824.0
        memoryText = String(format: "%.1f of %.1f GB", Double(used) / gb, Double(SystemMemory.totalBytes()) / gb)
    }

    private func runExport(named name: String) {
        Task {
            do {
                let url = try await BackupRestoreService.shared.exportArchive(fileName: name)
                BackupRestoreService.rememberExportNumber(from: name)
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

/// Sheet for export backup with cursor at start
struct ExportBackupSheet: View {
    @Binding var exportName: String
    let onExport: (String) -> Void
    let onCancel: () -> Void
    @State private var isFieldFocused = false
    
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    StartCursorTextField(text: $exportName, placeholder: "Backup name", isFocused: $isFieldFocused)
                        .font(.body)
                }
            }
            .navigationTitle("Export Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { onExport(exportName) }
                }
            }
            .onAppear {
                // Auto-focus the field when sheet appears
                isFieldFocused = true
            }
        }
        .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
        .presentationDetents([.medium])
    }
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


enum SystemMemory {
    static func usedBytes() -> UInt64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let page = UInt64(pageSize)
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        return active + inactive + wired + compressed
    }

    static func totalBytes() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    /// Frees memory the way the cleaning apps do: ask for a large block so the phone
    /// reclaims what it is holding, then give it straight back. malloc is used so a
    /// refused request ends the loop instead of closing the app.
    static func freeMemory() async -> Int? {
        let before = usedBytes()

        let cap: UInt64 = 1_536 * 1024 * 1024
        let target = Int(min(cap, totalBytes() / 3))

        let chunk = 64 * 1024 * 1024
        var pointers: [UnsafeMutableRawPointer] = []
        var allocated = 0
        while allocated < target {
            guard let pointer = malloc(chunk) else { break }
            memset(pointer, 0, chunk)
            pointers.append(pointer)
            allocated += chunk
        }

        // Hold it for a moment: the phone needs time to actually reclaim.
        try? await Task.sleep(nanoseconds: 2_000_000_000)

        for pointer in pointers {
            free(pointer)
        }
        pointers.removeAll()

        let after = usedBytes()
        guard let before, let after, before > after else { return 0 }
        return Int((before - after) / 1_048_576)
    }
}
