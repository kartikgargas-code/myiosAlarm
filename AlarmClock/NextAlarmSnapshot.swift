import Foundation

/// Provider for accessing the coordinator from SwiftUI environment
@MainActor
public final class NextAlarmProvider: ObservableObject {
    let coordinator: AlarmCoordinator
    
    init(coordinator: AlarmCoordinator) {
        self.coordinator = coordinator
    }
}

/// A snapshot of the next upcoming alarm, designed for sharing with
/// widget extensions and control widgets without duplicating scheduling logic.
public struct NextAlarmSnapshot: Codable, Equatable {
    /// The alarm's unique identifier
    public let alarmID: UUID

    /// The alarm's label/name
    public let label: String

    /// The permanent scheduled time (without adjustments)
    public let permanentTime: AlarmTime

    /// The repeat rule for this alarm
    public let repeatRule: AlarmRepeatRule

    /// The actual next occurrence date and time
    public let nextOccurrenceDate: Date

    /// Whether the next occurrence has a temporary adjustment
    public let isAdjusted: Bool

    /// Adjustment description (e.g., "+10 minutes", "Custom Time")
    public let adjustmentDescription: String?

    /// Whether the next occurrence is skipped
    public let isSkipped: Bool

    /// Whether the alarm is enabled
    public let isEnabled: Bool

    /// The alarm's sound configuration
    public let sound: AlarmSound

    /// The alarm's loudness setting
    public let loudness: AlarmLoudness

    /// Creates a snapshot from an alarm record and its next occurrence
    public init?(alarm: AlarmRecord, occurrence: AlarmOccurrence?) {
        guard let occurrence = occurrence else { return nil }
        self.alarmID = alarm.id
        self.label = alarm.label.isEmpty ? "Alarm" : alarm.label
        self.permanentTime = alarm.time
        self.repeatRule = alarm.repeatRule
        self.nextOccurrenceDate = occurrence.effectiveDate
        self.isAdjusted = occurrence.isAdjusted
        self.isSkipped = false
        self.isEnabled = alarm.isEnabled
        self.sound = alarm.sound
        self.loudness = alarm.loudness

        // Build adjustment description
        if occurrence.isAdjusted {
            let minutes = Int(occurrence.effectiveDate.timeIntervalSince(occurrence.baseDate) / 60)
            self.adjustmentDescription = minutes >= 0 ? "+\(minutes) minutes" : "\(minutes) minutes"
        } else {
            self.adjustmentDescription = nil
        }
    }

    /// Creates a snapshot indicating no upcoming alarm
    public static func none() -> NextAlarmSnapshot? {
        return nil
    }
}

/// Extension to provide formatted strings for the widget
extension NextAlarmSnapshot {
    /// Formatted time string (e.g., "7:00 AM")
    public var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: nextOccurrenceDate)
    }

    /// Formatted date indicator (e.g., "Today", "Tomorrow", or "MMM d")
    public var dateIndicator: String {
        let calendar = Calendar.current
        let now = Date()
        if calendar.isDate(nextOccurrenceDate, inSameDayAs: now) {
            return "Today"
        } else if calendar.isDate(nextOccurrenceDate, inSameDayAs: calendar.date(byAdding: .day, value: 1, to: now) ?? now) {
            return "Tomorrow"
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            return formatter.string(from: nextOccurrenceDate)
        }
    }
}