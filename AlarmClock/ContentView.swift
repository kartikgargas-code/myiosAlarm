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
    @State private var currentRingSongName: String? = nil
    @State private var pendingEnabled: [UUID: Bool] = [:]
    
    @Environment(\.scenePhase) private var scenePhase
    @State private var smartWakeService = SmartWakeService.shared
    @State private var alarmPlaybackService = AlarmPlaybackService.shared
    // Track foreground state for CC feedback gating
    @State private var isAppInForeground = true
    // Static property accessible from AlarmCoordinator
    static var isAppInForegroundStatic: Bool = true

    @State private var showingSettings = false
    
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
                }
                .scrollContentBackground(.hidden)
                .background(ThemeManager.shared.colors.background)
                .navigationTitle("myNextAlarm")
                .overlay(alignment: .bottomLeading) {
                    Button {
                        editorPresentation = EditorPresentation(id: UUID(), alarm: nil)
                    } label: {
                        Image(systemName: "plus")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                            .frame(width: 56, height: 56)
                            .appButtonChrome(shape: .circle, size: 56)
                    }
                    .padding(.leading, 20)
                    .padding(.bottom, 34)
                    .contentShape(Circle())
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                            .frame(width: 56, height: 56)
                            .appButtonChrome(shape: .circle, size: 56)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 34)
                    .contentShape(Circle())
                }
                
                // Now Ringing banner as pinned overlay
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
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
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
            .sheet(isPresented: $showingSettings) {
                SettingsView(coordinator: coordinator)
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
                            .tint(Color(red: 1.0, green: 0.72, blue: 0.0))
                    }
                }
            }
            
            Divider()
            
            Button {
                Task { await coordinator.duplicate(id: alarm.id) }
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
                    .tint(.yellow)
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
            DiagnosticsView(coordinator: coordinator)
        }
    }
}

// MARK: - New Clean Diagnostics Screen
// MARK: - Editor Presentation (item-based, travels with sheet)
struct EditorPresentation: Identifiable {
    let id: UUID
    let alarm: AlarmRecord?  // nil = Add new alarm
}

// MARK: - Sounds View (Sound Manager)
struct SoundsView: View {
    @Environment(\.dismiss) private var dismiss
    let coordinator: AlarmCoordinator
    
    @State private var showingDocumentPicker = false
    @State private var importError: String?
    @State private var pickerMode: PickerMode = .files
    private enum PickerMode { case files, folder }
    @State private var showingDeleteAll = false
    @State private var folderToDelete: String? = nil
    @State private var showingSortOptions = false
    
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
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [
                        .icon("Sort", systemImage: "arrow.up.arrow.down") { showingSortOptions = true }
                            .contextMenu(AnyView(
                                Group {
                                    Button("Delete All Tracks", role: .destructive) { showingDeleteAll = true }
                                    if !SoundLibrary.shared.importedFolders.isEmpty {
                                        Menu("Delete Folder") {
                                            ForEach(SoundLibrary.shared.importedFolders, id: \.self) { folder in
                                                Button(folder, role: .destructive) { folderToDelete = folder }
                                            }
                                        }
                                    }
                                }
                            ))
                    ],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
            }
            .confirmationDialog("Sort by", isPresented: $showingSortOptions, titleVisibility: .visible) {
                ForEach(SoundSortOption.allCases) { option in
                    Button(sortOption == option ? "\(option.rawValue)  (current)" : option.rawValue) {
                        sortOptionRaw = option.rawValue
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .confirmationDialog("Delete all tracks?", isPresented: $showingDeleteAll, titleVisibility: .visible) {
                Button("Delete All Tracks", role: .destructive) { Task { await coordinator.deleteAllImportedSounds() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Removes every imported track from the app and resets any alarm using one to Default.")
            }
            .confirmationDialog("Delete folder \"\(folderToDelete ?? "")\"?",
                isPresented: Binding(get: { folderToDelete != nil }, set: { if !$0 { folderToDelete = nil } }),
                titleVisibility: .visible) {
                Button("Delete Folder", role: .destructive) {
                    if let f = folderToDelete { Task { await coordinator.deleteImportedSounds(inFolder: f) } }
                    folderToDelete = nil
                }
                Button("Cancel", role: .cancel) { folderToDelete = nil }
            } message: {
                Text("Deletes every track in this folder and removes its playlist.")
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
        for alarm in coordinator.alarms {
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
        for alarm in coordinator.alarms {
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
