import SwiftUI
import AlarmKit
import AlarmClockShared

struct FullscreenClockView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentTime = Date()
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        ZStack {
            ThemeManager.shared.colors.background
                .ignoresSafeArea()
            
            VStack(spacing: 8) {
                // Close button top-right
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                }
                
                Spacer()
                
                // Large time display with morph seconds (12-hour, no AM/PM, :ss)
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(hoursMinutesString)
                        .font(.system(size: 96, weight: .thin, design: .rounded))
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.35), value: hoursMinutesString)

                    Text(":")
                        .font(.system(size: 96, weight: .thin, design: .rounded))
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)

                    MorphSecondsView(
                        seconds: Calendar.current.component(.second, from: currentTime),
                        color: ThemeManager.shared.colors.accent,
                        style: ThemeManager.shared.secondsMorphStyle,
                        font: .system(size: 96, weight: .thin, design: .rounded),
                        gooBlur: 9
                    )
                }
                .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
                
                Spacer()
                
                // Next alarm line at bottom
                if let nextAlarm = nextAlarmInfo {
                    Text(nextAlarm)
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .padding(.bottom, 40)
                }
            }
            .padding(.horizontal, 20)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            currentTime = Date()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(timer) { _ in
            currentTime = Date()
        }
    }
    
    private var hoursMinutesString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm"
        return formatter.string(from: currentTime)
    }
    
    private var nextAlarmInfo: String? {
        // Get the next alarm from the coordinator's published nextOccurrence
        guard let coordinator = AlarmCoordinator.sharedInstance,
              let nextOccurrence = coordinator.nextOccurrence,
              let alarm = coordinator.currentEngine.alarm(id: nextOccurrence.alarmID) else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        let timeString = formatter.string(from: nextOccurrence.effectiveDate)
        let label = alarm.label.isEmpty ? "Alarm" : alarm.label
        return "Next alarm: \(label) at \(timeString)"
    }
}

#Preview {
    FullscreenClockView()
}