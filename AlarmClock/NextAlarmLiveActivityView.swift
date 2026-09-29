import SwiftUI
import ActivityKit
import WidgetKit
import AlarmClockShared

/// Dynamic Island presentation for the next alarm
struct NextAlarmDynamicIsland {
    static func make(context: ActivityViewContext<NextAlarmAttributes>) -> DynamicIsland {
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
                Image(systemName: context.state.isAdjusted ? "clock.badge.checkmark" : "clock")
                    .font(.title2)
                    .foregroundStyle(context.state.isAdjusted ? .orange : .secondary)
            }
            
            DynamicIslandExpandedRegion(.bottom) {
                if let description = context.state.adjustmentDescription {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.orange)
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

/// Lock screen/banner view for the next alarm Live Activity.
struct NextAlarmLockScreenView: View {
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