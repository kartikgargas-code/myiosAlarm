import AlarmKit
import Observation
import SwiftUI
struct ProofAlarmMetadata: AlarmMetadata {
    let createdAt: Date
}
@MainActor
@Observable
final class AlarmProofOfConceptModel {
    enum Status: Equatable {
        case idle
        case requestingAuthorization
        case ready
        case scheduled(Date)
        case denied
        case failed(String)
    }
    private(set) var status: Status = .idle
    private let alarmManager = AlarmManager.shared
    var authorizationDescription: String {
        switch alarmManager.authorizationState {
        case .notDetermined: "Not requested"
        case .denied: "Denied"
        case .authorized: "Authorized"
        @unknown default: "Unknown"
        }
    }
    func requestAuthorization() async {
        status = .requestingAuthorization
        do {
            status = try await alarmManager.requestAuthorization() == .authorized ? .ready : .denied
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
    func scheduleTwoMinutesAhead(now: Date = .now) async {
        guard await ensureAuthorization() else { return }
        let plan = ProofAlarmPlan.twoMinutesAhead(from: now)
        let alert = AlarmPresentation.Alert(
            title: "AlarmKit Proof Alarm",
            stopButton: AlarmButton(
                text: "Stop",
                textColor: .white,
                systemImageName: "stop.circle.fill"
            )
        )
        let attributes = AlarmAttributes<ProofAlarmMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: ProofAlarmMetadata(createdAt: now),
            tintColor: .orange
        )
        let configuration = AlarmManager.AlarmConfiguration(
            schedule: .fixed(plan.fireDate),
            attributes: attributes
        )
        do {
            _ = try await alarmManager.schedule(id: UUID(), configuration: configuration)
            status = .scheduled(plan.fireDate)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
    private func ensureAuthorization() async -> Bool {
        switch alarmManager.authorizationState {
        case .authorized:
            return true
        case .notDetermined:
            await requestAuthorization()
            return status == .ready
        case .denied:
            status = .denied
            return false
        @unknown default:
            status = .failed("Unknown AlarmKit authorization state.")
            return false
        }
    }
}
