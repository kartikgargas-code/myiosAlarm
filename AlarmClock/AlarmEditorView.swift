import SwiftUI
import UniformTypeIdentifiers

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingAlarm: AlarmRecord?
    let onSave: (AlarmRecord) async -> Void
    let onTestAlarm: ((AlarmRecord, TimeInterval) async -> Void)?

    @State private var label: String
    @State private var selectedTime: Date
    @State private var repeatRule: AlarmRepeatRule
    @State private var customDays: Set<Int>
    @State private var oneTimeDate: Date
    @State private var adjustmentStep: Int
    @State private var selectedSound: AlarmSound
    @State private var selectedLoudness: AlarmLoudness
    @State private var showingSoundPicker = false
    
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

    init(existingAlarm: AlarmRecord? = nil, onSave: @escaping (AlarmRecord) async -> Void, onTestAlarm: ((AlarmRecord, TimeInterval) async -> Void)? = nil) {
        self.existingAlarm = existingAlarm
        self.onSave = onSave
        self.onTestAlarm = onTestAlarm
        let calendar = Calendar.autoupdatingCurrent
        let time = existingAlarm?.time ?? AlarmTime(hour: 7, minute: 0)
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
        _adjustmentStep = State(initialValue: existingAlarm?.adjustmentStepMinutes ?? 10)
        _selectedSound = State(initialValue: existingAlarm?.sound ?? .systemDefault)
        _selectedLoudness = State(initialValue: existingAlarm?.loudness ?? .defaultValue)
    }

    var body: some View {
        NavigationStack {
            editorForm
                .navigationTitle(existingAlarm == nil ? "Add Alarm" : "Edit Alarm")
                .scrollContentBackground(.hidden)
                .background(ThemeManager.shared.colors.background)
                .toolbar { editorToolbar }
        }
        .background(ThemeManager.shared.colors.background)
        .sheet(isPresented: $showingSoundPicker) {
            SoundPickerView(selectedSound: $selectedSound)
        }
        .onDisappear {
            testAlarmTask?.cancel()
        }
    }
    private var editorForm: some View {
        Form {
            scheduleFields
            soundSection
            loudnessSection
            adjustmentStepPicker
            if existingAlarm != nil {
                testAlarmSection
            }
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
            HStack {
                Text("Loudness")
                Spacer()
                Text(selectedLoudness.displayName)
                    .monospacedDigit()
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            Slider(value: loudnessBinding, in: 0...100, step: 1)
        }
    }

    private var loudnessBinding: Binding<Double> {
        Binding(
            get: { Double(selectedLoudness.percentage) },
            set: { selectedLoudness = AlarmLoudness(Int($0.rounded())) }
        )
    }
    private var adjustmentStepPicker: some View {
        Picker("Adjustment Step", selection: $adjustmentStep) {
            ForEach([1, 5, 10, 15, 30], id: \.self) { value in
                Text("\(value) minutes").tag(value)
            }
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
    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { saveAlarm() }
                .disabled(repeatSelection.wrappedValue == .custom && customDays.isEmpty)
        }
    }
    private func saveAlarm() {
        let alarm = makeAlarm(isEnabled: existingAlarm?.isEnabled ?? true)
        Task {
            await onSave(alarm)
            dismiss()
        }
    }
    private func makeAlarm(isEnabled: Bool) -> AlarmRecord {
        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: selectedTime)
        let time = AlarmTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        let date = repeatSelection.wrappedValue == .never ? resolvedOneTimeDate(time: time) : nil
        return AlarmRecord(
            id: existingAlarm?.id ?? UUID(),
            label: label,
            time: time,
            repeatRule: resolvedRepeatRule,
            oneTimeDate: date,
            isEnabled: isEnabled,
            adjustmentStepMinutes: adjustmentStep,
            overrides: existingAlarm?.overrides ?? [:],
            sound: selectedSound,
            loudness: selectedLoudness
        )
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
        
        let alarm = makeAlarm(isEnabled: true)
        
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
