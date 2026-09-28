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
    @State private var showingTestAlarm = false
    @State private var testDelay: TimeInterval = 60 // Default 60 seconds
    @State private var testAlarmScheduled = false
    @State private var testAlarmSound: String?
    @State private var testAlarmLoudness: AlarmLoudness?
    @State private var testAlarmTask: Task<Void, Never>?

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
            Form {
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

                    // Show next song for random mode
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

                Section("Alarm Sound Loudness") {
                    Picker("Loudness", selection: $selectedLoudness) {
                        ForEach(AlarmLoudness.allCases) { loudness in
                            Text(loudness.displayName).tag(loudness)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("100% = original audio amplitude. Lower settings generate a quieter audio asset for AlarmKit.")
                        .font(.caption2)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }

                Picker("Adjustment Step", selection: $adjustmentStep) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { value in
                        Text("\(value) minutes").tag(value)
                    }
                }

                if existingAlarm != nil {
                    Section("Test Alarm") {
                        if !testAlarmScheduled {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Text("Test Delay")
                                    Spacer()
                                    Picker("Delay", selection: $testDelay) {
                                        Text("10 seconds").tag(TimeInterval(10))
                                        Text("30 seconds").tag(TimeInterval(30))
                                        Text("60 seconds").tag(TimeInterval(60))
                                        Text("90 seconds").tag(TimeInterval(90))
                                        Text("2 minutes").tag(TimeInterval(120))
                                    }
                                    .pickerStyle(.menu)
                                    .frame(width: 140)
                                }

                                Button {
                                    Task {
                                        await scheduleTestAlarm()
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "speaker.wave.3.fill")
                                        Text("Test Alarm")
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(ThemeManager.shared.colors.accent)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                    Text("Test alarm scheduled")
                                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                                    Spacer()
                                    Button("Cancel Test") {
                                        cancelTestAlarm()
                                    }
                                    .foregroundStyle(ThemeManager.shared.colors.destructive)
                                }

                                if let sound = testAlarmSound {
                                    HStack {
                                        Image(systemName: "music.note")
                                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                                        Text("Sound: \(sound)")
                                            .font(.caption)
                                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                                    }
                                }

                                if let loudness = testAlarmLoudness {
                                    HStack {
                                        Image(systemName: "speaker.wave.2")
                                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                                        Text("Loudness: \(loudness.displayName)")
                                            .font(.caption)
                                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                                    }
                                }

                                Text("This is a real AlarmKit test — not an audio preview. The system alarm UI will appear with Stop button.")
                                    .font(.caption2)
                                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle(existingAlarm == nil ? "Add Alarm" : "Edit Alarm")
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: selectedTime)
                        let time = AlarmTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
                        let oneTimeDate: Date? = repeatSelection.wrappedValue == .never ? resolvedOneTimeDate(time: time) : nil
                        let alarm = AlarmRecord(
                            id: existingAlarm?.id ?? UUID(),
                            label: label,
                            time: time,
                            repeatRule: resolvedRepeatRule,
                            oneTimeDate: oneTimeDate,
                            isEnabled: existingAlarm?.isEnabled ?? true,
                            adjustmentStepMinutes: adjustmentStep,
                            overrides: existingAlarm?.overrides ?? [:],
                            sound: selectedSound,
                            loudness: selectedLoudness
                        )
                        Task {
                            await onSave(alarm)
                            dismiss()
                        }
                    }
                    .disabled(repeatSelection.wrappedValue == .custom && customDays.isEmpty)
                }
            }
        }
        .background(ThemeManager.shared.colors.background)
        .sheet(isPresented: $showingSoundPicker) {
            SoundPickerView(selectedSound: $selectedSound)
        }
        .onDisappear {
            testAlarmTask?.cancel()
        }
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

        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: selectedTime)
        let time = AlarmTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
        let oneTimeDate: Date? = repeatSelection.wrappedValue == .never ? resolvedOneTimeDate(time: time) : nil
        let alarm = AlarmRecord(
            id: existingAlarm?.id ?? UUID(),
            label: label,
            time: time,
            repeatRule: resolvedRepeatRule,
            oneTimeDate: oneTimeDate,
            isEnabled: true,
            adjustmentStepMinutes: adjustmentStep,
            overrides: existingAlarm?.overrides ?? [:],
            sound: selectedSound,
            loudness: selectedLoudness
        )

        // Determine what sound will be used for display
        var displaySound = "Default"
        var displayLoudness = selectedLoudness

        displaySound = soundDisplayName(for: selectedSound)

        testAlarmSound = displaySound
        testAlarmLoudness = displayLoudness
        testAlarmScheduled = true

        testAlarmTask = Task {
            await onTestAlarm(alarm, testDelay)
            await MainActor.run {
                testAlarmScheduled = false
                testAlarmSound = nil
                testAlarmLoudness = nil
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
        testAlarmScheduled = false
        testAlarmSound = nil
        testAlarmLoudness = nil
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
