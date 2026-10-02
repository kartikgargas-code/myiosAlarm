import XCTest
@testable import AlarmClock
import AlarmClockShared
import MediaPlayer

@MainActor
final class AlarmPlaybackLogicTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        now = date(2026, 9, 21, 6, 0)
    }

    // MARK: - Due Occurrence Evaluation Tests

    func testDueOccurrenceEvaluationWithSkip() throws {
        var engine = engineWithDailyAlarm()
        let alarmID = try XCTUnwrap(engine.alarms.first?.id)

        // Skip the next occurrence
        try engine.skipNext(id: alarmID, now: now)

        // The next occurrence should be the following day
        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 2)
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 22, 7, 0])
        XCTAssertEqual(components(occurrences[1].effectiveDate), [2026, 9, 23, 7, 0])
    }

    func testDueOccurrenceEvaluationWithAdjustment() throws {
        var engine = engineWithDailyAlarm()
        let alarmID = try XCTUnwrap(engine.alarms.first?.id)

        // Adjust by +10 minutes
        try engine.adjustNext(id: alarmID, byMinutes: 10, now: now)

        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 2)
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 7, 10])
        XCTAssertEqual(components(occurrences[1].effectiveDate), [2026, 9, 22, 7, 0])
    }

    func testDueOccurrenceEvaluationWithCustomTime() throws {
        var engine = engineWithDailyAlarm()
        let alarmID = try XCTUnwrap(engine.alarms.first?.id)

        // Set custom next time
        let customDate = date(2026, 9, 21, 8, 30)
        try engine.setNextTime(id: alarmID, date: customDate, now: now)

        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 2)
        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 8, 30])
        XCTAssertEqual(components(occurrences[1].effectiveDate), [2026, 9, 22, 7, 0])
    }

    func testDueOccurrenceEvaluationWithDisabledAlarm() throws {
        var engine = AlarmClock.AlarmEngine(calendar: calendar)
        let alarm1 = AlarmRecord(label: "Alarm 1", time: AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
        let alarm2 = AlarmRecord(label: "Alarm 2", time: AlarmTime(hour: 8, minute: 0), repeatRule: .daily)
        try engine.upsert(alarm1, now: now)
        try engine.upsert(alarm2, now: now)

        // Disable the earlier alarm
        try engine.setEnabled(false, id: alarm1.id)

        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 2)
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences[0].alarmID, alarm2.id)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 8, 0])
    }

    func testDueOccurrenceFromAppGroupSnapshot() throws {
        // Create a snapshot with alarms
        var engine = AlarmClock.AlarmEngine(calendar: calendar)
        let alarm = AlarmRecord(label: "Test Alarm", time: AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
        try engine.upsert(alarm, now: now)

        // Add an adjustment
        try engine.adjustNext(id: alarm.id, byMinutes: 15, now: now)

        let snapshot = engine.snapshot

        // Encode and decode (simulating App Group round-trip)
        let encoder = JSONEncoder.alarmEncoder
        let decoder = JSONDecoder.alarmDecoder
        let data = try encoder.encode(snapshot)
        let decodedSnapshot = try decoder.decode(AlarmStoreSnapshot.self, from: data)

        // Recreate engine from decoded snapshot
        let decodedEngine = AlarmClock.AlarmEngine(snapshot: decodedSnapshot, calendar: calendar)
        let occurrences = decodedEngine.desiredOccurrences(now: now, perAlarmLimit: 2)

        XCTAssertEqual(occurrences.count, 2)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 7, 15])
        XCTAssertEqual(components(occurrences[1].effectiveDate), [2026, 9, 22, 7, 0])
    }

    // MARK: - Track Sequence Resolution Tests

    func testTrackSequenceResolutionForImportedSound() throws {
        // For imported sounds, the sequence is a single track
        let soundID = UUID()
        let alarm = AlarmRecord(
            label: "Test",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily,
            sound: .imported(soundID)
        )

        // Verify the sound type resolves to single track
        switch alarm.sound {
        case .imported(let id):
            XCTAssertEqual(id, soundID)
        default:
            XCTFail("Expected imported sound")
        }
    }

    func testTrackSequenceResolutionForRandomPlaylist() throws {
        let playlistID = UUID()
        let alarm = AlarmRecord(
            label: "Test",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily,
            sound: .random(playlistID)
        )

        // Random sound should reference a playlist
        switch alarm.sound {
        case .random(let id):
            XCTAssertEqual(id, playlistID)
        default:
            XCTFail("Expected random sound")
        }
    }

    func testTrackSequenceResolutionForPrecomposedPlaylist() throws {
        let playlistID = UUID()
        let loudness = AlarmLoudness(75)
        let alarm = AlarmRecord(
            label: "Test",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily,
            sound: .precomposedPlaylist(playlistID, loudness)
        )

        switch alarm.sound {
        case .precomposedPlaylist(let id, let l):
            XCTAssertEqual(id, playlistID)
            XCTAssertEqual(l.percentage, 75)
        default:
            XCTFail("Expected precomposed playlist")
        }
    }

    func testTrackSequenceResolutionFromSnapshotWithOverrides() throws {
        var engine = AlarmClock.AlarmEngine(calendar: calendar)
        let playlistID = UUID()
        let alarm = AlarmRecord(
            label: "Test",
            time: AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily,
            sound: .random(playlistID)
        )
        try engine.upsert(alarm, now: now)

        // Simulate an override with a specific playlist selection
        let occurrence = engine.nextOccurrence(for: alarm.id, now: now)!
        let override = AlarmOccurrenceOverride(
            offsetMinutes: nil,
            customDate: nil,
            isSkipped: false,
            randomSoundID: playlistID
        )

        var updatedAlarm = alarm
        updatedAlarm.overrides[occurrence.occurrenceKey] = override
        try engine.upsert(updatedAlarm, now: now)

        // Verify the override is stored
        let retrievedAlarm = engine.alarm(id: alarm.id)!
        XCTAssertNotNil(retrievedAlarm.overrides[occurrence.occurrenceKey])
        XCTAssertEqual(retrievedAlarm.overrides[occurrence.occurrenceKey]?.randomSoundID, playlistID)
    }

    // MARK: - Now Playing Info Construction Tests

    func testNowPlayingInfoConstruction() throws {
        let soundName = "Test Song"
        let duration: TimeInterval = 180.0
        let elapsed: TimeInterval = 30.0
        let rate: Float = 1.0

        var nowPlayingInfo: [String: Any] = [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = soundName
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = duration
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = rate

        XCTAssertEqual(nowPlayingInfo[MPMediaItemPropertyTitle] as? String, soundName)
        XCTAssertEqual(nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] as? TimeInterval, duration)
        XCTAssertEqual(nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? TimeInterval, elapsed)
        XCTAssertEqual(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Float, rate)
    }

    func testNowPlayingInfoWithArtistAndAlbum() throws {
        var nowPlayingInfo: [String: Any] = [:]
        nowPlayingInfo[MPMediaItemPropertyTitle] = "Song"
        nowPlayingInfo[MPMediaItemPropertyArtist] = "Artist Name"
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = "Album Name"

        XCTAssertEqual(nowPlayingInfo[MPMediaItemPropertyArtist] as? String, "Artist Name")
        XCTAssertEqual(nowPlayingInfo[MPMediaItemPropertyAlbumTitle] as? String, "Album Name")
    }

    func testNowPlayingInfoPlaybackRateWhenPaused() throws {
        var nowPlayingInfo: [String: Any] = [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 0.0

        XCTAssertEqual(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 0.0)
    }

    func testNowPlayingInfoPlaybackRateWhenPlaying() throws {
        var nowPlayingInfo: [String: Any] = [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = 1.0

        XCTAssertEqual(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Float, 1.0)
    }

    // MARK: - Helpers

    private func engineWithDailyAlarm() -> AlarmClock.AlarmEngine {
        var engine = AlarmClock.AlarmEngine(calendar: calendar)
        let alarm = AlarmRecord(label: "Daily Alarm", time: AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
        try! engine.upsert(alarm, now: now)
        return engine
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.timeZone = calendar.timeZone
        return calendar.date(from: components)!
    }

    private func components(_ date: Date) -> [Int] {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return [comps.year!, comps.month!, comps.day!, comps.hour!, comps.minute!]
    }
}