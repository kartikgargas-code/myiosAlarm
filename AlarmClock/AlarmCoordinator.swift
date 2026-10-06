import AlarmKit
import ActivityKit
import Foundation
import Observation
import WidgetKit
import UserNotifications
import os.log

@MainActor
@Observable
final class AlarmCoordinator {
    static var sharedInstance: AlarmCoordinator?
    
    // Phase 7a: Delayed backup for playlist alarms when Smart Wake is enabled
    // Schedule AlarmKit backup at occurrence.effectiveDate + backupDelaySeconds
    static let backupDelaySeconds = 30

    private(set) var alarms: [AlarmRecord] = []
    private(set) var nextOccurrence: AlarmOccurrence?
    var lastError: String? = nil
    /// Non-fatal per-alarm issues from the last commit (e.g. one alarm's sound
    /// failed to precompose). The alarm list still saved; affected system
    /// alarms were skipped this round.
    private(set) var lastWarnings: [String] = []
    private let warningLog = OSLog(subsystem: "com.example.alarmclock", category: "CommitWarnings")
    // Store the engine modified by desiredSystemAlarms to persist random sound selections
    private var desiredSystemAlarmsEngine: AlarmEngine?

    // Playlist diagnostics
    var playlistDiagnostics = PlaylistDiagnostics()

    /// Play history - tracks songs that finished playing during alarm rings
    private(set) var playHistory: [PlayHistoryEntry] = []

    /// The computed next alarm snapshot for widgets and Lock Screen controls
    private(set) var nextAlarmSnapshot: NextAlarmSnapshot? = nil

    /// Diagnostic: last snapshot write result
    private(set) var lastSnapshotWriteResult: (success: Bool, error: String?, timestamp: Date?) = (true, nil, nil)

    /// Diagnostic: last WidgetCenter reload request timestamp
    private(set) var lastWidgetReloadRequest: Date? = nil

    /// Feedback message for Control Center actions (shown as toast or notification)
    var ccActionFeedback: String? = nil

    /// Live Activity / Dynamic Island toggle — when false, never request and end all existing on launch
    static let liveActivityEnabled = false

    /// Live Activity for Dynamic Island
    private var liveActivity: Activity<NextAlarmAttributes>?

    private var engine: AlarmEngine
    private let persistence: any AlarmPersisting
    private let scheduler: any AlarmSystemScheduling
    private let now: () -> Date
    private let maxHistoryEntries = 200
    private let ringDetectionOSLog = OSLog(subsystem: "com.example.alarmclock", category: "RingDetection")

    // Track emergency re-ring IDs so reconcile doesn't cancel them as orphans
    private var emergencyReRingIDs: Set<UUID> = []

    init(
        persistence: any AlarmPersisting = JSONAlarmPersistence(),
        scheduler: (any AlarmSystemScheduling)? = nil,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping () -> Date = Date.init
    ) {
        self.persistence = persistence
        if let scheduler {
            self.scheduler = scheduler
        } else {
            #if DIAGNOSTIC_BUILD
            self.scheduler = DiagnosticAlarmSchedulingService()
            #else
            self.scheduler = AlarmKitSchedulingService()
            #endif
        }
        self.now = now
        do {
            engine = AlarmEngine(snapshot: try persistence.load(), calendar: calendar)
            // Load play history from snapshot
            if let snapshot = try? persistence.load() {
                self.playHistory = snapshot.playHistory
            }
        } catch {
            engine = AlarmEngine(calendar: calendar)
            lastError = "Could not load alarms: \(error.localizedDescription)"
        }
        publish()
        // End all Live Activities on launch if disabled
        endAllLiveActivitiesOnLaunch()
    }

    func synchronize() async {
        // Consume any queued Control Center action before the no-op reconcile —
        // otherwise a foreground commit could overwrite the file unread.
        await applyPendingWidgetActions()
        await commit({ _ in }, reason: "synchronize")
    }

    func save(_ alarm: AlarmRecord) async {
        let idsBefore = engine.snapshot.alarms.map { $0.id }
        SmartWakeDebugLog.log("ALARM SAVE: before count=\(idsBefore.count) ids=\(idsBefore.map { $0.uuidString.prefix(8) }.joined(separator: \", \"))")
        await commit({ try $0.upsert(alarm, now: self.now()) }, reason: "save")
        let idsAfter = engine.snapshot.alarms.map { $0.id }
        SmartWakeDebugLog.log("ALARM SAVE: after count=\(idsAfter.count) ids=\(idsAfter.map { $0.uuidString.prefix(8) }.joined(separator: \", \"))")
    }

    func delete(id: UUID) async {
        let idsBefore = engine.snapshot.alarms.map { $0.id }
        SmartWakeDebugLog.log("ALARM DELETE: before count=\(idsBefore.count) ids=\(idsBefore.map { $0.uuidString.prefix(8) }.joined(separator: \", \"))")
        await commit({ $0.delete(id: id) }, reason: "delete")
        let idsAfter = engine.snapshot.alarms.map { $0.id }
        SmartWakeDebugLog.log("ALARM DELETE: after count=\(idsAfter.count) ids=\(idsAfter.map { $0.uuidString.prefix(8) }.joined(separator: \", \"))")
    }

    func setEnabled(_ enabled: Bool, id: UUID) async {
        let perfStart = CFAbsoluteTimeGetCurrent()
        SmartWakeDebugLog.log("PERF: setEnabled start id=\(id.uuidString.prefix(8)) enabled=\(enabled)")
        // Fast-path: mutate engine + persist immediately so UI flips instantly.
        // Then run reconciliation (sound resolution + AlarmKit) in background.
        var candidate = engine
        do {
            try candidate.setEnabled(enabled, id: id)
            candidate.pruneExpiredOverrides(now: now())
            try persistence.save(candidate.snapshot)
            writeAlarmsToAppGroup(candidate.snapshot)
            engine = candidate
            publish() // UI updates immediately
            SmartWakeDebugLog.log("PERF: setEnabled done in \(Int((CFAbsoluteTimeGetCurrent() - perfStart) * 1000))ms (reconcile continues in background)")
        } catch {
            lastError = error.localizedDescription
            SmartWakeDebugLog.log("PERF: setEnabled FAILED in \(Int((CFAbsoluteTimeGetCurrent() - perfStart) * 1000))ms: \(error.localizedDescription)")
            return
        }
        
        // Background reconciliation - does not block UI
        Task { @MainActor in
            await performCommit({ _ in }, reason: "toggle")
        }
    }

    func adjustNext(id: UUID, minutes: Int) async {
        await commit({ try $0.adjustNext(id: id, byMinutes: minutes, now: self.now()) }, reason: "adjust")
    }

