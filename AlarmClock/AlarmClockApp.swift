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

/// App Intents declaration for the main app
struct AlarmClockAppIntents: AppIntentsConfiguration {
    static var intents: [AppIntent.Type] {
        [
            AdjustNextAlarmIntent.self,
            ResetNextAlarmIntent.self,
            SkipNextAlarmIntent.self,
            UndoSkipAlarmIntent.self,
            OpenNextAlarmIntent.self,
        ]
    }
}
