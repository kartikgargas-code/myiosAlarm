import SwiftUI
import AppIntents
import AlarmClockShared

@main
struct AlarmClockApp: App {
    init() {
        // Register the Live Activity alarm service for the main app
        Task { @MainActor in
            LiveActivityAlarmServiceProvider.shared = SharedAlarmService()
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
