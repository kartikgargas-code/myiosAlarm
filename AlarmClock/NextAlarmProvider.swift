import Foundation

/// Provider for accessing the coordinator from SwiftUI environment.
/// App-target only: NextAlarmSnapshot.swift also compiles inside
/// AlarmClockShared, where AlarmCoordinator is not visible.
@MainActor
final class NextAlarmProvider: ObservableObject {
    let coordinator: AlarmCoordinator

    init(coordinator: AlarmCoordinator) {
        self.coordinator = coordinator
    }
}