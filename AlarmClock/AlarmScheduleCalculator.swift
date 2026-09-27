import Foundation

struct AlarmScheduleCalculator {
    var calendar: Calendar

    init(calendar: Calendar = .autoupdatingCurrent) {
        self.calendar = calendar
    }

    func occurrenceKey(for baseDate: Date) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    func nextBaseOccurrence(for alarm: AlarmRecord, after date: Date) -> Date? {
        guard alarm.isEnabled else { return nil }

        if alarm.repeatRule == .never {
            guard let oneTimeDate = alarm.oneTimeDate, oneTimeDate > date else { return nil }
            return oneTimeDate
        }

        let startDay = calendar.startOfDay(for: date)
        for dayOffset in 0..<370 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: startDay) else { continue }
            let weekday = calendar.component(.weekday, from: day)
            guard alarm.repeatRule.weekdays.contains(weekday),
                  let candidate = alarmDate(on: day, time: alarm.time) else { continue }
            if candidate > date {
                return candidate
            }
        }
        return nil
    }

    func nextEffectiveOccurrence(for alarm: AlarmRecord, after date: Date) -> AlarmOccurrence? {
        effectiveOccurrences(for: alarm, after: date, limit: 1).first
    }

    func effectiveOccurrences(for alarm: AlarmRecord, after date: Date, limit: Int) -> [AlarmOccurrence] {
        guard limit > 0 else { return [] }
        var occurrencesByKey: [String: AlarmOccurrence] = [:]

        for (key, override) in alarm.overrides where !override.isSkipped {
            guard let baseDate = baseDate(for: key, alarm: alarm) else { continue }
            let effectiveDate = override.customDate
                ?? baseDate.addingTimeInterval(TimeInterval((override.offsetMinutes ?? 0) * 60))
            guard effectiveDate > date else { continue }
            occurrencesByKey[key] = AlarmOccurrence(
                alarmID: alarm.id,
                occurrenceKey: key,
                baseDate: baseDate,
                effectiveDate: effectiveDate,
                isAdjusted: effectiveDate != baseDate
            )
        }

        var cursor = date
        for _ in 0..<(limit + alarm.overrides.count + 14) {
            guard let baseDate = nextBaseOccurrence(for: alarm, after: cursor) else { break }
            cursor = baseDate.addingTimeInterval(1)
            let key = occurrenceKey(for: baseDate)
            let override = alarm.overrides[key]
            guard override?.isSkipped != true else { continue }
            let effectiveDate = override?.customDate
                ?? baseDate.addingTimeInterval(TimeInterval((override?.offsetMinutes ?? 0) * 60))
            guard effectiveDate > date else { continue }
            occurrencesByKey[key] = AlarmOccurrence(
                alarmID: alarm.id,
                occurrenceKey: key,
                baseDate: baseDate,
                effectiveDate: effectiveDate,
                isAdjusted: effectiveDate != baseDate
            )
        }

        return occurrencesByKey.values
            .sorted { $0.effectiveDate < $1.effectiveDate }
            .prefix(limit)
            .map { $0 }
    }

    func earliestEffectiveOccurrence(in alarms: [AlarmRecord], after date: Date) -> AlarmOccurrence? {
        alarms.compactMap { nextEffectiveOccurrence(for: $0, after: date) }
            .min { $0.effectiveDate < $1.effectiveDate }
    }

    private func baseDate(for key: String, alarm: AlarmRecord) -> Date? {
        let values = key.split(separator: "-").compactMap { Int($0) }
        guard values.count == 3 else { return nil }
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        components.year = values[0]
        components.month = values[1]
        components.day = values[2]
        components.hour = alarm.time.hour
        components.minute = alarm.time.minute
        return calendar.date(from: components)
    }


    private func alarmDate(on day: Date, time: AlarmTime) -> Date? {
        var matching = DateComponents()
        matching.hour = time.hour
        matching.minute = time.minute
        matching.second = 0
        let searchStart = calendar.date(byAdding: .second, value: -1, to: calendar.startOfDay(for: day)) ?? day
        guard let candidate = calendar.nextDate(
            after: searchStart,
            matching: matching,
            matchingPolicy: .nextTime,
            repeatedTimePolicy: .first,
            direction: .forward
        ), calendar.isDate(candidate, inSameDayAs: day) else {
            return nil
        }
        return candidate
    }
}
