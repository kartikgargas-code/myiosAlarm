import SwiftUI
import AlarmClockShared

/// Dedicated Next Alarm control screen for Lock Screen widget and control navigation.
/// Reuses the existing alarm-management implementation without duplicating scheduling logic.
struct NextAlarmControlView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var provider: NextAlarmProvider
    
    private var snapshot: NextAlarmSnapshot? {
        provider.coordinator.nextAlarmSnapshot
    }
    
    @State private var customDate = Date.now.addingTimeInterval(600)
    @State private var showCustomTimePicker = false
    @State private var showingSkipConfirmation = false
    @State private var lastActionMessage: String? = nil
    
    var body: some View {
        NavigationStack {
            Group {
                if let snapshot = snapshot {
                    nextAlarmContent(snapshot)
                } else {
                    emptyState
                }
            }
            .navigationTitle("Next Alarm")
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [],
                    trailingActions: [
                        .primary("Done") { dismiss() }
                    ],
                    backgroundColor: ThemeManager.shared.colors.background
                )
            }
            .alert("Skip Next Occurrence?", isPresented: $showingSkipConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Skip", role: .destructive) {
                    Task { await skipNext() }
                }
            } message: {
                Text("This will skip the next occurrence of \"\(snapshot?.label ?? "Alarm")\". The following occurrence will ring as scheduled.")
            }
            .onAppear {
                if let snapshot = snapshot {
                    customDate = snapshot.nextOccurrenceDate
                }
            }
        }
    }
    
    private func nextAlarmContent(_ snapshot: NextAlarmSnapshot) -> some View {
        let colors = ThemeManager.shared.colors
        
        return Form {
            Section("Next Occurrence") {
                LabeledContent("Alarm", value: snapshot.label)
                LabeledContent("Permanent Time", value: formatTime(snapshot.permanentTime))
                LabeledContent("Next Occurrence", value: snapshot.formattedTime)
                LabeledContent("Date", value: snapshot.dateIndicator)
                
                if snapshot.isAdjusted {
                    LabeledContent("Adjustment", value: snapshot.adjustmentDescription ?? "Adjusted")
                        .foregroundStyle(colors.accent)
                }
                
                if snapshot.isSkipped {
                    LabeledContent("Status", value: "Skipped")
                        .foregroundStyle(colors.destructive)
                }
            }
            
            Section("Adjustments") {
                // Fixed ±10 minute buttons
                HStack(spacing: 12) {
                    Button {
                        Task { await adjustNext(minutes: -10) }
                    } label: {
                        Text("−10 min")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!snapshot.isEnabled)
                    
                    Button {
                        Task { await resetNext() }
                    } label: {
                        Text("Reset")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!snapshot.isEnabled || !snapshot.isAdjusted)
                    
                    Button {
                        Task { await adjustNext(minutes: 10) }
                    } label: {
                        Text("+10 min")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!snapshot.isEnabled)
                }
                
                // Custom Time
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("Custom Time", selection: $customDate, in: Date.now...)
                        .datePickerStyle(.compact)
                    
                    Button("Apply Custom Time") {
                        Task { await setCustomTime(customDate) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!snapshot.isEnabled)
                }
                
                // Skip Next / Undo Skip
                if snapshot.isSkipped {
                    Button("Undo Skip") {
                        Task { await undoSkip() }
                    }
                    .buttonStyle(.bordered)
                    .foregroundStyle(colors.accent)
                    .disabled(!snapshot.isEnabled)
                } else {
                    Button("Skip Next", role: .destructive) {
                        showingSkipConfirmation = true
                    }
                    .disabled(!snapshot.isEnabled)
                }
            }
            
            if let message = lastActionMessage {
                Section("Last Action") {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(colors.secondaryText)
                }
            }
            
            if let error = provider.coordinator.lastError {
                Section("Scheduling Error") {
                    Text(error).foregroundStyle(colors.destructive)
                }
            }
        }
    }
    
    private var emptyState: some View {
        let colors = ThemeManager.shared.colors
        
        return ContentUnavailableView {
            Label("No Upcoming Alarm", systemImage: "alarm.waves.left.and.right.slash")
        } description: {
            Text("Create an alarm to see it here")
        } actions: {
            Button("Open Alarm List") {
                // This will dismiss and the app will show the alarm list
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .scrollContentBackground(.hidden)
        .background(colors.background)
    }
    
    // MARK: - Actions
    
    private func adjustNext(minutes: Int) async {
        guard let snapshot = snapshot else { return }
        await provider.coordinator.adjustNext(id: snapshot.alarmID, minutes: minutes)
        await updateMessage("Adjusted by \(minutes >= 0 ? "+" : "")\(minutes) minutes")
    }
    
    private func resetNext() async {
        guard let snapshot = snapshot else { return }
        await provider.coordinator.resetNext(id: snapshot.alarmID)
        await updateMessage("Reset to permanent schedule")
    }
    
    private func setCustomTime(_ date: Date) async {
        guard let snapshot = snapshot else { return }
        await provider.coordinator.setNextTime(id: snapshot.alarmID, date: date)
        await updateMessage("Set custom time to \(date.formatted(date: .omitted, time: .shortened))")
    }
    
    private func skipNext() async {
        guard let snapshot = snapshot else { return }
        await provider.coordinator.skipNext(id: snapshot.alarmID)
        await updateMessage("Skipped next occurrence")
    }
    
    private func undoSkip() async {
        guard let snapshot = snapshot else { return }
        await provider.coordinator.undoSkip(id: snapshot.alarmID)
        await updateMessage("Undid skip")
    }
    
    @MainActor
    private func updateMessage(_ message: String) async {
        lastActionMessage = message
        // Clear message after 3 seconds
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        if lastActionMessage == message {
            lastActionMessage = nil
        }
    }
    
    private func formatTime(_ time: AlarmTime) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        let date = Calendar.current.date(from: DateComponents(hour: time.hour, minute: time.minute)) ?? Date()
        return formatter.string(from: date)
    }
}

// Preview
#Preview {
    let coordinator = AlarmCoordinator()
    NextAlarmControlView()
        .environmentObject(NextAlarmProvider(coordinator: coordinator))
        .preferredColorScheme(.dark)
}