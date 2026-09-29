import SwiftUI
import ActivityKit
import WidgetKit
import AlarmClockShared

/// Dynamic Island Live Activity for the next alarm
struct NextAlarmLiveActivityView: View {
    let context: ActivityViewContext<NextAlarmAttributes>
    
    var body: some View {
        // This will be handled by the ActivityConfiguration
    }
}

/// Dynamic Island presentation for the next alarm
struct NextAlarmDynamicIsland: View {
    let context: ActivityViewContext<NextAlarmAttributes>
    
    var body: some View {
        DynamicIsland {
            // Expanded presentation
            DynamicIslandExpandedRegion(.leading) {
                HStack(spacing: 8) {
                    Image(systemName: "alarm.fill")
                        .font(.title2)
                        .foregroundStyle(.orange)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.label.isEmpty ? "Alarm" : context.state.label)
                            .font(.headline)
                            .lineLimit(1)
                        
                        Text(context.state.nextOccurrenceDate, style: .time)
                            .font(.title2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                        
                        if context.state.isAdjusted, let desc = context.state.adjustmentDescription {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            
            DynamicIslandExpandedRegion(.trailing) {
                // Skip/Undo Skip button
                if context.state.isSkipped {
                    Button(intent: UndoSkipAlarmLiveIntent(alarmID: context.state.alarmID)) {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.uturn.backward")
                                .font(.title3)
                            Text("Undo")
                                .font(.caption2)
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(intent: SkipNextAlarmLiveIntent(alarmID: context.state.alarmID)) {
                        VStack(spacing: 2) {
                            Image(systemName: "forward.end.alt")
                                .font(.title3)
                            Text("Skip")
                                .font(.caption2)
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                }
            }
            
            DynamicIslandExpandedRegion(.bottom) {
                HStack(spacing: 12) {
                    // Minus adjustment button
                    Button(intent: AdjustNextAlarmLiveIntent(alarmID: context.state.alarmID, minutes: -context.state.adjustmentStepMinutes)) {
                        VStack(spacing: 2) {
                            Image(systemName: "minus.circle.fill")
                                .font(.title2)
                            Text("-\(context.state.adjustmentStepMinutes)")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Subtract \(context.state.adjustmentStepMinutes) minutes")
                    
                    // Plus adjustment button
                    Button(intent: AdjustNextAlarmLiveIntent(alarmID: context.state.alarmID, minutes: context.state.adjustmentStepMinutes)) {
                        VStack(spacing: 2) {
                            Image(systemName: "plus.circle.fill")
                                .font(.title2)
                            Text("+\(context.state.adjustmentStepMinutes)")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add \(context.state.adjustmentStepMinutes) minutes")
                    
                    // Reset button
                    Button(intent: ResetNextAlarmLiveIntent(alarmID: context.state.alarmID)) {
                        VStack(spacing: 2) {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.title2)
                            Text("Reset")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .foregroundStyle(.orange)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset to base schedule")
                }
            }
        } compactLeading: {
            // Compact leading - alarm icon
            Image(systemName: "alarm.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        } compactTrailing: {
            // Compact trailing - time
            Text(context.state.nextOccurrenceDate, style: .time)
                .font(.headline)
                .fontWeight(.bold)
                .monospacedDigit()
        } minimal: {
            // Minimal - just alarm icon
            Image(systemName: "alarm.fill")
                .font(.title3)
                .foregroundStyle(.orange)
        }
    }
}

/// Activity configuration for the next alarm Live Activity
struct NextAlarmActivityConfiguration: ActivityConfiguration {
    typealias Attributes = NextAlarmAttributes
    
    var body: some ActivityConfiguration<NextAlarmAttributes> {
        ActivityConfiguration(for: NextAlarmAttributes.self) { context in
            // Lock screen/banner presentation
            LockScreenView(state: context.state)
        } dynamicIsland: { context in
            // Dynamic Island presentation
            NextAlarmDynamicIsland(context: context)
        }
    }
    
    /// Lock screen/banner view
    struct LockScreenView: View {
        let state: NextAlarmAttributes.ContentState
        
        var body: some View {
            HStack(spacing: 12) {
                Image(systemName: "alarm.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.label.isEmpty ? "Alarm" : state.label)
                        .font(.headline)
                        .lineLimit(1)
                    
                    HStack(spacing: 8) {
                        Text(state.nextOccurrenceDate, style: .time)
                            .font(.title2)
                            .fontWeight(.bold)
                            .monospacedDigit()
                        
                        if state.isAdjusted, let desc = state.adjustmentDescription {
                            Text(desc)
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.orange.opacity(0.2))
                                .clipShape(Capsule())
                        }
                        
                        if state.isSkipped {
                            Text("SKIPPED")
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.red.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                }
                
                Spacer()
            }
            .padding()
        }
    }
}