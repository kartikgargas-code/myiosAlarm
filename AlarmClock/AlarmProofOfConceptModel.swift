import AlarmKit
import Observation
import SwiftUI
import UIKit

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

    private static let diagnosticsKey = "AlarmProofOfConceptDiagnostics"

    private(set) var status: Status = .idle
    private(set) var diagnostics: [String]
    private(set) var diagnosticsCopied = false

    private let alarmManager = AlarmManager.shared
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        diagnostics = defaults.stringArray(forKey: Self.diagnosticsKey) ?? []
        record("App opened on iOS \(UIDevice.current.systemVersion)")
        record("Current AlarmKit authorization: \(authorizationDescription)")
        record("NSAlarmKitUsageDescription present: \(usageDescriptionPresent)")
    }

    var authorizationDescription: String {
        Self.describe(alarmManager.authorizationState)
    }

    var diagnosticsText: String {
        ([
            "AlarmKit Proof Diagnostics",
            "iOS version: \(UIDevice.current.systemVersion)",
            "Current authorization: \(authorizationDescription)",
            "NSAlarmKitUsageDescription: \(usageDescriptionValue ?? "MISSING")"
        ] + diagnostics).joined(separator: "\n")
    }

    func authorizationButtonTapped() async {
        record("Authorization button tapped")
        await requestAuthorization()
    }

    func requestAuthorization() async {
        status = .requestingAuthorization
        record("Authorization request started")

        do {
            let returnedState = try await alarmManager.requestAuthorization()
            record("Authorization request completed")
            record("Returned authorization status: \(Self.describe(returnedState))")
            record("Current authorization after request: \(authorizationDescription)")
            status = returnedState == .authorized ? .ready : .denied
        } catch {
            record(error: error, operation: "Authorization request")
            status = .failed(error.localizedDescription)
        }
    }

    func scheduleTwoMinutesAhead(now: Date = .now) async {
        record("Schedule button tapped")
        guard await ensureAuthorization() else {
            record("Alarm scheduling stopped: authorization unavailable")
            return
        }

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

        record("Alarm scheduling started for \(plan.fireDate.formatted(date: .complete, time: .standard))")
        do {
            let alarm = try await alarmManager.schedule(id: UUID(), configuration: configuration)
            status = .scheduled(plan.fireDate)
            record("Alarm scheduling completed: success, id \(alarm.id.uuidString)")
        } catch {
            record(error: error, operation: "Alarm scheduling")
            status = .failed(error.localizedDescription)
        }
    }

    func copyDiagnostics() {
        UIPasteboard.general.string = diagnosticsText
        diagnosticsCopied = true
        record("Diagnostics copied")
    }

    private var usageDescriptionValue: String? {
        Bundle.main.object(forInfoDictionaryKey: "NSAlarmKitUsageDescription") as? String
    }

    private var usageDescriptionPresent: Bool {
        guard let value = usageDescriptionValue else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func ensureAuthorization() async -> Bool {
        record("Authorization checked before scheduling: \(authorizationDescription)")
        switch alarmManager.authorizationState {
        case .authorized:
            return true
        case .notDetermined:
            await requestAuthorization()
            return alarmManager.authorizationState == .authorized
        case .denied:
            status = .denied
            return false
        @unknown default:
            let message = "Unknown AlarmKit authorization state."
            record(message)
            status = .failed(message)
            return false
        }
    }

    private func record(error: Error, operation: String) {
        let error = error as NSError
        record("\(operation) failed")
        record("Error message: \(error.localizedDescription)")
        record("Error domain: \(error.domain)")
        record("Error code: \(error.code)")
        if !error.userInfo.isEmpty {
            record("Error userInfo: \(error.userInfo)")
        }
    }

    private func record(_ message: String) {
        let entry = "[\(Date.now.formatted(date: .numeric, time: .standard))] \(message)"
        diagnostics.append(entry)
        if diagnostics.count > 100 {
            diagnostics.removeFirst(diagnostics.count - 100)
        }
        defaults.set(diagnostics, forKey: Self.diagnosticsKey)
    }

    private static func describe(_ state: AlarmManager.AuthorizationState) -> String {
        switch state {
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .authorized: "Authorized"
        @unknown default: "Unknown (raw API case)"
        }
    }
}