    func setNextTime(id: UUID, date: Date) async {
        await commit({ try $0.setNextTime(id: id, date: date, now: self.now()) }, reason: "setNextTime")
    }

    func resetNext(id: UUID) async {
        await commit({ try $0.resetNext(id: id, now: self.now()) }, reason: "resetNext")
    }

    func skipNext(id: UUID) async {
        await commit({ try $0.skipNext(id: id, now: self.now()) }, reason: "skipNext")
    }

    func undoSkip(id: UUID) async {
        await commit({ try $0.undoSkip(id: id, now: self.now()) }, reason: "undoSkip")
    }

    func occurrence(for alarmID: UUID) -> AlarmOccurrence? {
        engine.nextOccurrence(for: alarmID, now: now())
    }

    /// Resolve the display name of the song for the currently/next ringing alarm
    /// Returns nil if no alarm is due or currently ringing
    func currentRingSongName() -> String? {
        return currentlyRingingAlarm()?.songName
    }
    
    /// SINGLE SOURCE OF TRUTH for ring detection â€” do not add a second check elsewhere.
    /// Uses AlarmKit's actual .alerting state to determine what's currently ringing.
    /// Returns (songName, alarmRecord) if an alarm is actively alerting, nil otherwise.
    func currentlyRingingAlarm() -> (songName: String, alarm: AlarmRecord)? {
        let kitManager = AlarmManager.shared
        let currentDate = now()

        // Find the alarm that's currently in .alerting state
        // Note: AlarmKit's alarms collection access may throw
        let alertingAlarms: [Alarm]
        do {
            alertingAlarms = try kitManager.alarms.filter { $0.state == .alerting }
        } catch {
            ringDetectionLog("alarms access threw: \(error.localizedDescription)")
            return nil
        }

        for kitAlarm in alertingAlarms {
            let alarmKitID = kitAlarm.id

            // Match the AlarmKit alarm to our record. Managed alarms are scheduled
            // under SystemScheduleID UUIDs (not alarmRecord.id), so primary matching
            // goes through the schedule metadata we attached at schedule time.
            let matchedAlarm = matchAppAlarm(forKitAlarmID: alarmKitID)

            #if DEBUG
            ringDetectionLog("kitAlarm \(alarmKitID.uuidString.prefix(8)) state=\(kitAlarm.state) matched=\(matchedAlarm?.id.uuidString.prefix(8) ?? "nil")")
            #endif

            guard let alarm = matchedAlarm else { continue }

            // Check if the occurrence is due (within reasonable window)
            guard let occurrence = engine.nextOccurrence(for: alarm.id, now: currentDate) else { continue }
            guard occurrence.effectiveDate <= currentDate,
                  !occurrence.isAdjusted || occurrence.effectiveDate > occurrence.baseDate else { continue }

            // Resolve the sound for this occurrence
            do {
                let (soundToUse, _) = try resolveSoundForOccurrence(alarm: alarm, occurrence: occurrence, engine: engine)
                let songName = displayNameForSound(soundToUse, alarm: alarm)
                return (songName: songName, alarm: alarm)
            } catch {
                continue // Try next alerting alarm if any
            }
        }

        return nil
    }

    /// Resolve an AlarmKit alarm ID to the app's AlarmRecord.
    /// AlarmKit echoes the UUID passed to schedule(id:configuration:) â€” for managed
    /// alarms that is SystemScheduleID, for test alarms the caller-provided UUID.
    private func matchAppAlarm(forKitAlarmID kitID: UUID) -> AlarmRecord? {
        // Direct record id (test alarms).
        if let direct = engine.alarm(id: kitID) {
            return direct
        }
        // Managed scheduled alarms: recompute the schedule UUID candidates for
        // each alarm's next occurrence and compare against the kit ID.
        for alarm in engine.alarms {
            guard alarm.isEnabled else { continue }
            guard let occurrence = engine.nextOccurrence(for: alarm.id, now: now()) else { continue }
            let label = alarm.label.isEmpty ? "Alarm" : alarm.label
            let candidateIDs = candidateScheduleIDs(for: alarm, occurrence: occurrence, label: label)
            if candidateIDs.contains(kitID) {
                return alarm
            }
        }
        return nil
    }

    /// Recompute the possible schedule UUIDs for an occurrence.
    /// Returns ONE stable ID per (alarm, occurrence, kind) — sound-independent.
    /// For backup alarms, uses a distinct kind suffix so they don't collide.
    private func candidateScheduleIDs(for alarm: AlarmRecord, occurrence: AlarmOccurrence, label: String) -> Set<UUID> {
        // Stable key: alarmID | occurrenceKey | label | loudness | kind
        // Does NOT include sound.id or selectionHash — those are handled by the
        // actual SystemScheduleID.make when scheduling, but the reconciliation
        // set must be stable so cancelling=0 on no-op toggles.
        let kind = occurrence.occurrenceKey.hasSuffix("-BACKUP") ? "backup" : "primary"
        let key = "\(occurrence.alarmID.uuidString)|\(occurrence.occurrenceKey)|\(label)|\(alarm.loudness.percentage)|\(kind)"
        let stableID = StableOccurrenceID.make(alarmID: occurrence.alarmID, occurrenceKey: key)
        return [stableID]
    }

    #if DEBUG
    @MainActor
    private func ringDetectionLog(_ message: String) {
        os_log(.debug, log: ringDetectionOSLog, "%{public}s", message)
    }
    #else
    @MainActor
    private func ringDetectionLog(_ message: String) {}
    #endif

