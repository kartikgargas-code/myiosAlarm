import AlarmKit
import ActivityKit
import Foundation
import SwiftUI

struct ScheduledOccurrenceMetadata: AlarmMetadata {
    let alarmID: UUID
    let occurrenceKey: String
    let baseDate: Date
}

struct DesiredSystemAlarm: Equatable {
    let id: UUID
    let occurrence: AlarmOccurrence
    let label: String
    let sound: AlarmSound
    let alarmKitSound: AlertConfiguration.AlertSound
    let snoozeDurationMinutes: Int? // Added for native snooze
}

@MainActor
protocol AlarmSystemScheduling {
    func reconcile(desired: [DesiredSystemAlarm], managedIDs: Set<UUID>) async throws -> Set<UUID>
}

struct AlarmReconciliationPlan: Equatable {
    let schedule: Set<UUID>
    let cancel: Set<UUID>

    init(desiredIDs: Set<UUID>, existingIDs: Set<UUID>, managedIDs: Set<UUID>) {
        schedule = desiredIDs.subtracting(existingIDs)
        cancel = managedIDs.subtracting(desiredIDs).intersection(existingIDs)
    }
}


struct AlarmKitSchedulingService: AlarmSystemScheduling {
    @MainActor
    var manager: AlarmManager { AlarmManager.shared }

    func reconcile(desired: [DesiredSystemAlarm], managedIDs: Set<UUID>) async throws -> Set<UUID> {
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
        let snoozeInterval = TimeInterval((item.snoozeDurationMinutes ?? 10) * 60)
        let alert = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: item.label),
            stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill"),
            secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
            secondaryButtonBehavior: .countdown
        )
        // .countdown secondary behavior re-triggers the alarm after postAlert;
        // without countdownDuration the snooze button renders but does nothing.
        let attributes = AlarmAttributes(
            presentation: AlarmPresentation(
                alert: alert,
                countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: item.label)),
                paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: item.label))
            ),
            metadata: ScheduledOccurrenceMetadata(
                alarmID: item.occurrence.alarmID,
                occurrenceKey: item.occurrence.occurrenceKey,
                baseDate: item.occurrence.baseDate
            ),
            tintColor: .orange
        )

        let configuration = AlarmManager.AlarmConfiguration<ScheduledOccurrenceMetadata>(
            countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snoozeInterval),
            schedule: .fixed(item.occurrence.effectiveDate),
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: nil,
            sound: item.alarmKitSound
        )
        _ = try await manager.schedule(id: item.id, configuration: configuration)
    }
}

#if DIAGNOSTIC_BUILD
struct DiagnosticAlarmSchedulingService: AlarmSystemScheduling {
    func reconcile(desired: [DesiredSystemAlarm], managedIDs: Set<UUID>) async throws -> Set<UUID> {
        []
    }
}
#endif


enum AlarmSynchronizationError: LocalizedError {
    case notAuthorized

    var errorDescription: String? {
        switch self {
        case .notAuthorized: "Alarm access is not authorized."
        }
    }
}

enum SystemScheduleID {
    static func make(
        for occurrence: AlarmOccurrence,
        label: String,
        sound: AlarmSound = .systemDefault,
        loudness: AlarmLoudness = .defaultValue,
        selectionHash: String? = nil
    ) -> UUID {
        var key = "\(Int64(occurrence.effectiveDate.timeIntervalSince1970))|\(label)|\(sound.id)|\(loudness.percentage)"
        if let selectionHash {
            key += "|\(selectionHash)"
        }
        return StableOccurrenceID.make(alarmID: occurrence.id, occurrenceKey: key)
    }
}
