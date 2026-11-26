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
        
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        let stamp = info?["AlarmClockBuildStamp"] as? String ?? "unknown"
        SmartWakeDebugLog.log("BUILD: v\(v) (\(b)) commit=\(stamp)")
        
        // Log previous day's silent loop total
        SmartWakeService.shared.logPreviousDayTotal()
        
        // Automatic cleanup at app launch
        Task { @MainActor in
            AlarmCoordinator.sharedInstance?.pruneStitchCacheNow()
        }
        
        // HEARTBEAT timer will be started/stopped via scenePhase in ContentView
        // No timer started here - it will be managed by scene phase changes
    }
    
    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(SoundsUIState())
        }
    }
}

/// Handles orientation and any notification actions delivered by an earlier build.
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
        AppDelegate.registerNotificationCategories()
        return true
    }

    /// The hold-to-choose snooze notice carries three snooze choices. They run in the
    /// background without unlocking and without opening the app. No custom dismiss
    /// action, so swiping the notice away is inert.
    private static func registerNotificationCategories() {
        let choices = [5, 10, 15].map { minutes in
            UNNotificationAction(
                identifier: "SNOOZE_CHOICE_\(minutes)",
                title: "Snooze \(minutes) min",
                options: []
            )
        }
        let category = UNNotificationCategory(
            identifier: AlarmNotificationIDs.snoozeChoiceCategory,
            actions: choices,
            intentIdentifiers: [],
            options: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let alarmIDString = userInfo["alarmID"] as? String ?? ""
        let occurrenceKey = userInfo["occurrenceKey"] as? String ?? ""
        
        if let alarmID = UUID(uuidString: alarmIDString) {
            if actionId == "STOP_ALARM" {
                // Stop action: stops this ringing alarm only (playback + its backup alarm)
                SmartWakeDebugLog.log("NOTIFY ALARM action=stop alarm=\(alarmIDString)")
                Task { @MainActor in
                    AlarmPlaybackService.shared.stopRingingAlarmFromNotification(
                        alarmID: alarmID,
                        occurrenceKey: occurrenceKey
                    )
                }
            } else if actionId == "SNOOZE_ALARM" {
                // Snooze tapped on a notice from an earlier build: same shared routine
                SmartWakeDebugLog.log("NOTIFY ALARM action=snooze alarm=\(alarmIDString)")
                Task { @MainActor in
                    await snoozeAlarm(alarmID: alarmID, occurrenceKey: occurrenceKey)
                }
            } else if actionId.hasPrefix("SNOOZE_CHOICE_") {
                // Hold-to-choose snooze: the chosen minutes apply to this ring only
                let minutes = Int(actionId.replacingOccurrences(of: "SNOOZE_CHOICE_", with: "")) ?? 10
                Task { @MainActor in
                    AlarmPlaybackService.shared.snoozeRingingAlarmFromNotification(
                        alarmID: alarmID,
                        occurrenceKey: occurrenceKey,
                        minutes: minutes
                    )
                }
            } else if actionId == UNNotificationDismissActionIdentifier {
                // Swiping the notification away must never silence the alarm
                SmartWakeDebugLog.log("NOTIFY ALARM action=dismissed alarm=\(alarmIDString)")
            }
        }
        
        completionHandler()
    }
    
    @MainActor
    private func snoozeAlarm(alarmID: UUID, occurrenceKey: String) async {
        // Old handler kept for notifications posted by an earlier build. It no longer
        // schedules anything itself: it hands the tap to the one shared snooze routine
        // with the alarm's saved snooze length.
        let savedMinutes = AlarmCoordinator.sharedInstance?
            .alarms.first(where: { $0.id == alarmID })?
            .snoozeDurationMinutes ?? 10
        AlarmPlaybackService.shared.snoozeRingingAlarmFromNotification(
            alarmID: alarmID,
            occurrenceKey: occurrenceKey,
            minutes: savedMinutes
        )
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
    private static var lastChargingState: Bool? = nil
    /// Count of widget reloads since app launch (for heartbeat)
    static var widgetReloadsSinceLaunch: Int = 0
    
    static func start() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        lastChargingState = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
        write(forceReload: true)
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            write(forceReload: false)
        }
        NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            let newChargingState = UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full
            if lastChargingState != newChargingState {
                lastChargingState = newChargingState
                write(forceReload: true)
            }
        }
        // A reload asked for while the app is on the way to the background, is not
        // charged to the widget budget - so those are the moments worth spending.
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
    
    /// Called when an alarm is added, removed, or changed to trigger a widget reload
    static func notifyAlarmChanged() {
        write(forceReload: true)
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
        widgetReloadsSinceLaunch += 2
        // Only log when a reload actually happens
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
