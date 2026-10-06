import re

with open(r'D:\myiosAlarm\AlarmClock\AlarmPlaybackService.swift', 'r', encoding='utf-8') as f:
    content = f.read()

new_func = '''    /// Handle SNOOZE command from lock screen (next track)
    private func handleSnoozeCommand() {
        // Snapshot backup ID locally BEFORE async cancel \u2014 prevents double-cancel on duplicate deliveries
        let backupID = pendingBackupAlarmID
        pendingBackupAlarmID = nil
        
        // 1-second dedupe gate
        let now = Date()
        if let last = lastSnoozeCommandTime, now.timeIntervalSince(last) < 1.0 {
            SmartWakeDebugLog.log("SNOOZE DUP ignored (within 1s)")
            return
        }
        lastSnoozeCommandTime = now
        
        // Snapshot alarm/occurrence/coordinator BEFORE stop() clears them
        guard let alarm = currentAlarm,
              let occurrence = currentOccurrence,
              let coordinator = AlarmCoordinator.sharedInstance else {
            SmartWakeDebugLog.log("SNOOZE: missing alarm/occurrence/coordinator")
            return
        }
        
        let snoozeMinutes = alarm.snoozeDurationMinutes ?? 10
        let snoozeFireDate = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        let snoozeDelayedBackupDate = snoozeFireDate.addingTimeInterval(TimeInterval(AlarmCoordinator.backupDelaySeconds))

        // Snapshot playlist info for immediate playlist start at true snooze time
        var playlistID: UUID? = nil
        if case .random(let pid) = alarm.sound { playlistID = pid }
        if case .precomposedPlaylist(let pid, _) = alarm.sound { playlistID = pid }
        
        // Cancel pending backup alarm
        if let id = backupID {
            Task {
                try? await AlarmManager.shared.cancel(id: id)
                SmartWakeDebugLog.log("SNOOZE: cancelled pending backup alarm \\(id.uuidString)")
            }
        }
        
        // Stop playback
        stop(reason: "remote-snooze")
        
        // Schedule delayed-backup AlarmKit alarm with floor sound (fires 30s after true snooze time)
        // This mirrors the wake-path architecture: playlist starts at true time, backup is safety net
        Task { @MainActor in
            do {
                // Get the floor sound for this alarm
                let floorSound = try await coordinator.alarmKitSound(for: alarm.sound, loudness: alarm.loudness)
                
                let snoozeID = UUID()
                let snoozeDurationSeconds = TimeInterval(snoozeMinutes * 60)
                let snoozeConfig = AlarmManager.AlarmConfiguration<ScheduledOccurrenceMetadata>(
                    countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: snoozeDurationSeconds),
                    schedule: .fixed(snoozeDelayedBackupDate),  // DELAYED: fires at snoozeTime + 30s (backup)
                    attributes: AlarmAttributes(
                        presentation: AlarmPresentation(
                            alert: AlarmPresentation.Alert(
                                title: LocalizedStringResource(stringLiteral: alarm.label.isEmpty ? "Alarm" : alarm.label),
                                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill"),
                                secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
                                secondaryButtonBehavior: .countdown
                            ),
                            countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: "Snoozed \\(snoozeMinutes) min")),
                            paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: "Snoozed \\(snoozeMinutes) min"), resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.circle.fill"))
                        ),
                        metadata: ScheduledOccurrenceMetadata(
                            alarmID: alarm.id,
                            occurrenceKey: "SNOOZE-\\(occurrence.occurrenceKey)",
                            baseDate: snoozeDelayedBackupDate  // baseDate matches delayed fire time
                        ),
                        tintColor: .orange
                    ),
                    stopIntent: nil,
                    secondaryIntent: nil,
                    sound: floorSound
                )
                _ = try await AlarmManager.shared.schedule(id: snoozeID, configuration: snoozeConfig)
                
                // Register with coordinator for reconcile exclusion
                coordinator.addEmergencyReRingID(snoozeID)
                pendingSnoozeAlarmID = snoozeID
                
                SmartWakeDebugLog.log("SNOOZE: scheduled DELAYED backup alarm id=\\(snoozeID.uuidString) at \\(snoozeDelayedBackupDate) (true snooze: \\(snoozeFireDate)) for \\(snoozeMinutes) min")
                
                // Playlist takeover context: if the silent loop keeps us alive,
                // SmartWakeService replaces the floor-sound ring with the playlist.
                if let pid = playlistID {
                    AlarmPlaybackService.shared.snoozeTakeoverContext =
                        (alarm: alarm, playlistID: pid, occurrenceKey: "SNOOZE-\\(occurrence.occurrenceKey)")
                }
                
                // Start playlist IMMEDIATELY at true snooze time (playlist-first, like wake path)
                // We schedule a local task to fire at the true snooze time
                let delay = snoozeFireDate.timeIntervalSinceNow
                if delay > 0, let pid = playlistID {
                    Task { @MainActor in
                        try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        // Start playlist at true snooze time
                        let occ = AlarmOccurrence(
                            alarmID: alarm.id,
                            occurrenceKey: "SNOOZE-\\(occurrence.occurrenceKey)",
                            baseDate: snoozeFireDate,
                            effectiveDate: snoozeFireDate,
                            isAdjusted: false
                        )
                        AlarmPlaybackService.shared.start(
                            playlistID: pid,
                            loudness: alarm.loudness,
                            alarm: alarm,
                            occurrence: occ
                        )
                        SmartWakeDebugLog.log("SNOOZE-PLAYLIST: started playlist at true snooze time \\(snoozeFireDate)")
                        
                        // Wait for playback to confirm, then cancel delayed backup
                        var playbackConfirmed = false
                        for _ in 0..<10 {
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            if AlarmPlaybackService.shared.isPlaying {
                                playbackConfirmed = true
                                break
                            }
                        }
                        if playbackConfirmed {
                            do {
                                try await AlarmManager.shared.cancel(id: snoozeID)
                                SmartWakeDebugLog.log("SNOOZE-PLAYLIST: cancelled delayed backup alarm \\(snoozeID.uuidString)")
                            } catch {
                                SmartWakeDebugLog.log("SNOOZE-PLAYLIST: cancel delayed backup FAILED: \\(error.localizedDescription)")
                            }
                            AlarmPlaybackService.shared.consumeSnoozeForTakeover()
                            SmartWakeService.shared.stopSilentPlayerOnly(reason: "snooze playlist takeover completed")
                        } else {
                            SmartWakeDebugLog.log("SNOOZE-PLAYLIST: playback did not confirm; delayed backup left as fallback")
                        }
                    }
                } else {
                    SmartWakeDebugLog.log("SNOOZE: delay <= 0 or no playlist, skipping playlist start (snooze time in past)")
                }
                
                // Keep the app alive during the snooze window so the snooze
                // re-ring can be taken over with the playlist (Task 9e-6).
                Task { @MainActor in
                    await SmartWakeService.shared.startIfReadyForeground()
                    SmartWakeDebugLog.log("SNOOZE: loop after restart running=\\(SmartWakeService.shared.isRunning)")
                }
                
                // Post local notification for snooze feedback
                let content = UNMutableNotificationContent()
                content.title = "Snoozed \\(snoozeMinutes) min"
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("j:mm a")
                formatter.timeZone = TimeZone.current
                content.body = "Next ring \\(formatter.string(from: snoozeFireDate))"
                content.sound = nil // Silent notification
                
                let request = UNNotificationRequest(
                    identifier: "SNOOZE-\\(snoozeID.uuidString)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                )
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        SmartWakeDebugLog.log("SNOOZE notification failed: \\(error.localizedDescription)")
                    }
                }
                
                // Update the widget snapshot so the lock-screen widget shows the
                // snoozed ring time instead of the regular next alarm.
                coordinator.publishSnoozeWidgetSnapshot(
                    alarm: alarm,
                    fireDate: snoozeFireDate,
                    occurrenceKey: "SNOOZE-\\(occurrence.occurrenceKey)"
                )
            } catch {
                let nsError = error as NSError
                SmartWakeDebugLog.log("SNOOZE: scheduling FAILED: \\(error.localizedDescription) (domain=\\(nsError.domain) code=\\(nsError.code))")
            }
        }
    }'''

# Find the start
start_marker = '/// Handle SNOOZE command from lock screen (next track)'
start_idx = content.find(start_marker)
if start_idx == -1:
    print("Start marker not found")
    exit(1)

# Find the end - look for the next function definition at same indentation
lines = content[start_idx:].split('\n')
brace_count = 0
end_line = 0
in_function = False

for i, line in enumerate(lines):
    if 'private func handleSnoozeCommand()' in line:
        in_function = True
    if in_function:
        brace_count += line.count('{')
        brace_count -= line.count('}')
        if brace_count == 0 and i > 0:
            end_line = i
            break

end_idx = start_idx + len('\n'.join(lines[:end_line+1]))

# Replace
new_content = content[:start_idx] + new_func + content[end_idx:]

with open(r'D:\myiosAlarm\AlarmClock\AlarmPlaybackService.swift', 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Replacement done!")