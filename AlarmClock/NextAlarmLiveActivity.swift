import Foundation
import ActivityKit
import AlarmClockShared

/// Attributes for the Next Alarm Live Activity
public struct NextAlarmAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// The alarm's unique identifier
        public let alarmID: UUID
        
        /// The alarm's label
        public let label: String
        
        /// The next occurrence date and time
        public let nextOccurrenceDate: Date
        
        /// The configured adjustment step in minutes
        public let adjustmentStepMinutes: Int
        
        /// Whether the next occurrence has a temporary adjustment
        public let isAdjusted: Bool
        
        /// Adjustment description (e.g., "+10 minutes")
        public let adjustmentDescription: String?
        
        /// Whether the next occurrence is skipped
        public let isSkipped: Bool
        
        /// Whether the alarm is enabled
        public let isEnabled: Bool
        
        /// The alarm's sound configuration
        public let sound: AlarmSound
        
        /// The alarm's loudness setting
        public let loudness: AlarmLoudness
        
        /// The repeat rule
        public let repeatRule: AlarmRepeatRule
        
        public init(
            alarmID: UUID,
            label: String,
            nextOccurrenceDate: Date,
            adjustmentStepMinutes: Int,
            isAdjusted: Bool,
            adjustmentDescription: String?,
            isSkipped: Bool,
            isEnabled: Bool,
            sound: AlarmSound,
            loudness: AlarmLoudness,
            repeatRule: AlarmRepeatRule
        ) {
            self.alarmID = alarmID
            self.label = label
            self.nextOccurrenceDate = nextOccurrenceDate
            self.adjustmentStepMinutes = adjustmentStepMinutes
            self.isAdjusted = isAdjusted
            self.adjustmentDescription = adjustmentDescription
            self.isSkipped = isSkipped
            self.isEnabled = isEnabled
            self.sound = sound
            self.loudness = loudness
            self.repeatRule = repeatRule
        }
    }
    
    /// Fixed attributes that don't change during the activity
    public let alarmID: UUID
    
    public init(alarmID: UUID) {
        self.alarmID = alarmID
    }
}

/// Extension to create ContentState from NextAlarmSnapshot
extension NextAlarmAttributes.ContentState {
    public static func from(snapshot: NextAlarmSnapshot) -> Self {
        NextAlarmAttributes.ContentState(
            alarmID: snapshot.alarmID,
            label: snapshot.label,
            nextOccurrenceDate: snapshot.nextOccurrenceDate,
            adjustmentStepMinutes: 10, // Will be updated with actual value
            isAdjusted: snapshot.isAdjusted,
            adjustmentDescription: snapshot.adjustmentDescription,
            isSkipped: snapshot.isSkipped,
            isEnabled: snapshot.isEnabled,
            sound: snapshot.sound,
            loudness: snapshot.loudness,
            repeatRule: snapshot.repeatRule
        )
    }
}