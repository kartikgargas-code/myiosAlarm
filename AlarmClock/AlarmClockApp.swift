import SwiftUI
import AppIntents
import AlarmClockShared
import UserNotifications

@main
struct AlarmClockApp: App {
    init() {
        // Register the Live Activity alarm service for the main app
        // App @main entry points already run on the main thread
        MainActor.assumeIsolated {
            LiveActivityAlarmServiceProvider.shared = SharedAlarmService()
        }
        
        // Request notification authorization for Stop action on lock screen
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                SmartWakeDebugLog.log("NOTIFICATION auth error: \(error.localizedDescription)")
            }
            SmartWakeDebugLog.log("NOTIFICATION authorization (app launch): \(granted ? "granted" : "denied")")
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
    }
}

/// App Intents are automatically discovered from the widget extension's Info.plist
/// and the AppIntent protocols used in the widget bundle.
/// No explicit configuration needed in iOS 17+.
