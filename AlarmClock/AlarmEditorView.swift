import SwiftUI

struct AlarmEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let existingAlarm: AlarmRecord?
    let onSave: (AlarmRecord) async -> Void

    @State private var label: String
    @State private var selectedTime: Date
    @State private var repeatRule: AlarmRepeatRule
    @State private var customDays: Set<Int>
    @State private var oneTimeDate: Date
    @State private var adjustmentStep: Int

    init(existingAlarm: AlarmRecord? = nil, onSave: @escaping (AlarmRecord) async -> Void) {
        self.existingAlarm = existingAlarm
        self.onSave = onSave
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

                Picker("Adjustment Step", selection: $adjustmentStep) {
                    ForEach([1, 5, 10, 15, 30], id: \.self) { value in
                        Text("\(value) minutes").tag(value)
                    }
                }
            }
            .navigationTitle(existingAlarm == nil ? "Add Alarm" : "Edit Alarm")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let components = Calendar.autoupdatingCurrent.dateComponents([.hour, .minute], from: selectedTime)
                        let time = AlarmTime(hour: components.hour ?? 0, minute: components.minute ?? 0)
                        let alarm = AlarmRecord(
                            id: existingAlarm?.id ?? UUID(),
                            label: label,
                            time: time,
                            repeatRule: resolvedRepeatRule,
                            oneTimeDate: repeatSelection.wrappedValue == .never ? resolvedOneTimeDate(time: time) : nil,
                            isEnabled: existingAlarm?.isEnabled ?? true,
                            adjustmentStepMinutes: adjustmentStep,
                            overrides: existingAlarm?.overrides ?? [:]
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
