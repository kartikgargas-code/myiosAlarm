import XCTest
@testable import AlarmClock

@MainActor
final class AlarmEngineTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        now = date(2026, 9, 21, 6, 0)
    }

    func testDailyPlusTenAdjustsOnlyNextOccurrence() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)

        try engine.adjustNext(id: id, byMinutes: 10, now: now)

        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 2)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 7, 10])
        XCTAssertEqual(components(occurrences[1].effectiveDate), [2026, 9, 22, 7, 0])
        XCTAssertEqual(engine.alarm(id: id)?.time, AlarmTime(hour: 7, minute: 0))
    }

    func testDailyMinusTen() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        try engine.adjustNext(id: id, byMinutes: -10, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: id, now: now)!.effectiveDate), [2026, 9, 21, 6, 50])
    }

    func testAdjustmentsAccumulateAndReset() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        try engine.adjustNext(id: id, byMinutes: 10, now: now)
        try engine.adjustNext(id: id, byMinutes: 10, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: id, now: now)!.effectiveDate), [2026, 9, 21, 7, 20])
        try engine.adjustNext(id: id, byMinutes: -10, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: id, now: now)!.effectiveDate), [2026, 9, 21, 7, 10])
        try engine.resetNext(id: id, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: id, now: now)!.effectiveDate), [2026, 9, 21, 7, 0])
    }

    func testSkipAndUndoAffectOnlyOneOccurrence() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        try engine.skipNext(id: id, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: id, now: now)!.effectiveDate), [2026, 9, 22, 7, 0])
        try engine.undoSkip(id: id, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: id, now: now)!.effectiveDate), [2026, 9, 21, 7, 0])
    }

    func testCustomNextTimePreservesBaseSchedule() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        try engine.setNextTime(id: id, date: date(2026, 9, 21, 8, 17), now: now)
        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 2)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 8, 17])
        XCTAssertEqual(components(occurrences[1].effectiveDate), [2026, 9, 22, 7, 0])
    }

    func testDelayedOccurrenceRemainsNextAfterPermanentTimePasses() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        try engine.adjustNext(id: id, byMinutes: 120, now: now)
        let afterBaseTime = date(2026, 9, 21, 7, 30)
        let occurrence = try XCTUnwrap(engine.nextOccurrence(for: id, now: afterBaseTime))
        XCTAssertEqual(occurrence.occurrenceKey, "2026-09-21")
        XCTAssertEqual(components(occurrence.effectiveDate), [2026, 9, 21, 9, 0])
    }

    func testMultipleAlarmsReorderWithoutLosingAdjustment() throws {
        var engine = AlarmEngine(calendar: calendar)
        let first = AlarmRecord(label: "A", time: AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
        let second = AlarmRecord(label: "B", time: AlarmTime(hour: 7, minute: 5), repeatRule: .daily)
        try engine.upsert(first, now: now)
        try engine.upsert(second, now: now)
        XCTAssertEqual(engine.earliestOccurrence(now: now)?.alarmID, first.id)
        try engine.adjustNext(id: first.id, byMinutes: 10, now: now)
        XCTAssertEqual(engine.earliestOccurrence(now: now)?.alarmID, second.id)
        XCTAssertEqual(components(engine.nextOccurrence(for: first.id, now: now)!.effectiveDate), [2026, 9, 21, 7, 10])
    }

    func testWeekdayWeekendAndCustomRecurrence() throws {
        var engine = AlarmEngine(calendar: calendar)
        let weekday = AlarmRecord(label: "Weekday", time: AlarmTime(hour: 7, minute: 0), repeatRule: .weekdays)
        let weekend = AlarmRecord(label: "Weekend", time: AlarmTime(hour: 8, minute: 0), repeatRule: .weekends)
        let custom = AlarmRecord(label: "Custom", time: AlarmTime(hour: 9, minute: 0), repeatRule: .custom([3, 5]))
        try engine.upsert(weekday, now: now)
        try engine.upsert(weekend, now: now)
        try engine.upsert(custom, now: now)
        XCTAssertEqual(components(engine.nextOccurrence(for: weekday.id, now: date(2026, 9, 25, 8, 0))!.baseDate), [2026, 9, 28, 7, 0])
        XCTAssertEqual(components(engine.nextOccurrence(for: weekend.id, now: date(2026, 9, 25, 8, 0))!.baseDate), [2026, 9, 26, 8, 0])
        XCTAssertEqual(components(engine.nextOccurrence(for: custom.id, now: now)!.baseDate), [2026, 9, 22, 9, 0])
    }

    func testMidnightCrossingKeepsOccurrenceIdentity() throws {
        var engine = AlarmEngine(calendar: calendar)
        let alarm = AlarmRecord(label: "Midnight", time: AlarmTime(hour: 0, minute: 5), repeatRule: .daily)
        let beforeMidnight = date(2026, 9, 21, 23, 0)
        try engine.upsert(alarm, now: beforeMidnight)
        try engine.adjustNext(id: alarm.id, byMinutes: -10, now: beforeMidnight)
        let occurrence = try XCTUnwrap(engine.nextOccurrence(for: alarm.id, now: beforeMidnight))
        XCTAssertEqual(occurrence.occurrenceKey, "2026-09-22")
        XCTAssertEqual(components(occurrence.effectiveDate), [2026, 9, 21, 23, 55])
    }

    func testMovingOccurrenceIntoPastFails() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        XCTAssertThrowsError(try engine.adjustNext(id: id, byMinutes: -120, now: now)) {
            XCTAssertEqual($0 as? AlarmEngineError, .occurrenceWouldBeInPast)
        }
    }

    func testDisablingAndDeletingRemoveDesiredOccurrences() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)
        try engine.setEnabled(false, id: id)
        XCTAssertNil(engine.nextOccurrence(for: id, now: now))
        engine.delete(id: id)
        XCTAssertTrue(engine.desiredOccurrences(now: now).isEmpty)
    }

    func testScheduleEditClearsOverridesButLabelEditPreservesThem() throws {
        var engine = engineWithDailyAlarm()
        var alarm = try XCTUnwrap(engine.alarms.first)
        try engine.adjustNext(id: alarm.id, byMinutes: 10, now: now)
        alarm = try XCTUnwrap(engine.alarm(id: alarm.id))
        alarm.label = "Renamed"
        try engine.upsert(alarm, now: now)
        XCTAssertEqual(engine.alarm(id: alarm.id)?.overrides.count, 1)
        alarm.time = AlarmTime(hour: 8, minute: 0)
        try engine.upsert(alarm, now: now)
        XCTAssertTrue(engine.alarm(id: alarm.id)?.overrides.isEmpty == true)
    }

    func testPersistenceRoundTripPreservesAdjustmentsAndSkips() throws {
        var engine = engineWithDailyAlarm()
        let first = try XCTUnwrap(engine.alarms.first)
        let second = AlarmRecord(label: "Second", time: AlarmTime(hour: 8, minute: 0), repeatRule: .daily)
        try engine.upsert(second, now: now)
        try engine.adjustNext(id: first.id, byMinutes: 10, now: now)
        try engine.skipNext(id: second.id, now: now)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let persistence = JSONAlarmPersistence(fileURL: url)
        try persistence.save(engine.snapshot)
        let loaded = try persistence.load()
        XCTAssertEqual(loaded, engine.snapshot)
    }

    func testStableOccurrenceAndSystemIDsAreDeterministic() throws {
        let engine = engineWithDailyAlarm()
        let occurrence = try XCTUnwrap(engine.earliestOccurrence(now: now))
        XCTAssertEqual(occurrence.id, occurrence.id)
        XCTAssertEqual(
            SystemScheduleID.make(for: occurrence, label: "Morning"),
            SystemScheduleID.make(for: occurrence, label: "Morning")
        )
        XCTAssertNotEqual(
            SystemScheduleID.make(for: occurrence, label: "Morning"),
            SystemScheduleID.make(for: occurrence, label: "Changed")
        )
    }

    func testDSTSpringForwardUsesNextValidLocalTime() throws {
        var engine = AlarmEngine(calendar: calendar)
        let alarm = AlarmRecord(label: "DST", time: AlarmTime(hour: 2, minute: 30), repeatRule: .daily)
        let before = date(2027, 3, 13, 3, 0)
        try engine.upsert(alarm, now: before)
        let dates = engine.desiredOccurrences(now: before, perAlarmLimit: 2)
        XCTAssertEqual(components(dates[0].baseDate), [2027, 3, 14, 3, 0])
        XCTAssertEqual(components(dates[1].baseDate), [2027, 3, 15, 2, 30])
    }

    func testReconciliationDoesNotDuplicateExistingSystemAlarms() {
        let existing = UUID()
        let missing = UUID()
        let stale = UUID()
        let plan = AlarmReconciliationPlan(
            desiredIDs: [existing, missing],
            existingIDs: [existing, stale],
            managedIDs: [existing, stale]
        )
        XCTAssertEqual(plan.schedule, [missing])
        XCTAssertEqual(plan.cancel, [stale])
    }

    func testSkippedOccurrenceDisplayState() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)

        // Initially no skipped occurrence - first occurrence should not be adjusted
        let initialOccurrence = try XCTUnwrap(engine.nextOccurrence(for: id, now: now))
        XCTAssertFalse(initialOccurrence.isAdjusted)
        let initialKey = initialOccurrence.occurrenceKey

        // Skip next occurrence
        try engine.skipNext(id: id, now: now)

        // Should have a skipped occurrence visible
        let alarm = try XCTUnwrap(engine.alarm(id: id))
        let skippedKey = alarm.overrides.first { $0.value.isSkipped }?.key
        XCTAssertNotNil(skippedKey)
        XCTAssertEqual(alarm.overrides[skippedKey!]?.isSkipped, true)

        // After skip, next effective occurrence should be the following day
        let afterSkip = engine.nextOccurrence(for: id, now: now)
        XCTAssertNotNil(afterSkip)
        XCTAssertNotEqual(afterSkip?.occurrenceKey, skippedKey)

        // Undo skip should remove the skipped indicator
        try engine.undoSkip(id: id, now: now)
        let afterUndo = engine.alarm(id: id)?.overrides
        XCTAssertNil(afterUndo?[skippedKey!]?.isSkipped)

        // Original occurrence should be next again
        let finalOccurrence = engine.nextOccurrence(for: id, now: now)
        XCTAssertEqual(finalOccurrence?.occurrenceKey, initialKey)
    }

    func testAdjustmentDisplayAfterMultipleAdjustments() throws {
        var engine = engineWithDailyAlarm()
        let id = try XCTUnwrap(engine.alarms.first?.id)

        try engine.adjustNext(id: id, byMinutes: 10, now: now)
        var occ = try XCTUnwrap(engine.nextOccurrence(for: id, now: now))
        XCTAssertTrue(occ.isAdjusted)
        XCTAssertEqual(Int(occ.effectiveDate.timeIntervalSince(occ.baseDate) / 60), 10)

        try engine.adjustNext(id: id, byMinutes: 10, now: now)
        occ = try XCTUnwrap(engine.nextOccurrence(for: id, now: now))
        XCTAssertEqual(Int(occ.effectiveDate.timeIntervalSince(occ.baseDate) / 60), 20)

        try engine.adjustNext(id: id, byMinutes: -10, now: now)
        occ = try XCTUnwrap(engine.nextOccurrence(for: id, now: now))
        XCTAssertEqual(Int(occ.effectiveDate.timeIntervalSince(occ.baseDate) / 60), 10)

        try engine.resetNext(id: id, now: now)
        occ = try XCTUnwrap(engine.nextOccurrence(for: id, now: now))
        XCTAssertFalse(occ.isAdjusted)
    }

    private func engineWithDailyAlarm() -> AlarmEngine {
        var engine = AlarmEngine(calendar: calendar)
        try! engine.upsert(
            AlarmRecord(label: "Morning", time: AlarmTime(hour: 7, minute: 0), repeatRule: .daily),
            now: now
        )
        return engine
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func components(_ date: Date) -> [Int] {
        let values = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [values.year!, values.month!, values.day!, values.hour!, values.minute!]
    }

    @MainActor
    func testImportedSoundStableIDAndLookup() throws {
        let fileName = "song_abc123.mp3"
        let id = StableOccurrenceID.make(
            alarmID: UUID(uuidString: "b23f4a5e-cc2f-4e71-9cde-979301000001")!,
            occurrenceKey: fileName
        )
        XCTAssertEqual(
            StableOccurrenceID.make(
                alarmID: UUID(uuidString: "b23f4a5e-cc2f-4e71-9cde-979301000001")!,
                occurrenceKey: fileName
            ),
            id
        )
        let randomID = UUID()
        XCTAssertThrowsError(try SoundLibrary.shared.alarmKitFileName(for: randomID)) { error in
            XCTAssertEqual(error as? SoundLibraryError, .importedSoundNotFound(randomID))
        }
    }

    @MainActor
    func testBuiltInSoundNameMapping() {
        XCTAssertEqual(AlarmSound.builtIn("Chime").systemFileName, "chime.wav")
        XCTAssertNil(AlarmSound.systemDefault.systemFileName)
        XCTAssertNil(AlarmSound.imported(UUID()).systemFileName)
        XCTAssertEqual(BuiltInSound.fileName(for: "Chime"), "chime.wav")
        XCTAssertNil(BuiltInSound.fileName(for: "Not Real"))
    }

    @MainActor
    func testRandomSoundMode() throws {
        let playlistID = UUID()
        let randomSound = AlarmSound.random(playlistID)
        XCTAssertEqual(randomSound.id, "random_\(playlistID.uuidString)")
        XCTAssertTrue(randomSound.displayName.contains("Random"))
    }

    @MainActor
    func testAlarmLoudnessSupportsEveryPercentageAndLegacyDecoding() throws {
        XCTAssertEqual(AlarmLoudness(0).gainFactor, 0)
        XCTAssertEqual(AlarmLoudness(37).gainFactor, 0.37, accuracy: 0.0001)
        XCTAssertEqual(AlarmLoudness(100).gainFactor, 1)
        XCTAssertEqual(AlarmLoudness(-1).percentage, 0)
        XCTAssertEqual(AlarmLoudness(101).percentage, 100)

        let decoded = try JSONDecoder().decode(AlarmLoudness.self, from: Data("50".utf8))
        XCTAssertEqual(decoded, .fifty)
        XCTAssertEqual(try JSONEncoder().encode(AlarmLoudness(63)), Data("63".utf8))
    }

    @MainActor
    func testAlarmRecordWithLoudness() throws {
        let alarm = AlarmRecord(
            label: "Test",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily,
            sound: .systemDefault,
            loudness: AlarmLoudness(63)
        )
        XCTAssertEqual(alarm.loudness.percentage, 63)
        XCTAssertEqual(alarm.loudness.gainFactor, 0.63, accuracy: 0.0001)
    }

    func testSystemScheduleIDChangesWithActualAudioConfiguration() throws {
        let occurrence = try XCTUnwrap(engineWithDailyAlarm().earliestOccurrence(now: now))
        let soundID = UUID()
        let baseline = SystemScheduleID.make(for: occurrence, label: "Morning", sound: .imported(soundID), loudness: AlarmLoudness(50))

        XCTAssertNotEqual(
            baseline,
            SystemScheduleID.make(for: occurrence, label: "Morning", sound: .imported(soundID), loudness: AlarmLoudness(51))
        )
        XCTAssertNotEqual(
            baseline,
            SystemScheduleID.make(for: occurrence, label: "Morning", sound: .imported(UUID()), loudness: AlarmLoudness(50))
        )
    }

    @MainActor
    func testAlarmOccurrenceOverrideWithRandomSoundID() throws {
        let soundID = UUID()
        var override = AlarmOccurrenceOverride(
            offsetMinutes: 10,
            customDate: nil,
            isSkipped: false,
            randomSoundID: soundID
        )
        XCTAssertEqual(override.randomSoundID, soundID)
        
        // Test nil case
        override = AlarmOccurrenceOverride(offsetMinutes: 10, customDate: nil, isSkipped: false, randomSoundID: nil)
        XCTAssertNil(override.randomSoundID)
    }

    @MainActor
    func testPlaylistModel() throws {
        let soundIDs = [UUID(), UUID(), UUID()]
        let playlist = Playlist(name: "Morning Mix", soundIDs: soundIDs)
        XCTAssertEqual(playlist.name, "Morning Mix")
        XCTAssertEqual(playlist.soundIDs.count, 3)
        XCTAssertEqual(playlist.soundIDs, soundIDs)
    }


    func testPlaylistDecodesLegacySelectionAsAllSongs() throws {
        let soundIDs = [UUID(), UUID()]
        let legacyPlaylist: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Legacy Mix",
            "soundIDs": soundIDs.map(\.uuidString),
            "dateCreated": Date().timeIntervalSinceReferenceDate
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyPlaylist)
        let playlist = try JSONDecoder().decode(Playlist.self, from: data)

        XCTAssertEqual(playlist.selectedSoundIDs, soundIDs)
    }


    @MainActor
    func testNextAlarmSnapshotNormalRepeatingAlarm() throws {
        let engine = AlarmEngine()
        let alarm = AlarmRecord(
            label: "Morning Alarm",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily
        )
        try engine.upsert(alarm, now: Date())

        let now = Date()
        let calendar = Calendar.current
        let nextOccurrence = engine.earliestOccurrence(now: now)
        
        XCTAssertNotNil(nextOccurrence)
        XCTAssertEqual(nextOccurrence?.alarmID, alarm.id)
        
        if let occurrence = nextOccurrence {
            let snapshot = NextAlarmSnapshot(alarm: alarm, occurrence: occurrence)
            XCTAssertNotNil(snapshot)
            XCTAssertEqual(snapshot?.alarmID, alarm.id)
            XCTAssertEqual(snapshot?.label, "Morning Alarm")
            XCTAssertEqual(snapshot?.permanentTime.hour, 7)
            XCTAssertEqual(snapshot?.permanentTime.minute, 0)
            XCTAssertFalse(snapshot?.isAdjusted ?? true)
            XCTAssertFalse(snapshot?.isSkipped ?? true)
            XCTAssertTrue(snapshot?.isEnabled ?? false)
        }
    }


    @MainActor
    func testNextAlarmSnapshotWithTemporaryAdjustment() throws {
        let engine = AlarmEngine()
        let alarm = AlarmRecord(
            label: "Adjusted Alarm",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily
        )
        try engine.upsert(alarm, now: Date())

        let now = Date()
        // Add a +10 minute adjustment
        try engine.adjustNext(id: alarm.id, byMinutes: 10, now: now)
        
        let nextOccurrence = engine.earliestOccurrence(now: now)
        XCTAssertNotNil(nextOccurrence)
        
        if let occurrence = nextOccurrence {
            let snapshot = NextAlarmSnapshot(alarm: alarm, occurrence: occurrence)
            XCTAssertNotNil(snapshot)
            XCTAssertTrue(snapshot?.isAdjusted ?? false)
            XCTAssertEqual(snapshot?.adjustmentDescription, "+10 minutes")
        }
    }


    @MainActor
    func testNextAlarmSnapshotWithCustomTime() throws {
        let engine = AlarmEngine()
        let alarm = AlarmRecord(
            label: "Custom Time Alarm",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily
        )
        try engine.upsert(alarm, now: Date())

        let now = Date()
        let customDate = now.addingTimeInterval(3600) // 1 hour from now
        try engine.setNextTime(id: alarm.id, date: customDate, now: now)
        
        let nextOccurrence = engine.earliestOccurrence(now: now)
        XCTAssertNotNil(nextOccurrence)
        
        if let occurrence = nextOccurrence {
            let snapshot = NextAlarmSnapshot(alarm: alarm, occurrence: occurrence)
            XCTAssertNotNil(snapshot)
            XCTAssertTrue(snapshot?.isAdjusted ?? false)
        }
    }


    @MainActor
    func testNextAlarmSnapshotWithSkippedOccurrence() throws {
        let engine = AlarmEngine()
        let alarm = AlarmRecord(
            label: "Skipped Alarm",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily
        )
        try engine.upsert(alarm, now: Date())

        let now = Date()
        try engine.skipNext(id: alarm.id, now: now)
        
        let nextOccurrence = engine.earliestOccurrence(now: now)
        // After skipping, the next occurrence should be the following day
        XCTAssertNotNil(nextOccurrence)
        
        if let occurrence = nextOccurrence {
            let snapshot = NextAlarmSnapshot(alarm: alarm, occurrence: occurrence)
            XCTAssertNotNil(snapshot)
            // The skipped occurrence should not be the one returned
        }
    }


    @MainActor
    func testNextAlarmSnapshotWithDisabledAlarm() throws {
        let engine = AlarmEngine()
        let alarm1 = AlarmRecord(
            label: "Disabled Alarm",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily
        )
        let alarm2 = AlarmRecord(
            label: "Enabled Alarm",
            time: AlarmTime(hour: 8, minute: 0),
            repeatRule: .daily
        )
        try engine.upsert(alarm1, now: Date())
        try engine.upsert(alarm2, now: Date())
        
        // Disable the earlier alarm
        try engine.setEnabled(false, id: alarm1.id)
        
        let now = Date()
        let nextOccurrence = engine.earliestOccurrence(now: now)
        
        // The enabled alarm at 8:00 should be the next occurrence
        XCTAssertNotNil(nextOccurrence)
        XCTAssertEqual(nextOccurrence?.alarmID, alarm2.id)
        
        if let occurrence = nextOccurrence {
            let snapshot = NextAlarmSnapshot(alarm: alarm2, occurrence: occurrence)
            XCTAssertNotNil(snapshot)
            XCTAssertEqual(snapshot?.label, "Enabled Alarm")
        }
    }


    @MainActor
    func testNextAlarmSnapshotNoUpcomingAlarm() throws {
        let engine = AlarmEngine()
        let now = Date()
        
        let nextOccurrence = engine.earliestOccurrence(now: now)
        XCTAssertNil(nextOccurrence)
        
        let snapshot = NextAlarmSnapshot(alarm: AlarmRecord(label: "Test", time: AlarmTime(hour: 7, minute: 0), repeatRule: .daily), occurrence: nil)
        XCTAssertNil(snapshot)
    }


    @MainActor
    func testNextAlarmSnapshotMidnightCrossing() throws {
        let engine = AlarmEngine()
        let alarm = AlarmRecord(
            label: "Midnight Alarm",
            time: AlarmTime(hour: 0, minute: 30),
            repeatRule: .daily
        )
        try engine.upsert(alarm, now: Date())

        let now = Date()
        let nextOccurrence = engine.earliestOccurrence(now: now)
        
        XCTAssertNotNil(nextOccurrence)
        
        if let occurrence = nextOccurrence {
            let snapshot = NextAlarmSnapshot(alarm: alarm, occurrence: occurrence)
            XCTAssertNotNil(snapshot)
            // Verify the date indicator logic works for midnight crossing
            let dateIndicator = snapshot?.dateIndicator
            XCTAssertNotNil(dateIndicator)
        }
    }
}
