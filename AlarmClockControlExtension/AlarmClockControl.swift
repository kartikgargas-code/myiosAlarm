import AppIntents
import SwiftUI
import WidgetKit
import Foundation
import AlarmClockShared

/// The main control bundle for the Alarm Clock Lock Screen control
@main
struct AlarmClockControlBundle: ControlWidgetBundle {
    var body: some ControlWidget {
        NextAlarmControl()
    }
}

/// Lock Screen control button for the next alarm
struct NextAlarmControl: ControlWidget {
    static let kind: String = "com.example.alarmclock.next-alarm-control"
    
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: Self.kind) {
            ControlWidgetButton(action: OpenNextAlarmIntent()) {
                Label("Next Alarm", systemImage: "alarm.fill")
            }
        }
        .displayName("Next Alarm")
        .description("Opens the Next Alarm control screen.")
    }
}

/// App Intent to open the Next Alarm control screen
struct OpenNextAlarmIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Next Alarm"
    
    @Parameter(title: "Destination")
    var target: AlarmDestination
    
    init() {
        self.target = .nextAlarm
    }
    
    func perform() async throws -> some IntentResult {
        // The OpenIntent will automatically open the app
        // Deep linking to the Next Alarm screen is handled by the app
        return .result()
    }
}

/// Enum representing where the control can navigate
enum AlarmDestination: String, AppEnum {
    case nextAlarm
    
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Alarm Destination")
    
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .nextAlarm: DisplayRepresentation(
            title: "Next Alarm",
            subtitle: "View and control the next scheduled alarm"
        )
    ]
}