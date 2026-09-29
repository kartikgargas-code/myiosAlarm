import SwiftUI
import AppIntents

@main
struct AlarmClockApp: App {
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
