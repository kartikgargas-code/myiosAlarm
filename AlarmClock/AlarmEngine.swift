import Foundation

public struct AlarmEngine {
    public var snapshot: AlarmStoreSnapshot
    public var calculator: AlarmScheduleCalculator

    public init(snapshot: AlarmStoreSnapshot = .empty, calendar: Calendar = .autoupdatingCurrent) {
        self.snapshot = snapshot
        self.calculator = AlarmScheduleCalculator(calendar: calendar)
    }

    public var alarms: [AlarmRecord] {
        snapshot.alarms.sorted(by: permanentTimeOrder)
    }

    public func alarmsOrderedByNextOccurrence(now: Date) -> [AlarmRecord] {
        snapshot.alarms.sorted { first, second in
            let firstDate = calculator.nextEffectiveOccurrence(for: first, after: now)?.effectiveDate
            let secondDate = calculator.nextEffectiveOccurrence(for: second, after: now)?.effectiveDate
            switch (firstDate, secondDate) {
            case let (.some(lhs), .some(rhs)) where lhs != rhs:
                return lhs < rhs
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return permanentTimeOrder(first, second)
            }
        }
    }

    public func alarm(id: UUID) -> AlarmRecord? {
        snapshot.alarms.first { $0.id == id }
    }

    public mutating func upsert(_ alarm: AlarmRecord, now: Date) throws {
        try validate(alarm)
        if let index = snapshot.alarms.firstIndex(where: { $0.id == alarm.id }) {
            var updated = alarm
            if scheduleIdentity(of: snapshot.alarms[index]) != scheduleIdentity(of: alarm) {
                updated.overrides = [:]
            }
            snapshot.alarms[index] = updated
        } else {
            snapshot.alarms.append(alarm)
        }
        pruneExpiredOverrides(now: now)
    }

    public mutating func delete(id: UUID) {
        snapshot.alarms.removeAll { $0.id == id }
    }

    public mutating func setEnabled(_ enabled: Bool, id: UUID) throws {
        try mutateAlarm(id: id) { $0.isEnabled = enabled }
    }

    public mutating func adjustNext(id: UUID, byMinutes minutes: Int, now: Date) throws {
        try mutateNextOverride(id: id, now: now) { occurrence, override in
            let currentDate = override.customDate
                ?? occurrence.baseDate.addingTimeInterval(TimeInterval((override.offsetMinutes ?? 0) * 60))
            let newDate = currentDate.addingTimeInterval(TimeInterval(minutes * 60))
            guard newDate > now else { throw AlarmEngineError.occurrenceWouldBeInPast }
            override.customDate = nil
            override.offsetMinutes = Int(newDate.timeIntervalSince(occurrence.baseDate) / 60)
            override.isSkipped = false
        }
    }

    public mutating func setNextTime(id: UUID, date: Date, now: Date) throws {
        guard date > now else { throw AlarmEngineError.occurrenceWouldBeInPast }
        try mutateNextOverride(id: id, now: now) { _, override in
            override.customDate = date
            override.offsetMinutes = nil
            override.isSkipped = false
        }
    }

    public mutating func resetNext(id: UUID, now: Date) throws {
        guard let alarm = alarm(id: id),
              let occurrence = calculator.nextEffectiveOccurrence(for: alarm, after: now) else {
            throw AlarmEngineError.noUpcomingOccurrence
        }
        try mutateAlarm(id: id) { $0.overrides[occurrence.occurrenceKey] = nil }
    }

    public mutating func skipNext(id: UUID, now: Date) throws {
        try mutateNextOverride(id: id, now: now) { _, override in
            override.isSkipped = true
        }
    }

    public mutating func undoSkip(id: UUID, now: Date) throws {
        guard let index = snapshot.alarms.firstIndex(where: { $0.id == id }) else {
            throw AlarmEngineError.alarmNotFound
        }
        let alarm = snapshot.alarms[index]
        let skippedCandidates = alarm.overrides.compactMap { key, value -> (String, AlarmOccurrenceOverride, Date)? in
            guard value.isSkipped, let date = baseDate(for: key, alarm: alarm) else { return nil }
            return (key, value, date)
        }
        let filtered = skippedCandidates.filter { $0.2 > now }
        let earliestSkipped = filtered.min { $0.2 < $1.2 }
        guard let skipped = earliestSkipped else {
            throw AlarmEngineError.noSkippedOccurrence
        }
        var restored = skipped.1
        restored.isSkipped = false
        snapshot.alarms[index].overrides[skipped.0] = restored == .none ? nil : restored
    }