    /// Black-box recorder: prints every AlarmKit alarm's state to the log so a
    /// device session (Console.app / sysdiagnose, subsystem com.example.alarmclock,
    /// category AlarmKitState) shows what the system ACTUALLY did — e.g. after a
    /// snooze tap: is the alarm .alerting, .countdown, .paused? Intentionally NOT
    /// gated on DEBUG: release builds must record too.
    func logAlarmKitState() {
        do {
            let alarms = try AlarmManager.shared.alarms
            if alarms.isEmpty {
                os_log(.info, log: alarmKitStateOSLog, "STATE DUMP: no AlarmKit alarms exist")
                SmartWakeDebugLog.log("STATE DUMP: no AlarmKit alarms exist")
                return
            }
            
            let total = alarms.count
            let scheduled = alarms.filter { $0.state == .scheduled }.count
            let alerting = alarms.filter { $0.state == .alerting }.count
            let countdown = alarms.filter { $0.state == .countdown }.count
            let paused = alarms.filter { $0.state == .paused }.count
            
            let summary = "STATE DUMP: total=\(total) scheduled=\(scheduled) alerting=\(alerting) countdown=\(countdown) paused=\(paused)"
            os_log(.info, log: alarmKitStateOSLog, "%{public}s", summary)
            SmartWakeDebugLog.log(summary)
            
            // Only list alerting and countdown alarm IDs with their state
            if alerting > 0 || countdown > 0 {
                for a in alarms where a.state == .alerting || a.state == .countdown {
                    let detail = "  id=\(a.id.uuidString) state=\(String(describing: a.state))"
                    os_log(.info, log: alarmKitStateOSLog, "%{public}s", detail)
                    SmartWakeDebugLog.log(detail)
                }
            }
        } catch {
            os_log(.error, log: alarmKitStateOSLog, "STATE DUMP FAILED: %{public}s", error.localizedDescription)
            SmartWakeDebugLog.log("STATE DUMP FAILED: \(error.localizedDescription)")
        }
    }
    private let alarmKitStateOSLog = OSLog(subsystem: "com.example.alarmclock", category: "AlarmKitState")

    
    /// Deprecated: Use currentlyRingingAlarm() instead
    @available(*, deprecated, message: "Use currentlyRingingAlarm() instead - single source of truth")
    func currentRingSongAndAlarm() -> (songName: String, alarm: AlarmRecord)? {
        return currentlyRingingAlarm()
    }
    
