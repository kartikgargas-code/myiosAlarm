import SwiftUI

struct ContentView: View {
    @State private var model = AlarmProofOfConceptModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Image(systemName: "alarm.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(.orange)

                    VStack(spacing: 8) {
                        Text("AlarmKit Proof of Concept")
                            .font(.title2.bold())
                        Text("Schedules one real system alarm two minutes ahead.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    statusCard

                    Button("Request Alarm Access") {
                        Task { await model.authorizationButtonTapped() }
                    }
                    .buttonStyle(.bordered)

                    Button("Schedule Alarm in 2 Minutes") {
                        Task { await model.scheduleTwoMinutesAhead() }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    diagnosticsCard
                }
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .background(Color.black)
            .navigationTitle("Alarm Clock")
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Authorization: \(model.authorizationDescription)")
                .font(.headline)
            Text(statusMessage)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Diagnostics")
                    .font(.headline)
                Spacer()
                Button(model.diagnosticsCopied ? "Copied" : "Copy Diagnostics") {
                    model.copyDiagnostics()
                }
                .buttonStyle(.bordered)
            }

            Text(model.diagnosticsText)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding()
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 16))
    }

    private var statusMessage: String {
        switch model.status {
        case .idle: "Ready to request access."
        case .requestingAuthorization: "Requesting access…"
        case .ready: "Alarm access granted."
        case .scheduled(let date): "Scheduled for \(date.formatted(date: .omitted, time: .standard))."
        case .denied: "Access denied. Enable Alarms for this app in Settings."
        case .failed(let message): "Request failed: \(message)"
        }
    }
}