    public func nextOccurrence(for id: UUID, now: Date) -> AlarmOccurrence? {
        alarm(id: id).flatMap { calculator.nextEffectiveOccurrence(for: $0, after: now) }
    }

    public func earliestOccurrence(now: Date) -> AlarmOccurrence? {
        calculator.earliestEffectiveOccurrence(in: snapshot.alarms, after: now)
    }

    public func desiredOccurrences(now: Date, perAlarmLimit: Int = 7) -> [AlarmOccurrence] {
        snapshot.alarms.flatMap {
            calculator.effectiveOccurrences(for: $0, after: now, limit: perAlarmLimit)
        }
    }

    public mutating func pruneExpiredOverrides(now: Date) {
        for index in snapshot.alarms.indices {
            snapshot.alarms[index].overrides = snapshot.alarms[index].overrides.filter { key, _ in
                guard let date = baseDate(for: key, alarm: snapshot.alarms[index]) else { return false }
                return date >= now.addingTimeInterval(-86_400)
            }
        }
    }

    private mutating func mutateNextOverride(
        id: UUID,
        now: Date,
        mutation: (AlarmOccurrence, inout AlarmOccurrenceOverride) throws -> Void
    ) throws {
        guard let index = snapshot.alarms.firstIndex(where: { $0.id == id }) else {
            throw AlarmEngineError.alarmNotFound
        }
        let alarm = snapshot.alarms[index]
        guard let occurrence = calculator.nextEffectiveOccurrence(for: alarm, after: now) else {
            throw AlarmEngineError.noUpcomingOccurrence
        }
        let key = occurrence.occurrenceKey
        var override = alarm.overrides[key] ?? .none
        try mutation(occurrence, &override)
        snapshot.alarms[index].overrides[key] = override == .none ? nil : override
    }

    private mutating func mutateAlarm(id: UUID, mutation: (inout AlarmRecord) throws -> Void) throws {
        guard let index = snapshot.alarms.firstIndex(where: { $0.id == id }) else {
            throw AlarmEngineError.alarmNotFound
        }
        try mutation(&snapshot.alarms[index])
    }

    private func validate(_ alarm: AlarmRecord) throws {
        guard (0...23).contains(alarm.time.hour), (0...59).contains(alarm.time.minute) else {
            throw AlarmEngineError.invalidTime
        }
        guard alarm.adjustmentStepMinutes > 0 else { throw AlarmEngineError.invalidAdjustmentStep }
        if case .custom(let days) = alarm.repeatRule, days.isEmpty || !days.isSubset(of: Set(1...7)) {
            throw AlarmEngineError.invalidRepeatDays
        }
        if alarm.repeatRule == .never, alarm.oneTimeDate == nil {
            throw AlarmEngineError.oneTimeDateRequired
        }
    }

    private func scheduleIdentity(of alarm: AlarmRecord) -> String {
        "\(alarm.time.hour):\(alarm.time.minute)|\(alarm.repeatRule)|\(alarm.oneTimeDate?.timeIntervalSince1970 ?? 0)"
    }

    private func permanentTimeOrder(_ first: AlarmRecord, _ second: AlarmRecord) -> Bool {
        if first.time.hour != second.time.hour { return first.time.hour < second.time.hour }
        if first.time.minute != second.time.minute { return first.time.minute < second.time.minute }
        return first.id.uuidString < second.id.uuidString
    }

    private func baseDate(for key: String, alarm: AlarmRecord) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calculator.calendar
        components.timeZone = calculator.calendar.timeZone
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        components.hour = alarm.time.hour
        components.minute = alarm.time.minute
        return calculator.calendar.date(from: components)
    }
}

enum AlarmEngineError: LocalizedError, Equatable {
    case alarmNotFound
    case noUpcomingOccurrence
    case noSkippedOccurrence
    case occurrenceWouldBeInPast
    case invalidTime
    case invalidAdjustmentStep
    case invalidRepeatDays
    case oneTimeDateRequired

    var errorDescription: String? {
        switch self {
        case .alarmNotFound: "Alarm not found."
        case .noUpcomingOccurrence: "This alarm has no upcoming occurrence."
        case .noSkippedOccurrence: "This alarm has no upcoming skipped occurrence."
        case .occurrenceWouldBeInPast: "The adjusted occurrence must remain in the future."
        case .invalidTime: "Alarm time is invalid."
        case .invalidAdjustmentStep: "Adjustment step must be greater than zero."
        case .invalidRepeatDays: "Choose at least one valid repeat day."
        case .oneTimeDateRequired: "A one-time alarm requires a future date."
        }
    }
}
