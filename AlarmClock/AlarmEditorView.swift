import SwiftUI
import UniformTypeIdentifiers
import AlarmClockShared

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingAlarm: AlarmRecord?
    let alarms: [AlarmRecord]
    let onSave: (AlarmRecord) async -> Void
    let onTestAlarm: ((AlarmRecord, TimeInterval) async -> Void)?

    @State private var label: String
    @State private var selectedTime: Date
    @State private var repeatRule: AlarmRepeatRule
    @State private var customDays: Set<Int>
    @State private var oneTimeDate: Date
    @State private var selectedSound: AlarmSound
    @State private var selectedLoudness: AlarmLoudness
    @State private var snoozeDurationMinutes: Int
    // TASK 3: Alarm behaviour options
    @State private var vibrate: Bool = true
    @State private var fadeInEnabled: Bool = false
    @State private var fadeInSeconds: Int = 10
    @State private var silenceAfterMinutes: Int? = nil
    @State private var loopSound: Bool = true
    @State private var showingSoundPicker = false
    @State private var isSaving = false
    @State private var draftID = UUID()
    // Capture the alarm ID at init so a nil existingAlarm at save time
    // can never silently create a second alarm.
    private let alarmID: UUID
    
    // Simplified test alarm state
    private enum TestAlarmState: Equatable {
        case idle
        case starting
        case success
        case error(String)
    }
    
    @State private var testAlarmState: TestAlarmState = .idle
    @State private var testAlarmTask: Task<Void, Never>?
    private let testSchedulingDelay: TimeInterval = 10 // Internal minimal delay for reliable scheduling

    init(existingAlarm: AlarmRecord? = nil, alarms: [AlarmRecord], onSave: @escaping (AlarmRecord) async -> Void, onTestAlarm: ((AlarmRecord, TimeInterval) async -> Void)? = nil) {
        self.existingAlarm = existingAlarm
        self.alarms = alarms
        self.onSave = onSave
        self.onTestAlarm = onTestAlarm
        // Capture the alarm ID once at init
        self.alarmID = existingAlarm?.id ?? UUID()
        let calendar = Calendar.autoupdatingCurrent
        let now = Date.now
        let nowComponents = calendar.dateComponents([.hour, .minute], from: now)
        let time = existingAlarm?.time ?? AlarmTime(hour: nowComponents.hour ?? 7, minute: nowComponents.minute ?? 0)
        let selectedTime = calendar.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? .now
        _label = State(initialValue: existingAlarm?.label ?? "")
        _selectedTime = State(initialValue: selectedTime)
        _repeatRule = State(initialValue: existingAlarm?.repeatRule ?? .daily)
        if case .custom(let days) = existingAlarm?.repeatRule {
            _customDays = State(initialValue: days)
        } else {
            _customDays = State(initialValue: [])
        }
        _oneTimeDate = State(initialValue: existingAlarm?.oneTimeDate ?? Date.now.addingTimeInterval(3_600))
        _selectedSound = State(initialValue: existingAlarm?.sound ?? .systemDefault)
        _selectedLoudness = State(initialValue: existingAlarm?.loudness ?? .defaultValue)
        _snoozeDurationMinutes = State(initialValue: existingAlarm?.snoozeDurationMinutes ?? 10)
        // TASK 3: Initialize alarm behaviour options from existingAlarm
        _vibrate = State(initialValue: existingAlarm?.vibrate ?? true)
        _fadeInEnabled = State(initialValue: existingAlarm?.fadeInEnabled ?? false)
        _fadeInSeconds = State(initialValue: existingAlarm?.fadeInSeconds ?? 10)
        _silenceAfterMinutes = State(initialValue: existingAlarm?.silenceAfterMinutes)
        _loopSound = State(initialValue: existingAlarm?.loopSound ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                scheduleFields
                soundSection
                loudnessSection
                snoozeSection
                alarmBehaviourSection
                if existingAlarm != nil {
                    testAlarmSection
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle(existingAlarm == nil ? "Add Alarm" : "Edit Alarm")
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [
                        .icon("Cancel", systemImage: "xmark") { dismiss() }
                    ],
                    trailingActions: [
                        .icon("Save", systemImage: "checkmark", isEnabled: !(isSaving || (repeatSelection.wrappedValue == .custom && customDays.isEmpty))) { saveAlarm() }
                    ]
                )
            }
        }
        .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
        .background(ThemeManager.shared.colors.background)
        .sheet(isPresented: $showingSoundPicker) {
            SoundPickerView(selectedSound: $selectedSound, alarms: alarms)
        }
        .onChange(of: selectedLoudness) { _, newValue in
            // Start preview when loudness changes via wheel picker
            startLoudnessPreview()
        }
        .onDisappear {
            testAlarmTask?.cancel()
            stopLoudnessPreview()
        }
    }
    @ViewBuilder
    private var scheduleFields: some View {
        DatePicker("Time", selection: $selectedTime, displayedComponents: .hourAndMinute)
            .datePickerStyle(.wheel)
        TextField("Label", text: $label)
        Picker("Repeat", selection: repeatSelection) {
            Text("Never").tag(RepeatSelection.never)
            Text("Every Day").tag(RepeatSelection.daily)
            Text("Weekdays").tag(RepeatSelection.weekdays)
            Text("Weekends").tag(RepeatSelection.weekends)
            Text("Custom").tag(RepeatSelection.custom)
        }
        if repeatSelection.wrappedValue == .never {
            DatePicker("Date", selection: $oneTimeDate, in: Date.now...)
        }
        if repeatSelection.wrappedValue == .custom {
            Section("Repeat Days") {
                ForEach(1...7, id: \.self) { weekday in
                    Toggle(Calendar.current.weekdaySymbols[weekday - 1], isOn: dayBinding(weekday))
                }
            }
        }
    }
    private var soundSection: some View {
        Section("Sound") {
            Button {
                showingSoundPicker = true
            } label: {
                HStack {
                    Text("Alarm Sound")
                    Spacer()
                    Text(selectedSound.displayName)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    Image(systemName: "chevron.right")
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
            }
            .buttonStyle(.plain)
            RandomModeNextSongView(selectedSound: selectedSound)
        }
    }
    private var loudnessSection: some View {
        Section("Alarm Sound Loudness") {
            AccentWheelPicker(
                values: Array(stride(from: 0, through: 100, by: 5)),
                display: { "\($0)%" },
                selection: loudnessIntBinding,
                accent: ThemeManager.shared.colors.accent,
                secondary: ThemeManager.shared.colors.secondaryText
            )
            .frame(height: 130)
        }
    }

    private var loudnessIntBinding: Binding<Int> {
        Binding(
            get: { selectedLoudness.percentage },
            set: { selectedLoudness = AlarmLoudness($0) }
        )
    }
    
    @State private var loudnessPreviewTask: Task<Void, Never>?
    @State private var loudnessPreviewURL: URL?
    @State private var loudnessPreviewSoundID: String?
    @State private var loudnessChangeDebounceTask: Task<Void, Never>?
    
    private func startLoudnessPreview() {
        // Get the sound URL for the selected sound
        let soundID = getSoundIDForPreview()
        guard let url = getSoundURLForPreview() else { return }
        
        loudnessPreviewURL = url
        loudnessPreviewSoundID = soundID
        
        // Start playing the preview with initial volume
        SoundPreviewService.shared.play(url: url, id: soundID ?? "loudness-preview")
        updatePreviewVolume()
        
        // Cancel any existing debounce task
        loudnessChangeDebounceTask?.cancel()
        
        // Schedule stop after ~2 seconds of no change
        loudnessChangeDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            if !Task.isCancelled {
                stopLoudnessPreview()
            }
        }
    }
    
    private func stopLoudnessPreview() {
        loudnessPreviewTask?.cancel()
        loudnessPreviewTask = nil
        loudnessChangeDebounceTask?.cancel()
        loudnessChangeDebounceTask = nil
        SoundPreviewService.shared.stop()
        loudnessPreviewURL = nil
        loudnessPreviewSoundID = nil
    }
    
    private func updatePreviewVolume() {
        if let player = SoundPreviewService.shared.player,
           SoundPreviewService.shared.playingSoundID == (loudnessPreviewSoundID ?? "loudness-preview") {
            let volume = selectedLoudness.gainFactor
            player.volume = Float(volume)
        }
    }
    
    private func getSoundURLForPreview() -> URL? {
        switch selectedSound {
        case .systemDefault:
            return SoundPreviewService.bundledSoundURL(for: "system_default")
        case .builtIn(let name):
            return SoundPreviewService.bundledSoundURL(for: name)
        case .imported(let id):
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }),
               let soundsDir = SoundLibrary.shared.soundsDirectory {
                return sound.localURL(soundsDirectory: soundsDir)
            }
            return nil
        case .random(let playlistID):
            // For random playlists, pick the first sound
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
               let firstSoundID = playlist.soundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let soundsDir = SoundLibrary.shared.soundsDirectory {
                return sound.localURL(soundsDirectory: soundsDir)
            }
            return nil
        case .precomposedPlaylist(let playlistID, _):
            // For precomposed playlists, we can't easily get a single sound
            // Fall back to first sound in the playlist
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
               let firstSoundID = playlist.soundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let soundsDir = SoundLibrary.shared.soundsDirectory {
                return sound.localURL(soundsDirectory: soundsDir)
            }
            return nil
        }
    }
    
    private func getSoundIDForPreview() -> String? {
        switch selectedSound {
        case .systemDefault:
            return "system_default"
        case .builtIn(let name):
            return name
        case .imported(let id):
            return id.uuidString
        case .random(let pid):
            return "random-\(pid.uuidString)"
        case .precomposedPlaylist(let pid, _):
            return "precomposed-\(pid.uuidString)"
        }
    }
    
    private var snoozeSection: some View {
        Section("Snooze Duration") {
            HStack(spacing: 8) {
                ForEach([5, 10, 15], id: \.self) { minutes in
                    Button {
                        snoozeDurationMinutes = minutes
                    } label: {
                        Text("\(minutes) min")
                            .font(.callout)
                            .foregroundStyle(snoozeDurationMinutes == minutes ? .white : ThemeManager.shared.colors.secondaryText)
                            .underline(false)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderless)
                    .background(
                        snoozeDurationMinutes == minutes
                            ? ThemeManager.shared.colors.accent
                            : ThemeManager.shared.colors.accent.opacity(0.15)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(ThemeManager.shared.colors.accent.opacity(0.5), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
    
    private var alarmBehaviourSection: some View {
        Section("Alarm Behaviour") {
            Toggle("Vibrate", isOn: $vibrate)
            
            Toggle("Fade In", isOn: $fadeInEnabled)
            if fadeInEnabled {
                Picker("Fade In Duration", selection: $fadeInSeconds) {
                    Text("5 s").tag(5)
                    Text("10 s").tag(10)
                    Text("15 s").tag(15)
                    Text("30 s").tag(30)
                    Text("60 s").tag(60)
                }
                .pickerStyle(.menu)
            }
            
            Picker("Silence After", selection: Binding(
                get: { silenceAfterMinutes ?? -1 },
                set: { silenceAfterMinutes = $0 == -1 ? nil : $0 }
            )) {
                Text("Never").tag(-1)
                Text("1 min").tag(1)
                Text("2 min").tag(2)
                Text("5 min").tag(5)
                Text("10 min").tag(10)
                Text("15 min").tag(15)
                Text("30 min").tag(30)
            }
            .pickerStyle(.menu)
            
            Toggle("Loop Sound", isOn: $loopSound)
        }
    }
    
    private var testAlarmSection: some View {
        Section("Test Alarm") {
            if testAlarmState != .idle {
                activeTestAlarmView
            } else {
                testAlarmButton
            }
        }
    }
    
    private var testAlarmButton: some View {
        Button {
            Task { await scheduleTestAlarm() }
        } label: {
            HStack {
                Image(systemName: "speaker.wave.3.fill")
                Text(testButtonLabel)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(testButtonTint)
        .disabled(testAlarmState != .idle)
        .animation(.easeInOut(duration: 0.15), value: testAlarmState)
    }
    
    private var testButtonLabel: String {
        switch testAlarmState {
        case .idle: return "Test"
        case .starting: return "Starting…"
        case .success: return "Test Scheduled"
        case .error: return "Test"
        }
    }
    
    private var testButtonTint: Color {
        switch testAlarmState {
        case .idle: return ThemeManager.shared.colors.accent
        case .starting: return ThemeManager.shared.colors.accent.opacity(0.6)
        case .success: return .green
        case .error: return ThemeManager.shared.colors.destructive
        }
    }
    
    private var activeTestAlarmView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if testAlarmState == .starting {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Scheduling test alarm…")
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                } else if case .error(let message) = testAlarmState {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                    Text(message)
                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                        .font(.caption)
                } else if testAlarmState == .success {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Test alarm scheduled successfully")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
            }
        }
        .padding(.vertical, 4)
    }
    private func saveAlarm() {
        guard !isSaving else { return }
        isSaving = true
        // Stable draft ID: a stray second tap updates the same draft
        // instead of inserting a second alarm.
        let alarm = makeAlarm()
        Task {
            await onSave(alarm)
            isSaving = false
            dismiss()
        }
    }
    private func makeAlarm() -> AlarmRecord {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: selectedTime)
        let time = AlarmTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        let date = repeatSelection.wrappedValue == .never ? resolvedOneTimeDate(time: time) : nil
        
        // Diagnostic line to track what's happening
        let existingID = existingAlarm?.id.uuidString ?? "nil"
        SmartWakeDebugLog.log("EDITOR SAVE: existingAlarm=\(existingID) using=\(alarmID.uuidString)")
        
        let alarm: AlarmRecord = AlarmRecord(
            id: alarmID,
            label: label,
            time: time,
            repeatRule: resolvedRepeatRule,
            oneTimeDate: date,
            isEnabled: true,
            adjustmentStepMinutes: 10,
            overrides: existingAlarm?.overrides ?? [:],
            sound: selectedSound,
            loudness: selectedLoudness,
            snoozeDurationMinutes: snoozeDurationMinutes,
            vibrate: vibrate,
            fadeInEnabled: fadeInEnabled,
            fadeInSeconds: fadeInSeconds,
            silenceAfterMinutes: silenceAfterMinutes,
            loopSound: loopSound
        )
        return alarm
    }
    private var repeatSelection: Binding<RepeatSelection> {
        Binding(
            get: { RepeatSelection(rule: repeatRule) },
            set: { selection in repeatRule = selection.rule(customDays: customDays) }
        )
    }

    private var resolvedRepeatRule: AlarmRepeatRule {
        repeatSelection.wrappedValue.rule(customDays: customDays)
    }

    private func dayBinding(_ weekday: Int) -> Binding<Bool> {
        Binding(
            get: { customDays.contains(weekday) },
            set: { enabled in
                if enabled { customDays.insert(weekday) } else { customDays.remove(weekday) }
                repeatRule = .custom(customDays)
            }
        )
    }

    private func resolvedOneTimeDate(time: AlarmTime) -> Date {
        var components = Calendar.autoupdatingCurrent.dateComponents([.year, .month, .day], from: oneTimeDate)
        components.hour = time.hour
        components.minute = time.minute
        components.second = 0
        return Calendar.autoupdatingCurrent.date(from: components) ?? oneTimeDate
    }

    private func getNextRandomSound(for playlist: Playlist) -> UUID? {
        // For display purposes, just return the first sound
        // The actual random selection happens at scheduling time
        return playlist.soundIDs.first
    }

    private func scheduleTestAlarm() async {
        guard let onTestAlarm else { return }
        
        // Cancel any existing test alarm task
        testAlarmTask?.cancel()
        
        // Immediate pressed feedback
        testAlarmState = .starting
        
        let alarm = makeAlarm()
        
        testAlarmTask = Task {
            await onTestAlarm(alarm, testSchedulingDelay)
            
            // Check if task was cancelled
            if !Task.isCancelled {
                await MainActor.run {
                    testAlarmState = .success
                    
                    // Auto-reset to idle after showing success briefly
                    Task {
                        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                        if !Task.isCancelled {
                            await MainActor.run {
                                testAlarmState = .idle
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func soundDisplayName(for sound: AlarmSound) -> String {
        switch sound {
        case .systemDefault:
            return "System Default"
        case .builtIn(let name):
            return name
        case .imported(let id):
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                return sound.name
            }
            return "Imported"
        case .random(let playlistID):
            if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }),
               let firstSoundID = playlist.soundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }) {
                return "\(sound.name) (from \(playlist.name))"
            }
            return "Random"
        case .precomposedPlaylist(let playlistID, _):
            if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }),
               let firstSoundID = playlist.soundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }) {
                return "\(sound.name) (from \(playlist.name) — precomposed)"
            }
            return "Precomposed Playlist"
        }
    }

    private func cancelTestAlarm() {
        testAlarmTask?.cancel()
        testAlarmTask = nil
        testAlarmState = .idle
    }
}

private enum RepeatSelection: Hashable {
    case never
    case daily
    case weekdays
    case weekends
    case custom

    init(rule: AlarmRepeatRule) {
        switch rule {
        case .never: self = .never
        case .daily: self = .daily
        case .weekdays: self = .weekdays
        case .weekends: self = .weekends
        case .custom: self = .custom
        }
    }

    func rule(customDays: Set<Int>) -> AlarmRepeatRule {
        switch self {
        case .never: .never
        case .daily: .daily
        case .weekdays: .weekdays
        case .weekends: .weekends
        case .custom: .custom(customDays)
        }
    }
}

struct RandomModeNextSongView: View {
    let selectedSound: AlarmSound

    var body: some View {
        if case .random(let playlistID) = selectedSound {
            let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID })
            if let playlist {
                let nextSoundID = getNextRandomSound(for: playlist)
                if let nextSoundID {
                    let nextSound = SoundLibrary.shared.importedSounds.first(where: { $0.id == nextSoundID })
                    if let nextSound {
                        HStack {
                            Image(systemName: "shuffle")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                                .font(.caption)
                            Text("Next alarm song: \(nextSound.name)")
                                .font(.caption)
                                .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        }
                        .padding(.leading, 4)
                    }
                }
            }
        }
    }

    private func getNextRandomSound(for playlist: Playlist) -> UUID? {
        // For display purposes, just return the first sound
        // The actual random selection happens at scheduling time
        return playlist.soundIDs.first
    }
}
