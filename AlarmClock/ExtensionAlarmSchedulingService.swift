import AlarmKit
import ActivityKit
import Foundation
import AlarmClockShared

/// Service for scheduling AlarmKit alarms from a Live Activity intent.
public struct ExtensionAlarmSchedulingService {
    var manager: AlarmManager { AlarmManager.shared }
    
    /// Reconcile desired alarms with AlarmKit
    /// This is the same logic as AlarmKitSchedulingService.reconcile but usable from extensions
    public func reconcile(desired: [DesiredSystemAlarm], managedIDs: Set<UUID>) async throws -> Set<UUID> {
        guard manager.authorizationState == .authorized else {
            throw AlarmSynchronizationError.notAuthorized
        }
        
        let existingIDs = Set(try manager.alarms.map(\.id))
        let desiredIDs = Set(desired.map(\.id))
        let plan = AlarmReconciliationPlan(
            desiredIDs: desiredIDs,
            existingIDs: existingIDs,
            managedIDs: managedIDs
        )
        let missing = desired.filter { plan.schedule.contains($0.id) }
        
        var newlyScheduled: [UUID] = []
        do {
            for item in missing.sorted(by: { $0.occurrence.effectiveDate < $1.occurrence.effectiveDate }) {
                try await schedule(item)
                newlyScheduled.append(item.id)
            }
        } catch {
            for id in newlyScheduled {
                try? manager.cancel(id: id)
            }
            throw error
        }
        
        for id in plan.cancel {
            try manager.cancel(id: id)
        }
        return desiredIDs
    }
    
    private func schedule(_ item: DesiredSystemAlarm) async throws {
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: item.label),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill")
        )
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(alert: alert),
            metadata: ScheduledOccurrenceMetadata(
                alarmID: item.occurrence.alarmID,
                occurrenceKey: item.occurrence.occurrenceKey,
                baseDate: item.occurrence.baseDate
            ),
            tintColor: .orange
        )
        
        let configuration = AlarmManager.AlarmConfiguration.alarm(
            schedule: .fixed(item.occurrence.effectiveDate),
            attributes: attributes,
            sound: item.alarmKitSound
        )
        _ = try await manager.schedule(id: item.id, configuration: configuration)
    }
}

/// Types needed for the extension scheduling service
public extension ExtensionAlarmSchedulingService {
    struct ScheduledOccurrenceMetadata: AlarmMetadata {
        let alarmID: UUID
        let occurrenceKey: String
        let baseDate: Date
    }
    
    public struct DesiredSystemAlarm: Equatable {
        public let id: UUID
        public let occurrence: AlarmOccurrence
        public let label: String
        public let sound: AlarmSound
        public let alarmKitSound: AlertConfiguration.AlertSound
    }
    
    public struct AlarmReconciliationPlan: Equatable {
        public let schedule: Set<UUID>
        public let cancel: Set<UUID>
        
        public init(desiredIDs: Set<UUID>, existingIDs: Set<UUID>, managedIDs: Set<UUID>) {
            schedule = desiredIDs.subtracting(existingIDs)
            cancel = managedIDs.subtracting(desiredIDs).intersection(existingIDs)
        }
    }
    
    public enum AlarmSynchronizationError: LocalizedError {
        case notAuthorized
        
        public var errorDescription: String? {
            switch self {
            case .notAuthorized: "Alarm access is not authorized."
            }
        }
    }
    
    public struct SystemScheduleID {
        public static func make(
            for occurrence: AlarmOccurrence,
            label: String,
            sound: AlarmSound = .systemDefault,
            loudness: AlarmLoudness = .defaultValue
        ) -> UUID {
            // Use StableOccurrenceID for stable IDs
            StableOccurrenceID.make(
                alarmID: occurrence.alarmID,
                occurrenceKey: "\(Int64(occurrence.effectiveDate.timeIntervalSince1970))|\(label)|\(sound.id)|\(loudness.percentage)"
            )
        }
    }
}