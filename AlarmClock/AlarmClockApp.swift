import SwiftUI
import AppIntents
import AlarmKit
import AlarmClockShared
import UserNotifications

@main
struct AlarmClockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Register the Live Activity alarm service for the main app
        // App @main entry points already run on the main thread
        MainActor.assumeIsolated {
            LiveActivityAlarmServiceProvider.shared = SharedAlarmService()
        }
        
        // Request notification authorization for Stop/Snooze actions on lock screen
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                SmartWakeDebugLog.log("NOTIFICATION auth error: \(error.localizedDescription)")
            }
            SmartWakeDebugLog.log("NOTIFICATION authorization (app launch): \(granted ? "granted" : "denied")")
        }

        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let stamp = info?["AlarmClockBuildStamp"] as? String ?? "unknown"
        SmartWakeDebugLog.log("BUILD: v\(v) (\(b)) commit=\(stamp)")
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

/// App delegate to handle notification actions
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let alarmIDString = userInfo["alarmID"] as? String ?? ""
        let occurrenceKey = userInfo["occurrenceKey"] as? String ?? ""
        
        if let alarmID = UUID(uuidString: alarmIDString) {
            if actionId == "STOP_ALARM" || actionId == UNNotificationDismissActionIdentifier {
                // Stop action or notification dismissed
                SmartWakeDebugLog.log("NOTIFICATION action: STOP alarmID=\(alarmIDString) occurrenceKey=\(occurrenceKey)")
                Task { @MainActor in
                    AlarmPlaybackService.shared.stop(reason: "notification-stop")
                }
            } else if actionId == "SNOOZE_ALARM" {
                // Snooze action
                SmartWakeDebugLog.log("NOTIFICATION action: SNOOZE alarmID=\(alarmIDString) occurrenceKey=\(occurrenceKey)")
                Task { @MainActor in
                    await snoozeAlarm(alarmID: alarmID, occurrenceKey: occurrenceKey)
                }
            }
        }
        
        completionHandler()
    }
    
    @MainActor
    private func snoozeAlarm(alarmID: UUID, occurrenceKey: String) async {
        // Stop current playback
        AlarmPlaybackService.shared.stop(reason: "snooze")
        
        // Find the alarm and schedule snooze
        if let coordinator = AlarmCoordinator.sharedInstance,
           let alarm = coordinator.alarms.first(where: { $0.id == alarmID }) {
            let snoozeMinutes = alarm.snoozeDurationMinutes ?? 10
            let snoozeFireDate = Date().addingTimeInterval(TimeInterval(snoozeMinutes * 60))
            
            do {
                // Schedule one-shot AlarmKit alarm using existing path (precomposed floor WAV)
                let snoozeID = UUID()
                let snoozeConfig = AlarmManager.AlarmConfiguration<ScheduledOccurrenceMetadata>(
                    countdownDuration: Alarm.CountdownDuration(preAlert: nil, postAlert: 0),
                    schedule: .fixed(snoozeFireDate),
                    attributes: AlarmAttributes(
                        presentation: AlarmPresentation(
                            alert: AlarmPresentation.Alert(
                                title: LocalizedStringResource(stringLiteral: alarm.label.isEmpty ? "Alarm" : alarm.label),
                                stopButton: AlarmButton(text: "Stop", textColor: .white, systemImageName: "stop.circle.fill"),
                                secondaryButton: AlarmButton(text: "Snooze", textColor: .white, systemImageName: "zzz"),
                                secondaryButtonBehavior: .countdown
                            ),
                            countdown: AlarmPresentation.Countdown(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min")),
                            paused: AlarmPresentation.Paused(title: LocalizedStringResource(stringLiteral: "Snoozed \(snoozeMinutes) min"), resumeButton: AlarmButton(text: "Resume", textColor: .white, systemImageName: "play.circle.fill"))
                        ),
                        metadata: ScheduledOccurrenceMetadata(
                            alarmID: alarm.id,
                            occurrenceKey: "SNOOZE-\(occurrenceKey)",
                            baseDate: snoozeFireDate
                        ),
                        tintColor: .orange
                    ),
                    stopIntent: nil,
                    secondaryIntent: nil,
                    sound: (try? await coordinator.alarmKitSound(for: alarm.sound, loudness: alarm.loudness)) ?? .default
                )
                _ = try await AlarmManager.shared.schedule(id: snoozeID, configuration: snoozeConfig)
                
                // Register with coordinator for reconcile exclusion
                coordinator.addEmergencyReRingID(snoozeID)
                
                SmartWakeDebugLog.log("SNOOZE scheduled id=\(snoozeID.uuidString) at \(snoozeFireDate)")
            } catch {
                SmartWakeDebugLog.log("SNOOZE scheduling FAILED: \(error.localizedDescription)")
            }
        }
    }
}

/// App Intents are automatically discovered from the widget extension's Info.plist
/// and the AppIntent protocols used in the widget bundle.
/// No explicit configuration needed in iOS 17+.
