import Foundation
import Observation

@MainActor
@Observable
final class AlarmCoordinator {
    private(set) var alarms: [AlarmRecord] = []
    private(set) var nextOccurrence: AlarmOccurrence?
    private(set) var lastError: String?
    private(set) var isSynchronizing = false

    private var engine: AlarmEngine
    private let persistence: any AlarmPersisting
    private let scheduler: any AlarmSystemScheduling
    private let now: () -> Date

    init(
        persistence: any AlarmPersisting = JSONAlarmPersistence(),
        scheduler: (any AlarmSystemScheduling)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        self.scheduler = scheduler ?? AlarmKitSchedulingService()
        self.now = now
        do {
            engine = AlarmEngine(snapshot: try persistence.load(), calendar: calendar)
        } catch {
            engine = AlarmEngine(calendar: calendar)
            lastError = "Could not load alarms: \(error.localizedDescription)"
        }
        publish()
    }

    func synchronize() async {
        await commit { _ in }
    }

    func save(_ alarm: AlarmRecord) async {
        await commit { try $0.upsert(alarm, now: now()) }
    }

    func delete(id: UUID) async {
        await commit { $0.delete(id: id) }
    }

    func setEnabled(_ enabled: Bool, id: UUID) async {
        await commit { try $0.setEnabled(enabled, id: id) }
    }

    func adjustNext(id: UUID, minutes: Int) async {
        await commit { try $0.adjustNext(id: id, byMinutes: minutes, now: now()) }
    }

    func setNextTime(id: UUID, date: Date) async {
        await commit { try $0.setNextTime(id: id, date: date, now: now()) }
    }

    func resetNext(id: UUID) async {
        await commit { try $0.resetNext(id: id, now: now()) }
    }

    func skipNext(id: UUID) async {
        await commit { try $0.skipNext(id: id, now: now()) }
    }

    func undoSkip(id: UUID) async {
        await commit { try $0.undoSkip(id: id, now: now()) }
    }

    func occurrence(for alarmID: UUID) -> AlarmOccurrence? {
        engine.nextOccurrence(for: alarmID, now: now())
    }

    private func commit(_ mutation: (inout AlarmEngine) throws -> Void) async {
        guard !isSynchronizing else { return }
        isSynchronizing = true
        defer { isSynchronizing = false }

        var candidate = engine
        do {
            try mutation(&candidate)
            candidate.pruneExpiredOverrides(now: now())
            let desired = desiredSystemAlarms(from: candidate)
            candidate.snapshot.managedSystemAlarmIDs = try await scheduler.reconcile(
                desired: desired,
                managedIDs: engine.snapshot.managedSystemAlarmIDs
            )
            try persistence.save(candidate.snapshot)
            engine = candidate
            lastError = nil
            publish()
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func desiredSystemAlarms(from engine: AlarmEngine) -> [DesiredSystemAlarm] {
        engine.desiredOccurrences(now: now()).compactMap { occurrence in
            guard let alarm = engine.alarm(id: occurrence.alarmID) else { return nil }
            let label = alarm.label.isEmpty ? "Alarm" : alarm.label
            return DesiredSystemAlarm(
                id: SystemScheduleID.make(for: occurrence, label: label),
                occurrence: occurrence,
                label: label
            )
        }
    }

    private func publish() {
        alarms = engine.alarms
        nextOccurrence = engine.earliestOccurrence(now: now())
    }
}
