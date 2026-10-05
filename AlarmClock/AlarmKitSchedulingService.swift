import AlarmKit
import ActivityKit
import Foundation
import SwiftUI
import os.log

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
    func reconcile(desired: [DesiredSystemAlarm], managedIDs: Set<UUID>, reason: String) async throws -> Set<UUID>
}

struct AlarmReconciliationPlan: Equatable {
    let schedule: Set<UUID>
    let cancel: Set<UUID>

    init(desiredIDs: Set<UUID>, existingIDs: Set<UUID>, managedIDs: Set<UUID>) {
        schedule = desiredIDs.subtracting(existingIDs)
        // Cancel ALL app-namespace alarms not currently desired.
        // Orphans (existing in AlarmKit but not in managedIDs or desiredIDs) are
        // never cancelled by the old logic. This change ensures they are cancelled.
        cancel = existingIDs.subtracting(desiredIDs)
    }
}


struct AlarmKitSchedulingService: AlarmSystemScheduling {
    @MainActor
    var manager: AlarmManager { AlarmManager.shared }
    
    private let reconcileLog = OSLog(subsystem: "com.example.alarmclock", category: "AlarmKitScheduling")

    func reconcile(desired: [DesiredSystemAlarm], managedIDs: Set<UUID>, reason: String) async throws -> Set<UUID> {
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
        
        // Log reconciliation details with reason
        let scheduleCount = plan.schedule.count
        os_log(.info, log: reconcileLog, "RECONCILE(%{public}s): existing=%{public}d desired=%{public}d schedule=%{public}d cancelling=%{public}d", reason, existingIDs.count, desiredIDs.count, scheduleCount, plan.cancel.count)
        SmartWakeDebugLog.log("RECONCILE(\(reason)): existing=\(existingIDs.count) desired=\(desiredIDs.count) schedule=\(scheduleCount) cancelling=\(plan.cancel.count)")
        for cancelID in plan.cancel {
            SmartWakeDebugLog.log("RECONCILE(\(reason)) CANCEL: \(cancelID.uuidString)")
        }

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
            do {
                try manager.cancel(id: id)
                os_log(.info, log: reconcileLog, "RECONCILE: cancelled %{public}s", id.uuidString)
                SmartWakeDebugLog.log("RECONCILE CANCEL SUCCESS: \(id.uuidString)")
            } catch {
                os_log(.error, log: reconcileLog, "RECONCILE CANCEL FAILED: %{public}s error=%{public}s", id.uuidString, error.localizedDescription)
                SmartWakeDebugLog.log("RECONCILE CANCEL FAILED: \(id.uuidString) error=\(error.localizedDescription)")
            }
        }
        return desiredIDs
    }

    private func schedule(_ item: DesiredSystemAlarm) async throws {
        let snoozeInterval = TimeInterval((item.snoozeDurationMinutes ?? 10) * 60)
        let snoozeMinutes = item.snoozeDurationMinutes ?? 10
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
                countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min")),
                paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min"), resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.circle.fill"))
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
        // STABLE ID: alarmID | occurrenceKey | label | loudness | kind (no sound.id)
        // This prevents AlarmKit churn when sound resolution changes (e.g., random mode).
        // The sound is still passed in the AlarmConfiguration for the actual alert.
        let kind = occurrence.occurrenceKey.hasSuffix("-BACKUP") ? "backup" : "primary"
        var key = "\(Int64(occurrence.effectiveDate.timeIntervalSince1970))|\(label)|\(loudness.percentage)|\(kind)"
        if let selectionHash {
            key += "|\(selectionHash)"
        }
        return StableOccurrenceID.make(alarmID: occurrence.alarmID, occurrenceKey: key)
    }
}
