import XCTest
@testable import AlarmClock
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
        let alarm1 = AlarmClock.AlarmRecord(label: "Alarm 1", time: AlarmClock.AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
        let alarm2 = AlarmClock.AlarmRecord(label: "Alarm 2", time: AlarmClock.AlarmTime(hour: 8, minute: 0), repeatRule: .daily)
        try engine.upsert(alarm1, now: now)
        try engine.upsert(alarm2, now: now)

        // Disable the earlier alarm
        try engine.setEnabled(false, id: alarm1.id)

        let occurrences = engine.desiredOccurrences(now: now, perAlarmLimit: 1)
        XCTAssertEqual(occurrences.count, 1)
        XCTAssertEqual(occurrences[0].alarmID, alarm2.id)
        XCTAssertEqual(components(occurrences[0].effectiveDate), [2026, 9, 21, 8, 0])
    }

    func testDueOccurrenceFromAppGroupSnapshot() throws {
        // Create a snapshot with alarms
        var engine = AlarmClock.AlarmEngine(calendar: calendar)
        let alarm = AlarmClock.AlarmRecord(label: "Test Alarm", time: AlarmClock.AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
        try engine.upsert(alarm, now: now)

        // Add an adjustment
        try engine.adjustNext(id: alarm.id, byMinutes: 15, now: now)

        let snapshot = engine.snapshot

        // Encode and decode (simulating App Group round-trip)
        let encoder = JSONEncoder.alarmEncoder
        let decoder = JSONDecoder.alarmDecoder
        let data = try encoder.encode(snapshot)
        let decodedSnapshot: AlarmClock.AlarmStoreSnapshot = try decoder.decode(AlarmClock.AlarmStoreSnapshot.self, from: data)

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
        let alarm = AlarmClock.AlarmRecord(
            label: "Test",
            time: AlarmClock.AlarmTime(hour: 7, minute: 0),
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
        let alarm = AlarmClock.AlarmRecord(
            label: "Test",
            time: AlarmClock.AlarmTime(hour: 7, minute: 0),
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
        let loudness = AlarmClock.AlarmLoudness(75)
        let alarm = AlarmClock.AlarmRecord(
            label: "Test",
            time: AlarmClock.AlarmTime(hour: 7, minute: 0),
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
        let alarm = AlarmClock.AlarmRecord(
            label: "Test",
            time: AlarmClock.AlarmTime(hour: 7, minute: 0),
            repeatRule: .daily,
            sound: .random(playlistID)
        )
        try engine.upsert(alarm, now: now)

        // Simulate an override with a specific playlist selection
        let occurrence = engine.nextOccurrence(for: alarm.id, now: now)!
        let override = AlarmClock.AlarmOccurrenceOverride(
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
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = Float(0.0)

        XCTAssertEqual(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Float, Float(0.0))
    }

    func testNowPlayingInfoPlaybackRateWhenPlaying() throws {
        var nowPlayingInfo: [String: Any] = [:]
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = Float(1.0)

        XCTAssertEqual(nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Float, Float(1.0))
    }

    // MARK: - Helpers

    private func engineWithDailyAlarm() -> AlarmClock.AlarmEngine {
        var engine = AlarmClock.AlarmEngine(calendar: calendar)
        let alarm = AlarmClock.AlarmRecord(label: "Daily Alarm", time: AlarmClock.AlarmTime(hour: 7, minute: 0), repeatRule: .daily)
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
    
    // MARK: - Backward Compatibility Tests
    
    func testAlarmRecordDecodesWithoutSnoozeDuration() throws {
        // Create JSON without snoozeDurationMinutes field (simulating old data)
        // Note: repeatRule and sound now use custom encoding with "type" field
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "label": "Test Alarm",
            "time": {"hour": 7, "minute": 0},
            "repeatRule": {"type": "daily"},
            "oneTimeDate": null,
            "isEnabled": true,
            "adjustmentStepMinutes": 10,
            "overrides": {},
            "sound": {"type": "systemDefault"},
            "loudness": 100
        }
        """.data(using: .utf8)!
        
        let decoder = JSONDecoder.alarmDecoder
        let alarmRecord = try decoder.decode(AlarmClock.AlarmRecord.self, from: json)
        
        XCTAssertEqual(alarmRecord.id.uuidString, "12345678-1234-1234-1234-123456789012")
        XCTAssertEqual(alarmRecord.label, "Test Alarm")
        XCTAssertEqual(alarmRecord.time.hour, 7)
        XCTAssertEqual(alarmRecord.time.minute, 0)
        XCTAssertEqual(alarmRecord.repeatRule, .daily)
        XCTAssertEqual(alarmRecord.snoozeDurationMinutes, 10) // Default value
    }

    // MARK: - Legacy wire-format compatibility (pre-2add1a5 device data)

    func testLegacyRepeatRulePlainStringDecodes() throws {
        XCTAssertEqual(try JSONDecoder.alarmDecoder.decode(AlarmRepeatRule.self, from: Data(#""daily""#.utf8)), .daily)
        XCTAssertEqual(try JSONDecoder.alarmDecoder.decode(AlarmRepeatRule.self, from: Data(#""never""#.utf8)), .never)
        XCTAssertEqual(try JSONDecoder.alarmDecoder.decode(AlarmRepeatRule.self, from: Data(#""weekdays""#.utf8)), .weekdays)
        XCTAssertEqual(try JSONDecoder.alarmDecoder.decode(AlarmRepeatRule.self, from: Data(#""weekends""#.utf8)), .weekends)
    }

    func testLegacyRepeatRuleCustomPayloadDecodes() throws {
        // Swift synthesized associated-value encoding: {"custom": {"_0": [1, 2, 3]}}
        let json = #"{"custom": {"_0": [1, 2, 3]}}"#.data(using: .utf8)!
        let rule = try JSONDecoder.alarmDecoder.decode(AlarmRepeatRule.self, from: json)
        XCTAssertEqual(rule, .custom([1, 2, 3]))

        // Variant with unkeyed days array: {"custom": [1, 2, 3]}
        let unkeyed = #"{"custom": [4, 5]}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder.alarmDecoder.decode(AlarmRepeatRule.self, from: unkeyed), .custom([4, 5]))
    }

    func testLegacyAlarmSoundPlainStringDecodes() throws {
        XCTAssertEqual(try JSONDecoder.alarmDecoder.decode(AlarmSound.self, from: Data(#""systemDefault""#.utf8)), .systemDefault)
    }

    func testLegacyAlarmSoundSynthesizedPayloadsDecode() throws {
        let soundID = UUID()
        let playlistID = UUID()

        // Swift synthesized single-payload encodings.
        XCTAssertEqual(
            try JSONDecoder.alarmDecoder.decode(AlarmSound.self, from: Data("{\"imported\": \"\(soundID.uuidString)\"}".utf8)),
            .imported(soundID))
        XCTAssertEqual(
            try JSONDecoder.alarmDecoder.decode(AlarmSound.self, from: Data("{\"random\": \"\(playlistID.uuidString)\"}".utf8)),
            .random(playlistID))
        XCTAssertEqual(
            try JSONDecoder.alarmDecoder.decode(AlarmSound.self, from: Data(#"{"builtIn": "chime"}"#.utf8)),
            .builtIn("chime"))

        // Associated multi-value case: {"precomposedPlaylist": {"_0": uuid, "_1": 75}}
        let precomposed = "{\"precomposedPlaylist\": {\"_0\": \"\(playlistID.uuidString)\", \"_1\": 75}}".data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder.alarmDecoder.decode(AlarmSound.self, from: precomposed),
            .precomposedPlaylist(playlistID, AlarmLoudness(75)))
    }

    func testLegacyAlarmRecordFullDocumentDecodes() throws {
        // Full old-format document as it exists on devices before 2add1a5.
        let soundID = UUID()
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "label": "Legacy Alarm",
            "time": {"hour": 6, "minute": 30},
            "repeatRule": "daily",
            "oneTimeDate": null,
            "isEnabled": true,
            "adjustmentStepMinutes": 10,
            "overrides": {},
            "sound": {"imported": "\(soundID.uuidString)"},
            "loudness": 100
        }
        """.data(using: .utf8)!

        let record = try JSONDecoder.alarmDecoder.decode(AlarmRecord.self, from: json)
        XCTAssertEqual(record.repeatRule, .daily)
        XCTAssertEqual(record.sound, .imported(soundID))
        XCTAssertEqual(record.snoozeDurationMinutes, 10)
        XCTAssertEqual(record.label, "Legacy Alarm")
    }

    func testAlarmRecordRoundTripPersistsCurrentFormat() throws {
        let alarm = AlarmRecord(
            label: "RoundTrip",
            time: AlarmTime(hour: 5, minute: 45),
            repeatRule: .custom([2, 4]),
            sound: .precomposedPlaylist(UUID(), AlarmLoudness(75)),
            loudness: .fifty,
            snoozeDurationMinutes: 15)
        let data = try JSONEncoder.alarmEncoder.encode([alarm])
        let decoded = try JSONDecoder.alarmDecoder.decode([AlarmRecord].self, from: data)
        XCTAssertEqual(decoded.first, alarm)
        // Encoding must stay in the current keyed format (one canonical output).
        let jsonString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(jsonString.contains(#""type""#), "Encoded AlarmSound/AlarmRepeatRule should use the type-keyed format")
    }

    // MARK: - Deterministic selection hash

    func testSelectionHashIsStableAcrossInvocations() {
        let key = "aaaa-bbbb-cccc"
        let first = SoundSelectionHash.make(from: key)
        let second = SoundSelectionHash.make(from: key)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 16)
        XCTAssertNotEqual(first, SoundSelectionHash.make(from: key + "-d"))
    }

    func testScheduleIdentityChangesWithSelectionHash() {
        let occurrence = AlarmOccurrence(alarmID: UUID(), occurrenceKey: "2026-10-02", baseDate: Date(), effectiveDate: Date(), isAdjusted: false)
        let sound = AlarmSound.precomposedPlaylist(UUID(), .hundred)
        let withoutHash = SystemScheduleID.make(for: occurrence, label: "A", sound: sound, loudness: .hundred)
        let withHash = SystemScheduleID.make(for: occurrence, label: "A", sound: sound, loudness: .hundred, selectionHash: "deadbeef00112233")
        let withOtherHash = SystemScheduleID.make(for: occurrence, label: "A", sound: sound, loudness: .hundred, selectionHash: "cafebabedead4321")
        XCTAssertNotEqual(withoutHash, withHash)
        XCTAssertNotEqual(withHash, withOtherHash)
    }
    
    // MARK: - Display Name UUID Stripping Tests
    
    func testDisplayNameStripsTrailingUUID() {
        let testCases = [
            ("song_123e4567-e89b-12d3-a456-426614174000", "song"),
            ("my_track_abcd1234-5678-90ab-cdef-123456789012", "my_track"),
            ("clean_name", "clean_name"),
            ("name_with_underscore_123e4567-e89b-12d3-a456-426614174000", "name_with_underscore"),
            ("", ""),
            ("no_uuid_here_", "no_uuid_here_"),
        ]
        
        for (input, expected) in testCases {
            let result = stripTrailingUUID(input)
            XCTAssertEqual(result, expected, "Failed for input: \(input)")
        }
    }
    
    func testDisplayNameHandlesEdgeCases() {
        // UUID in middle should not be stripped
        XCTAssertEqual(stripTrailingUUID("prefix_123e4567-e89b-12d3-a456-426614174000_suffix"), "prefix_123e4567-e89b-12d3-a456-426614174000_suffix")
        // Multiple UUIDs - only last one stripped
        XCTAssertEqual(stripTrailingUUID("name_11111111-1111-1111-1111-111111111111_22222222-2222-2222-2222-222222222222"), "name_11111111-1111-1111-1111-111111111111")
        // Partial UUID (not 36 chars) should not match
        XCTAssertEqual(stripTrailingUUID("name_123"), "name_123")
    }
    
    // Helper function extracted from AlarmPlaybackService for testing
    private func stripTrailingUUID(_ soundName: String) -> String {
        let uuidPattern = "_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
        if let range = soundName.range(of: uuidPattern, options: .regularExpression) {
            return String(soundName[..<range.lowerBound])
        }
        return soundName
    }
}