    /// Get display name for a sound
    private func displayNameForSound(_ sound: AlarmSound, alarm: AlarmRecord) -> String {
        switch sound {
        case .systemDefault:
            return "Default Alarm"
        case .builtIn(let name):
            return name
        case .imported(let id):
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                return sound.name
            }
            return "Imported Sound"
        case .random(let playlistID):
            // For random, we need to check if there's an override with a specific song
            if let occurrence = nextOccurrence,
               let override = alarm.overrides[occurrence.occurrenceKey],
               let selectedSoundID = override.randomSoundID {
                // The selectedSoundID is actually the playlist ID for precomposed
                if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == selectedSoundID }),
                   let firstSoundID = playlist.selectedSoundIDs.first,
                   let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }) {
                    return sound.name
                }
            }
            // Fallback: show playlist name
            if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }) {
                return "Random: \(playlist.name)"
            }
            return "Random Playlist"
        case .precomposedPlaylist(let playlistID, _):
            // For precomposed, get the first selected song from the playlist
            if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }),
               let firstSoundID = playlist.selectedSoundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }) {
                return sound.name
            }
            if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }) {
                return "Precomposed: \(playlist.name)"
            }
            return "Precomposed Playlist"
        }
    }

    /// Commits are serialized: a mutation arriving while another commit runs is
    /// queued and applied afterwards, never silently dropped.
    private var commitQueue: Task<Void, Never>?

    func commit(_ mutation: @escaping (inout AlarmEngine) throws -> Void, reason: String = "unknown") async {
        let previous = commitQueue
        let task = Task { @MainActor in
            await previous?.value
            await performCommit(mutation, reason: reason)
        }
        commitQueue = task
        await task.value
    }

    private func performCommit(_ mutation: (inout AlarmEngine) throws -> Void, reason: String) async {
        let perfStart = CFAbsoluteTimeGetCurrent()
        SmartWakeDebugLog.log("PERF: commit(\(reason)) start")
        var candidate = engine
        do {
            try mutation(&candidate)
            candidate.pruneExpiredOverrides(now: now())
            let (desired, soundWarnings) = await desiredSystemAlarms(from: candidate)
            if !soundWarnings.isEmpty {
                lastWarnings = soundWarnings
                os_log(.info, log: warningLog, "Sound resolution issues (alarm still saved, affected system alarms skipped): %{public}s", soundWarnings.joined(separator: " | "))
            } else {
                lastWarnings = []
            }
            // Use the engine modified by desiredSystemAlarms to persist random sound selections
            if let modifiedEngine = desiredSystemAlarmsEngine {
                candidate = modifiedEngine
            }
            
            // Exclude emergency re-ring IDs from reconciliation cancel set
            var managedIDs = engine.snapshot.managedSystemAlarmIDs
            managedIDs.formUnion(emergencyReRingIDs)
            
            candidate.snapshot.managedSystemAlarmIDs = try await scheduler.reconcile(
                desired: desired,
                managedIDs: managedIDs,
                reason: reason
            )
            // Include play history in the snapshot
            candidate.snapshot.playHistory = playHistory
            try persistence.save(candidate.snapshot)
            writeAlarmsToAppGroup(candidate.snapshot)
            engine = candidate
            lastError = nil
            publish()
            SmartWakeDebugLog.log("PERF: commit(\(reason)) done in \(Int((CFAbsoluteTimeGetCurrent() - perfStart) * 1000))ms")
        } catch {
            lastError = error.localizedDescription
            SmartWakeDebugLog.log("PERF: commit(\(reason)) FAILED in \(Int((CFAbsoluteTimeGetCurrent() - perfStart) * 1000))ms: \(error.localizedDescription)")
        }
    }

    /// Mirror alarms.json into the shared App Group so Smart Wake (and the
    /// widget/extension world) can read current alarm state. Best-effort:
    /// a missing container (no entitlements / unresolved group) just skips it.
    private func writeAlarmsToAppGroup(_ snapshot: AlarmStoreSnapshot) {
        guard let groupID = AppGroupResolver.resolve(),
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return
        }
        do {
            let url = containerURL.appendingPathComponent("alarms.json")
            let data = try JSONEncoder.alarmEncoder.encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            os_log(.error, log: warningLog, "Failed to mirror alarms.json to App Group: %{public}s", error.localizedDescription)
        }
    }

    // MARK: - Pending widget actions (Control Center buttons)

    /// Register a Darwin-notification observer so a RUNNING app applies widget
    /// actions the moment the extension posts them; otherwise they apply on the
    /// next foreground (scenePhase .active / synchronize).
    private var widgetActionObserverRegistered = false

    private func registerWidgetActionObserver() {
        guard !widgetActionObserverRegistered else { return }
        widgetActionObserverRegistered = true
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { (_, _, _, _, _) in
                // C callback: no captures. Hop back to the coordinator actor.
                Task { @MainActor in
                    await AlarmCoordinator.sharedInstance?.applyPendingWidgetActions()
                }
            },
            "com.example.alarmclock.widget.changed" as CFString,
            nil,
            .deliverImmediately
        )
    }

    /// Consume the widget's queued pending action (if any) through the full
    /// commit pipeline — the app is the sole writer of alarms.json and the only
    /// party with working AlarmKit authorization. The file is deleted BEFORE
    /// the mutation on purpose: a re-apply (skipping twice, adjusting 20 min)
    /// would silently corrupt the schedule, while a dropped action is visible
    /// in the log and the user can simply press again.
    func applyPendingWidgetActions() async {
        registerWidgetActionObserver()
        guard let groupID = AppGroupResolver.resolve(),
              let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) else {
            return
        }
        let fileURL = containerURL.appendingPathComponent(PendingWidgetAction.fileName)
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let data = try Data(contentsOf: fileURL)
            let action = try JSONDecoder.alarmDecoder.decode(PendingWidgetAction.self, from: data)
            let age = Int(now().timeIntervalSince(action.requestedAt))
            SmartWakeDebugLog.log("WIDGET ACTION APPLY: \(action.action) alarm=\(action.alarmID.uuidString.prefix(8)) requestedAt=\(action.requestedAt) age=\(age)s")
            guard engine.alarm(id: action.alarmID) != nil else {
                SmartWakeDebugLog.log("WIDGET ACTION APPLY: alarm gone, dropped")
                try FileManager.default.removeItem(at: fileURL)
                return
            }
            // Consume first: a second Control Center press just overwrites the
            // file, so the latest request must not be clobbered by our delete.
            try FileManager.default.removeItem(at: fileURL)
            switch action.action {
            case PendingWidgetAction.skip:
                await skipNext(id: action.alarmID)
            case PendingWidgetAction.adjustEarlier:
                await adjustNext(id: action.alarmID, minutes: -10)
            case PendingWidgetAction.adjustLater:
                await adjustNext(id: action.alarmID, minutes: 10)
            default:
                SmartWakeDebugLog.log("WIDGET ACTION APPLY: unknown action '\(action.action)' — dropped")
                return
            }
            SmartWakeDebugLog.log("WIDGET ACTION APPLY: handed to commit (\(action.action))")
            
            // Generate feedback message and show it
            let formatter = DateFormatter()
            formatter.setLocalizedDateFormatFromTemplate("j:mm a")
            formatter.timeZone = TimeZone.current
            let nextTime = formatter.string(from: self.nextOccurrence?.effectiveDate ?? Date())
            let actionText: String
            switch action.action {
            case PendingWidgetAction.skip:
                actionText = "Next alarm skipped"
            case PendingWidgetAction.adjustEarlier:
                actionText = "Alarm moved -10 min"
            case PendingWidgetAction.adjustLater:
                actionText = "Alarm moved +10 min"
            default:
                actionText = "Alarm adjusted"
            }
            let feedback = "\(actionText) · next \(nextTime)"
            
            // Set feedback for in-app toast (if foreground)
            self.ccActionFeedback = feedback
            
            // Clear feedback after 5 seconds
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                if self.ccActionFeedback == feedback {
                    self.ccActionFeedback = nil
                }
            }
            
            // Post local notification for background feedback
            let content = UNMutableNotificationContent()
            content.title = "Alarm Clock"
            content.body = feedback
            content.sound = nil
            let request = UNNotificationRequest(
                identifier: "CC_FEEDBACK_\(action.alarmID.uuidString)_\(Date().timeIntervalSince1970)",
                content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    SmartWakeDebugLog.log("CC FEEDBACK notification failed: \(error.localizedDescription)")
                } else {
                    SmartWakeDebugLog.log("CC FEEDBACK notification posted: \(feedback)")
                }
            }
            
            // Log alarm IDs after widget action apply
            let idsAfterWidget = engine.snapshot.alarms.map { $0.id }
            SmartWakeDebugLog.log("WIDGET ACTION APPLY: after count=\(idsAfterWidget.count) ids=\(idsAfterWidget.map { $0.uuidString.prefix(8) }.joined(separator: \", \"))")
        } catch {
            SmartWakeDebugLog.log("WIDGET ACTION APPLY FAILED: \(error.localizedDescription)")
        }
    }


    /// Per-alarm sound isolation: a failure resolving one alarm's sound becomes a
    /// warning for that alarm only; the remaining alarms still get scheduled and
    /// the commit succeeds. Returns (desired system alarms, warnings).
    private func desiredSystemAlarms(from engine: AlarmEngine) async -> ([DesiredSystemAlarm], [String]) {
        var mutableEngine = engine
        let occurrences = mutableEngine.desiredOccurrences(now: now())
        var results: [DesiredSystemAlarm] = []
        var warnings: [String] = []
        
        let smartWakeEnabled = SmartWakeService.shared.isSmartWakeEnabled
        let backupDelay = AlarmCoordinator.backupDelaySeconds
        
        // Log the scheduling horizon and number of occurrences
        SmartWakeDebugLog.log("DESIRED ALARMS: scheduling horizon=\(occurrences.count) occurrences, smartWakeEnabled=\(smartWakeEnabled)")
        
        for occurrence in occurrences {
            guard let alarm = mutableEngine.alarm(id: occurrence.alarmID) else { continue }
            let label = alarm.label.isEmpty ? "Alarm" : alarm.label
            do {
                // For random mode, select a song for this occurrence if not already selected
                let (soundToUse, override) = try resolveSoundForOccurrence(alarm: alarm, occurrence: occurrence, engine: mutableEngine)
                // Apply the override if there is one
                if let newOverride = override {
                    if var updatedAlarm = mutableEngine.alarm(id: alarm.id) {
                        updatedAlarm.overrides[occurrence.occurrenceKey] = newOverride
                        try mutableEngine.upsert(updatedAlarm, now: now())
                    }
                }
                let alarmKitSound = try await alarmKitSound(for: soundToUse, loudness: alarm.loudness)
                
                // Primary alarm at the effective date
                // For playlist alarms with Smart Wake enabled, we SKIP the primary alarm at wake time
                // and only schedule the backup alarm (which fires at wakeTime + 30s)
                let shouldSchedulePrimaryAtWake = !(smartWakeEnabled && SmartWakeService.isPlaylistSound(soundToUse))
                
                if shouldSchedulePrimaryAtWake {
                    let primaryItem = DesiredSystemAlarm(
                        id: SystemScheduleID.make(
                            for: occurrence,
                            label: label,
                            sound: soundToUse,
                            loudness: alarm.loudness,
                            selectionHash: desiredSelectionHash(for: soundToUse)
                        ),
                        occurrence: occurrence,
                        label: label,
                        sound: soundToUse,
                        alarmKitSound: alarmKitSound,
                        snoozeDurationMinutes: alarm.snoozeDurationMinutes
                    )
                    results.append(primaryItem)
                    SmartWakeDebugLog.log("DESIRED ITEM: occurrenceKey=\(occurrence.occurrenceKey) kind=PRIMARY effectiveDate=\(occurrence.effectiveDate) label=\"\(label)\"")
                }
                
                // Phase 7a: Schedule delayed backup for playlist alarms when Smart Wake is enabled
                // Backup fires at occurrence.effectiveDate + backupDelaySeconds with short floor sound
                if smartWakeEnabled && SmartWakeService.isPlaylistSound(soundToUse) {
                    let backupOccurrenceKey = "\(occurrence.occurrenceKey)-BACKUP"
                    let backupDate = occurrence.effectiveDate.addingTimeInterval(TimeInterval(AlarmCoordinator.backupDelaySeconds))
                    let backupOccurrence = AlarmOccurrence(
                        alarmID: occurrence.alarmID,
                        occurrenceKey: backupOccurrenceKey,
                        baseDate: occurrence.baseDate,
                        effectiveDate: backupDate,
                        isAdjusted: false
                    )
                    
                    // Extract playlistID from soundToUse for backup precompose
                    let playlistID: UUID
                    if case .precomposedPlaylist(let pid, _) = soundToUse {
                        playlistID = pid
                    } else if case .random(let pid) = soundToUse {
                        playlistID = pid
                    } else {
                        // Should not reach here since we checked isPlaylistSound
                        fatalError("Expected playlist sound for backup")
                    }
                    
                    // Create short floor sound for backup (cap at 60s total duration)
                    let backupPrecomposedTuple = try await AudioProcessingService.shared.precomposePlaylist(
                        playlistID: playlistID,
                        loudness: alarm.loudness,
                        songCount: 5,
                        maxDuration: 60  // Cap total duration at 60s for backup
                    )
                    let backupPrecomposedURL = backupPrecomposedTuple.0
                    
                    // Record diagnostics
                    playlistDiagnostics.addPreparation(backupPrecomposedTuple.1)
                    playlistDiagnostics.addGeneratedFile(backupPrecomposedTuple.2)
                    
                    // Copy to Library/Sounds for AlarmKit access
                    let processedFileName = backupPrecomposedURL.lastPathComponent
                    let soundsDir = SoundLibrary.shared.soundsDirectory!
                    let alarmKitURL = soundsDir.appendingPathComponent(processedFileName)
                    
                    if !FileManager.default.fileExists(atPath: alarmKitURL.path) {
                        // File copy off the main actor — a multi-MB WAV copy
                        // stalls every UI interaction on the save path.
                        try await Task.detached(priority: .utility) {
                            try FileManager.default.copyItem(at: backupPrecomposedURL, to: alarmKitURL)
                        }.value
                    }
                    
                    let backupAlarmKitSound: AlertConfiguration.AlertSound = .named(processedFileName)
                    
                    let backupItem = DesiredSystemAlarm(
                        id: SystemScheduleID.make(
                            for: backupOccurrence,
                            label: label,
                            sound: soundToUse,
                            loudness: alarm.loudness,
                            selectionHash: desiredSelectionHash(for: soundToUse)
                        ),
                        occurrence: backupOccurrence,
                        label: label,
                        sound: soundToUse,
                        alarmKitSound: backupAlarmKitSound,
                        snoozeDurationMinutes: alarm.snoozeDurationMinutes
                    )
                    results.append(backupItem)
                    SmartWakeDebugLog.log("DESIRED ITEM: occurrenceKey=\(backupOccurrence.occurrenceKey) kind=BACKUP effectiveDate=\(backupOccurrence.effectiveDate) label=\"\(label)\"")
                }
            } catch {
                warnings.append("\(label): \(error.localizedDescription)")
            }
        }
        // Store the modified engine for persistence
        desiredSystemAlarmsEngine = mutableEngine
        
        // Final summary log
        let primaryCount = results.filter { $0.occurrence.occurrenceKey.hasSuffix("-BACKUP") == false }.count
        let backupCount = results.filter { $0.occurrence.occurrenceKey.hasSuffix("-BACKUP") }.count
        SmartWakeDebugLog.log("DESIRED ALARMS SUMMARY: total=\(results.count) primary=\(primaryCount) backup=\(backupCount) userAlarms=\(occurrences.count)")
        
        return (results, warnings)
    }
    
    /// Add an emergency re-ring ID so it's excluded from reconciliation cancellation
    func addEmergencyReRingID(_ id: UUID) {
        emergencyReRingIDs.insert(id)
    }
    
    /// Clear all emergency re-ring IDs (e.g., after they've fired)
    func clearEmergencyReRingIDs() {
        emergencyReRingIDs.removeAll()
    }

    /// Stable per-selection hash so schedule identity changes when the chosen
    /// song set changes â€” reconcile then reschedules with the fresh precomposed file.
    private func desiredSelectionHash(for sound: AlarmSound) -> String? {
        if case .precomposedPlaylist(let playlistID, _) = sound,
           let playlist = try? SoundLibrary.shared.playlist(for: playlistID) {
            let key = playlist.selectedSoundIDs.map { $0.uuidString }.sorted().joined(separator: "-")
            return SoundSelectionHash.make(from: key)
        }
        return nil
    }

    /// Resolve the sound for a specific occurrence, handling random mode
    /// Returns the sound to use and the updated override (if any)
    private func resolveSoundForOccurrence(alarm: AlarmRecord, occurrence: AlarmOccurrence, engine: AlarmEngine) throws -> (AlarmSound, AlarmOccurrenceOverride?) {
        switch alarm.sound {
        case .random(let playlistID):
            // Check if we already have a precomposed playlist for this occurrence
            if let override = alarm.overrides[occurrence.occurrenceKey],
               let selectedSoundID = override.randomSoundID {
                // Verify the sound still exists in the playlist
                if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
                   playlist.soundIDs.contains(selectedSoundID) {
                    // Check if precomposed playlist exists for this loudness
                    let precomposedSound = AlarmSound.precomposedPlaylist(playlistID, alarm.loudness)
                    return (precomposedSound, nil)
                }
            }

            // Need to select a new random song (but we'll use precomposed playlist)
            // Avoid immediately repeating the previous precomposed playlist if multiple available
            var previousPlaylistID: UUID?
            // Find the previous occurrence's selected playlist
            let earlierOccurrences = engine.desiredOccurrences(now: now().addingTimeInterval(-86400 * 7))
                .filter { $0.alarmID == alarm.id && $0.effectiveDate < occurrence.effectiveDate }
                .sorted { $0.effectiveDate > $1.effectiveDate }
            if let prevOccurrence = earlierOccurrences.first,
               let prevOverride = alarm.overrides[prevOccurrence.occurrenceKey],
               let prevSoundID = prevOverride.randomSoundID {
                // The previousSoundID was a playlist ID for precomposed
                previousPlaylistID = prevSoundID
            }

            // For precomposed, we just need the playlist ID
            // The actual song selection happens during precomposition
            let playlist = try SoundLibrary.shared.playlist(for: playlistID)
            let availableSounds = playlist.soundIDs
            
            // Store the playlist ID in the override for this occurrence
            var newOverride = alarm.overrides[occurrence.occurrenceKey] ?? .none
            newOverride.randomSoundID = playlistID  // Store playlist ID for precomposed

            // Return precomposed playlist sound with the alarm's loudness
            let precomposedSound = AlarmSound.precomposedPlaylist(playlistID, alarm.loudness)
            return (precomposedSound, newOverride)

        default:
            return (alarm.sound, nil)
        }
    }

    func alarmKitSound(for sound: AlarmSound, loudness: AlarmLoudness = .hundred) async throws -> AlertConfiguration.AlertSound {
        switch sound {
        case .systemDefault:
            return .default
        case .builtIn(let name):
            guard let fileName = AlarmSound.builtIn(name).systemFileName else {
                throw SoundLibraryError.builtInSoundMissing(name)
            }
            guard SoundPreviewService.bundledSoundURL(for: fileName) != nil else {
                throw SoundLibraryError.builtInSoundMissing(fileName)
            }
            return .named(fileName)
        case .imported(let id):
            let fileName = try SoundLibrary.shared.alarmKitFileName(for: id)
            
            // If loudness is not 100%, use the processed sound file
            if loudness != .hundred {
                // Get the original sound info
                let originalSound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id })
                if let originalSound {
                    // Get or create the processed sound
                    let processedURL = try await AudioProcessingService.shared.getOrCreateProcessedSound(
                        for: originalSound,
                        loudness: loudness
                    )
                    // The processed file is a WAV in Library/ProcessedSounds
                    // Copy it to Library/Sounds for AlarmKit access
                    let processedFileName = processedURL.lastPathComponent
                    let soundsDir = SoundLibrary.shared.soundsDirectory!
                    let alarmKitURL = soundsDir.appendingPathComponent(processedFileName)
                    
                    if !FileManager.default.fileExists(atPath: alarmKitURL.path) {
                        try FileManager.default.copyItem(at: processedURL, to: alarmKitURL)
                    }
                    return .named(processedFileName)
                }
            }
            return .named(fileName)
        case .random:
            // Random sound should have been resolved to precomposedPlaylist by the caller,
            // but if we get here, fall back to first song in playlist or built-in
            if let coordinator = AlarmCoordinator.sharedInstance,
               let alarm = coordinator.alarms.first,
               case .random(let playlistID) = alarm.sound,
               let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
               let firstSoundID = playlist.selectedSoundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let fileName = try? SoundLibrary.shared.alarmKitFileName(for: firstSoundID) {
                return .named(fileName)
            }
            // Ultimate fallback: built-in sound
            return .named("classic-bell.wav")
        case .precomposedPlaylist(let playlistID, let loudness):
            // Generate or get the precomposed playlist file
            let (precomposedURL, preparationEntry, generatedFileEntry) = try await AudioProcessingService.shared.precomposePlaylist(
                playlistID: playlistID,
                loudness: loudness,
                songCount: 5
            )
            
            // Record diagnostics
            playlistDiagnostics.addPreparation(preparationEntry)
            playlistDiagnostics.addGeneratedFile(generatedFileEntry)
            
            // Copy to Library/Sounds for AlarmKit access
            let processedFileName = precomposedURL.lastPathComponent
            let soundsDir = SoundLibrary.shared.soundsDirectory!
            let alarmKitURL = soundsDir.appendingPathComponent(processedFileName)
            
            let fileExistedAtScheduling = FileManager.default.fileExists(atPath: alarmKitURL.path)
            
            if !fileExistedAtScheduling {
                try FileManager.default.copyItem(at: precomposedURL, to: alarmKitURL)
            }
            
            // Record scheduling diagnostics
            let schedulingEntry = PlaylistDiagnostics.SchedulingEntry(
                timestamp: Date(),
                alarmID: UUID(), // Will be filled by caller
                occurrenceKey: "", // Will be filled by caller
                scheduledDate: Date(),
                soundConfiguration: "Precomposed playlist (\(precomposedURL.lastPathComponent))",
                usedPrecomposedFile: true,
                fileName: precomposedURL.lastPathComponent,
                fileExistedAtScheduling: fileExistedAtScheduling,
                alarmKitAccepted: false, // Will be updated after scheduling
                error: nil,
                fallbackToSingleSong: false,
                fallbackReason: nil
            )
            
            // Store for later update after scheduling
            // For now, we'll just return the sound
            return .named(processedFileName)
        }
    }

    private func publish() {
        let currentDate = now()
        alarms = engine.alarmsOrderedByNextOccurrence(now: currentDate)
        let earliest = engine.earliestOccurrence(now: currentDate)
        nextOccurrence = earliest
        
        // Compute next alarm snapshot for widgets and Lock Screen controls
        if let earliest = earliest {
            if let alarm = engine.alarm(id: earliest.alarmID) {
                nextAlarmSnapshot = NextAlarmSnapshot(alarm: alarm, occurrence: earliest)
            }
        } else {
            nextAlarmSnapshot = nil
        }
        
        // Write to App Group for widget extension
        writeNextAlarmSnapshotToAppGroup()
        
        // Update Live Activity
        updateLiveActivity()
    }
    
    /// Update or start the Live Activity for Dynamic Island
    private func updateLiveActivity() {
        // Respect the liveActivityEnabled toggle
        guard Self.liveActivityEnabled else {
            // If disabled, ensure any existing activity is ended
            endLiveActivity()
            return
        }
        
        guard let snapshot = nextAlarmSnapshot else {
            // No upcoming alarm - end any existing activity
            endLiveActivity()
            return
        }
        
        // Use the alarm's configured adjustment step minutes
        let alarmRecord = engine.alarm(id: snapshot.alarmID)
        let adjustmentStepMinutes = alarmRecord?.adjustmentStepMinutes ?? 10
        
        let contentState = NextAlarmAttributes.ContentState(
            alarmID: snapshot.alarmID,
            label: snapshot.label,
            nextOccurrenceDate: snapshot.nextOccurrenceDate,
            adjustmentStepMinutes: adjustmentStepMinutes,
            isAdjusted: snapshot.isAdjusted,
            adjustmentDescription: snapshot.adjustmentDescription,
            isSkipped: snapshot.isSkipped,
            isEnabled: snapshot.isEnabled,
            sound: snapshot.sound,
            loudness: snapshot.loudness,
            repeatRule: snapshot.repeatRule
        )
        
        let attributes = NextAlarmAttributes(alarmID: snapshot.alarmID)
        
        Task {
            do {
                if let activity = liveActivity {
                    // Update existing activity
                    await activity.update(using: contentState)
                } else {
                    // Start new activity
                    let activity = try Activity.request(
                        attributes: attributes,
                        content: .init(state: contentState, staleDate: nil),
                        pushType: nil
                    )
                    await MainActor.run {
                        self.liveActivity = activity
                    }
                }
            } catch {
                print("Failed to update Live Activity: \(error)")
            }
        }
    }
    
    /// End the Live Activity
    private func endLiveActivity() {
        Task {
            for activity in Activity<NextAlarmAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run {
                self.liveActivity = nil
            }
        }
    }
    
    /// End all existing Live Activities on launch if disabled
    private func endAllLiveActivitiesOnLaunch() {
        guard !Self.liveActivityEnabled else { return }
        Task {
            for activity in Activity<NextAlarmAttributes>.activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
    
    /// Temporarily show the snoozed ring time in the widget snapshot.
    /// The regular snapshot is restored by publish() on the next reconcile.
    func publishSnoozeWidgetSnapshot(alarm: AlarmRecord, fireDate: Date, occurrenceKey: String) {
        let occurrence = AlarmOccurrence(
            alarmID: alarm.id,
            occurrenceKey: occurrenceKey,
            baseDate: fireDate,
            effectiveDate: fireDate,
            isAdjusted: false
        )
        nextAlarmSnapshot = NextAlarmSnapshot(alarm: alarm, occurrence: occurrence)
        writeNextAlarmSnapshotToAppGroup()
        SmartWakeDebugLog.log("SNOOZE: widget snapshot updated to snoozed ring time \(fireDate)")
    }

    /// Re-publish the regular next-alarm snapshot (e.g. after a snooze re-ring ends).
    func publishSnapshot() {
        publish()
    }

    private func writeNextAlarmSnapshotToAppGroup() {
        let timestamp = Date()
        
        guard let configuredAppGroup = Bundle.main.object(
            forInfoDictionaryKey: "AlarmClockAppGroupIdentifier"
        ) as? String else {
            WidgetDiagnostics.appLogEvent("Missing configured App Group identifier in Info.plist", appGroupIdentifier: nil, containerAvailable: false)
            lastSnapshotWriteResult = (false, "Missing configured App Group identifier", timestamp)
            return
        }
        let resignedAppGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let appGroupIdentifier = resignedAppGroups.first {
            $0 == configuredAppGroup || $0.hasPrefix(configuredAppGroup + ".")
        } ?? configuredAppGroup

        WidgetDiagnostics.appLogEvent("Resolved App Group identifier", appGroupIdentifier: appGroupIdentifier)
        
        guard let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            WidgetDiagnostics.appLogEvent("Failed to get App Group container URL", appGroupIdentifier: appGroupIdentifier, containerAvailable: false)
            lastSnapshotWriteResult = (false, "Failed to get App Group container URL", timestamp)
            return
        }
        
        WidgetDiagnostics.appLogEvent("App Group container available", appGroupIdentifier: appGroupIdentifier, containerAvailable: true)
        
        let snapshotURL = appGroupURL.appendingPathComponent("nextAlarmSnapshot.json")
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        
        do {
            let data = try encoder.encode(nextAlarmSnapshot)
            try data.write(to: snapshotURL, options: .atomic)
            
            // Verify write
            let fileAttributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
            let fileSize = (fileAttributes[.size] as? Int) ?? 0
            let fileModDate = (fileAttributes[.modificationDate] as? Date) ?? timestamp
            
            WidgetDiagnostics.appLogEvent("Snapshot written successfully", 
                appGroupIdentifier: appGroupIdentifier, 
                containerAvailable: true,
                fileExists: true,
                fileSize: fileSize,
                fileModificationDate: fileModDate,
                writeSuccess: true,
                snapshotAlarmID: nextAlarmSnapshot?.alarmID,
                snapshotLabel: nextAlarmSnapshot?.label,
                snapshotNextOccurrence: nextAlarmSnapshot?.nextOccurrenceDate,
                snapshotIsEnabled: nextAlarmSnapshot?.isEnabled)
            
            var reloadRequested = false
            if let widgetKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: widgetKind)
                reloadRequested = true
            }
            if let controlKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockControlKind") as? String {
                WidgetCenter.shared.reloadTimelines(ofKind: controlKind)
                reloadRequested = true
            }
            
            lastSnapshotWriteResult = (true, nil, timestamp)
            lastWidgetReloadRequest = timestamp
            
            WidgetDiagnostics.appLogEvent("WidgetCenter reload requested", 
                appGroupIdentifier: appGroupIdentifier,
                widgetReloadRequested: reloadRequested)
            
        } catch {
            WidgetDiagnostics.appLogEvent("Failed to write snapshot", 
                appGroupIdentifier: appGroupIdentifier,
                containerAvailable: true,
                fileExists: false,
                writeSuccess: false,
                writeError: error.localizedDescription)
            
            lastSnapshotWriteResult = (false, error.localizedDescription, timestamp)
        }
    }

    /// Schedule a test alarm using the actual alarm configuration
    /// Uses a separate temporary AlarmKit alarm ID so it doesn't interfere with real alarms
    func scheduleTestAlarm(_ alarm: AlarmRecord, delay: TimeInterval) async {
        #if DIAGNOSTIC_BUILD
        lastError = "Alarm scheduling is disabled in AlarmClock Diagnostic."
        return
        #endif

        let testDate = now().addingTimeInterval(delay)
        let testID = UUID() // Separate temporary ID for test alarm

        // Resolve the sound for the test (handles random mode)
        let soundToUse: AlarmSound
        var displaySound = "Default"
        var displayLoudness = alarm.loudness

        do {
            switch alarm.sound {
            case .systemDefault:
                displaySound = "System Default"
                soundToUse = .systemDefault
            case .builtIn(let name):
                displaySound = name
                soundToUse = .builtIn(name)
            case .imported(let id):
                if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                    displaySound = sound.name
                }
                soundToUse = .imported(id)
            case .random(let playlistID):
                if let playlist = SoundLibrary.shared.playlists.first(where: { $0.id == playlistID }),
                   !playlist.soundIDs.isEmpty {
                    // Use precomposed playlist for test alarm too
                    soundToUse = .precomposedPlaylist(playlistID, alarm.loudness)
                    if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == playlist.soundIDs.first! }) {
                        displaySound = "\(sound.name) (from \(playlist.name) â€” precomposed)"
                    }
                } else {
                    soundToUse = .systemDefault
                }
            case .precomposedPlaylist:
                soundToUse = alarm.sound
            }

            let alarmKitSound = try await alarmKitSound(for: soundToUse, loudness: alarm.loudness)

            // Create the test alarm configuration
            let snoozeInterval = TimeInterval((alarm.snoozeDurationMinutes ?? 10) * 60)
            let snoozeMinutes = alarm.snoozeDurationMinutes ?? 10
            let alert = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: "[TEST] \(alarm.label.isEmpty ? "Test Alarm" : alarm.label)"),
                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill"),
                secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
                secondaryButtonBehavior: .countdown
            )
            let attributes = AlarmAttributes(
                presentation: AlarmPresentation(
                    alert: alert,
                    countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min")),
                    paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min"), resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.circle.fill"))
                ),
                metadata: ScheduledOccurrenceMetadata(
                    alarmID: alarm.id,
                    occurrenceKey: "TEST-\(Int64(testDate.timeIntervalSince1970))",
                    baseDate: testDate
                ),
                tintColor: .orange
            )

            let configuration = AlarmManager.AlarmConfiguration<ScheduledOccurrenceMetadata>(
                countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snoozeInterval),
                schedule: .fixed(testDate),
                attributes: attributes,
                stopIntent: nil,
                secondaryIntent: nil,
                sound: alarmKitSound
            )

            _ = try await (scheduler as? AlarmKitSchedulingService)?.manager.schedule(id: testID, configuration: configuration)

        } catch {
            lastError = "Test alarm failed: \(error.localizedDescription)"
        }
    }

    /// Cancel a pending test alarm
    func cancelTestAlarm(testID: UUID) async {
        try? (scheduler as? AlarmKitSchedulingService)?.manager.cancel(id: testID)
    }

    /// Record a song that finished playing during an alarm ring
    /// Call this when a song completes playback (not when skipped/cut off)
    func recordPlayHistory(songName: String, alarmID: UUID, alarmLabel: String, soundID: UUID? = nil) {
        let entry = PlayHistoryEntry(
            songName: songName,
            alarmLabel: alarmLabel,
            alarmID: alarmID,
            timestamp: now(),
            soundID: soundID
        )
        playHistory.insert(entry, at: 0) // Newest first
        
        // Prune to max entries
        if playHistory.count > maxHistoryEntries {
            playHistory = Array(playHistory.prefix(maxHistoryEntries))
        }
        
        // Persist immediately
        Task {
            await saveHistory()
        }
    }

    /// Save play history to persistence
    private func saveHistory() async {
        var candidate = engine
        candidate.snapshot.playHistory = playHistory
        try? persistence.save(candidate.snapshot)
    }

    /// Delete a history entry, optionally also deleting the associated sound file
    func deleteHistoryEntry(id: UUID, deleteSoundFile: Bool = false) {
        if let entry = playHistory.first(where: { $0.id == id }) {
            if deleteSoundFile, let soundID = entry.soundID {
                // Check if any alarm/playlist still references this sound
                if !isSoundReferenced(soundID: soundID) {
                    SoundLibrary.shared.deleteSoundFileByID(soundID)
                } else {
                    // Sound is still referenced - could log a warning or set an error
                    lastError = "Cannot delete song file: still referenced by an alarm or playlist"
                    return
                }
            }
        }
        playHistory.removeAll { $0.id == id }
        Task {
            await saveHistory()
        }
    }
    
    /// Clear all play history entries
    func clearAllHistory(deleteSoundFiles: Bool = false) {
        if deleteSoundFiles {
            // Delete sound files for entries that have soundIDs and aren't referenced
            for entry in playHistory {
                if let soundID = entry.soundID, !isSoundReferenced(soundID: soundID) {
                    SoundLibrary.shared.deleteSoundFileByID(soundID)
                }
            }
        }
        playHistory.removeAll()
        Task {
            await saveHistory()
        }
    }
    
    /// Check if a sound ID is still referenced by any alarm or playlist
    private func isSoundReferenced(soundID: UUID) -> Bool {
        // Check alarms
        for alarm in alarms {
            if case .imported(let id) = alarm.sound, id == soundID {
                return true
            }
            if case .random(let pid) = alarm.sound {
                let playlist = try? SoundLibrary.shared.playlist(for: pid)
                if playlist?.soundIDs.contains(soundID) == true {
                    return true
                }
            }
            if case .precomposedPlaylist(let pid, _) = alarm.sound {
                let playlist = try? SoundLibrary.shared.playlist(for: pid)
                if playlist?.soundIDs.contains(soundID) == true {
                    return true
                }
            }
        }
        // Check all playlists
        for playlist in SoundLibrary.shared.playlists {
            if playlist.soundIDs.contains(soundID) {
                return true
            }
        }
        return false
    }

    /// Toggle playback of a history entry: press plays, press again stops.
    func playHistoryEntry(_ entry: PlayHistoryEntry) {
        if SoundPreviewService.shared.playingSoundID == historySoundID(for: entry) {
            SoundPreviewService.shared.stop()
            return
        }
        stopHistoryPlayback()
        // Find the sound in the library
        let soundName = entry.songName
        var soundURL: URL?
        var soundID: String?
        
        // Check imported sounds
        if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.name == soundName }) {
            soundURL = sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
            soundID = sound.fileName
        }
        
        // If not found in imported, check built-in sounds
        if soundURL == nil, let url = SoundPreviewService.bundledSoundURL(for: soundName) {
            soundURL = url
            soundID = soundName
        }
        
        // If still not found, try to find by file name (imported sounds use fileName)
        if soundURL == nil {
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.fileName.hasPrefix(soundName) || $0.name == soundName }) {
                soundURL = sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
                soundID = sound.fileName
            }
        }
        
        guard let url = soundURL, let id = soundID else {
            lastError = "Could not find sound file for: \(soundName)"
            return
        }

        SoundPreviewService.shared.play(url: url, id: historySoundID(for: entry))
    }

    /// Stable ID identifying the sound used for a history entry playback.
    private func historySoundID(for entry: PlayHistoryEntry) -> String {
        "history-\(entry.id.uuidString)"
    }

    /// Stop any history/preview playback started from Play History.
    func stopHistoryPlayback() {
        SoundPreviewService.shared.stop()
    }
}
