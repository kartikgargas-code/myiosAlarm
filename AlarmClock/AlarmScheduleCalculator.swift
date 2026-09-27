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
        var occurrences: [AlarmOccurrence] = []
        var cursor = date.addingTimeInterval(-7 * 86_400)

        for _ in 0..<400 {
            guard let baseDate = nextBaseOccurrence(for: alarm, after: cursor) else { break }
            cursor = baseDate.addingTimeInterval(1)
            let key = occurrenceKey(for: baseDate)
            let override = alarm.overrides[key]
            guard override?.isSkipped != true else { continue }

            let effectiveDate: Date
            if let customDate = override?.customDate {
                effectiveDate = customDate
            } else if let offsetMinutes = override?.offsetMinutes {
                effectiveDate = baseDate.addingTimeInterval(TimeInterval(offsetMinutes * 60))
            } else {
                effectiveDate = baseDate
            }
            guard effectiveDate > date else { continue }

            occurrences.append(AlarmOccurrence(
                alarmID: alarm.id,
                occurrenceKey: key,
                baseDate: baseDate,
                effectiveDate: effectiveDate,
                isAdjusted: effectiveDate != baseDate
            ))
            occurrences.sort { $0.effectiveDate < $1.effectiveDate }
            if occurrences.count > limit {
                occurrences.removeLast(occurrences.count - limit)
            }

            if occurrences.count == limit,
               let latest = occurrences.last,
               baseDate > latest.effectiveDate.addingTimeInterval(7 * 86_400) {
                break
            }
        }
        return occurrences
    }

    func earliestEffectiveOccurrence(in alarms: [AlarmRecord], after date: Date) -> AlarmOccurrence? {
        alarms.compactMap { nextEffectiveOccurrence(for: $0, after: date) }
            .min { $0.effectiveDate < $1.effectiveDate }
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
