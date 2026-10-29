import SwiftUI
import AppIntents
import AlarmKit
import AlarmClockShared
import UserNotifications
import WidgetKit

@main
struct AlarmClockApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    init() {
        // Shrink large title font from ~34 to 28
        UINavigationBar.appearance().largeTitleTextAttributes = [.font: UIFont.systemFont(ofSize: 28, weight: .bold)]
        
        // Register the Live Activity alarm service for the main app
        // App @main entry points already run on the main thread
        MainActor.assumeIsolated {
            LiveActivityAlarmServiceProvider.shared = SharedAlarmService()
        }

        // Keep the Lock Screen battery widget's figure fresh
        BatteryReporter.start()
        // What did the phone actually grant us? Written to the log so the Diagnostics
        // screen answers it without a Mac, and the shared alarm copy is put back so the
        // widgets have something to show even when nothing has been edited.
        SmartWakeDebugLog.log("APPGROUP " + AppGroupResolver.describe(), force: true)
        SharedStorage.republish()
        
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
        
        // Log previous day's silent loop total
        SmartWakeService.shared.logPreviousDayTotal()
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

/// App delegate to handle notification actions
class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    @MainActor private static var clockLandscapeAllowed = false

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.clockLandscapeAllowed ? .all : .portrait
    }

    @MainActor
    static func setClockLandscapeAllowed(_ allowed: Bool) {
        clockLandscapeAllowed = allowed
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let preferences = UIWindowScene.GeometryPreferences.iOS(
            interfaceOrientations: allowed ? .all : .portrait
        )
        scene.requestGeometryUpdate(preferences) { _ in }
    }

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
                
                // Update widget snapshot so Lock Screen/widget shows the snoozed ring time
                coordinator.publishSnoozeWidgetSnapshot(
                    alarm: alarm,
                    fireDate: snoozeFireDate,
                    occurrenceKey: "SNOOZE-\(occurrenceKey)"
                )
                SmartWakeDebugLog.log("SNOOZE (lock screen): widget snapshot updated")
                
                // Post snooze notification with auto-hide after ~1 minute
                let content = UNMutableNotificationContent()
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("j:mm a")
                formatter.timeZone = TimeZone.current
                content.title = "Snoozed \(snoozeMinutes) min at \(formatter.string(from: snoozeFireDate))"
                content.body = ""
                content.sound = nil // Silent notification
                
                let request = UNNotificationRequest(
                    identifier: "SNOOZE-\(snoozeID.uuidString)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
                )
                
                UNUserNotificationCenter.current().add(request) { error in
                    if let error = error {
                        SmartWakeDebugLog.log("SNOOZE (lock screen) notification failed: \(error.localizedDescription)")
                    } else {
                        SmartWakeDebugLog.log("SNOOZE (lock screen): notification posted")
                        // Auto-hide notification after ~1 minute (best effort)
                        Task {
                            try? await Task.sleep(nanoseconds: 60_000_000_000)
                            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["SNOOZE-\(snoozeID.uuidString)"])
                            SmartWakeDebugLog.log("SNOOZE (lock screen) notification auto-hidden after 60s")
                        }
                    }
                }
            } catch {
                SmartWakeDebugLog.log("SNOOZE scheduling FAILED: \(error.localizedDescription)")
            }
        }
    }
}

/// App Intents are automatically discovered from the widget extension's Info.plist
/// and the AppIntent protocols used in the widget bundle.
/// No explicit configuration needed in iOS 17+.


enum BatteryReporter {
    static let batteryWidgetKind = "com.example.alarmclock.battery-widget"
    static let nextAlarmWidgetKind = "com.example.alarmclock.next-alarm-widget"
    
    /// The level a reload was last asked for, and when. iOS budgets widget reloads (about 40-70
    /// a day), so asking on every 1% step while charging spent the budget and the widget then
    /// froze on an old number. Only a 5% move, an hour of silence, or a moment that does not
    /// count against the budget gets a reload now.
    private static var lastReloadPercent: Int? = nil
    private static var lastReloadAt: Date = .distantPast
    static func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        write(forceReload: true)
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            write(forceReload: false)
        }
        // A reload asked for while the app is awake, or on the way to the background, is not
        // charged to the widget budget - so those are the moments worth spending.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            write(forceReload: true)
        }
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            write(forceReload: true)
        }
        // Keep the stored number recent. No reload ask: the five-minute write is silent.
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            write(forceReload: false)
        }
    }
    static func write(forceReload: Bool) {
        let level = UIDevice.current.batteryLevel
        guard level >= 0 else { return }
        let defaults = WidgetSettingsStore.defaults
        defaults.set(Double(level), forKey: "appBatteryLevel")
        defaults.set(Date().timeIntervalSince1970, forKey: "appBatteryLevelAt")
        let percent = Int((level * 100).rounded())
        let movedFive = lastReloadPercent.map { abs(percent - $0) >= 5 } ?? true
        let silentTooLong = Date().timeIntervalSince(lastReloadAt) > 3600
        guard forceReload || movedFive || silentTooLong else { return }
        lastReloadPercent = percent
        lastReloadAt = Date()
        // Reload BOTH widget kinds that show battery: circular battery + inline next-alarm
        WidgetCenter.shared.reloadTimelines(ofKind: batteryWidgetKind)
        WidgetCenter.shared.reloadTimelines(ofKind: nextAlarmWidgetKind)
        SmartWakeDebugLog.log("BATTERY reload asked n=\(percent)% force=\(forceReload) moved5=\(movedFive) silent=\(silentTooLong) kinds=\(batteryWidgetKind),\(nextAlarmWidgetKind)")
    }
}

/// The shared App Group the app and the widgets both read, kept in one place so the
/// Diagnostics screen can report exactly what the phone granted.
enum SharedStorage {
    static func resolve() -> String? {
        AppGroupResolver.resolve()
    }

    /// Copy the app's own alarm file into the shared container and reload the widget
    /// kinds. Best-effort: with no usable container there is nothing to do.
    static func republish() {
        guard let group = resolve(),
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
              ) else {
            return
        }
        let source = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("alarms.json")
        if let data = try? Data(contentsOf: source) {
            try? data.write(to: container.appendingPathComponent("alarms.json"), options: .atomic)
        }

        var kinds = [BatteryReporter.batteryWidgetKind, "com.example.alarmclock.memory-widget"]
        if let nextAlarmKind = Bundle.main.object(forInfoDictionaryKey: "AlarmClockWidgetKind") as? String {
            kinds.append(nextAlarmKind)
        }
        for kind in kinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
    }
}
