import Foundation
import SwiftUI
import UIKit
import os.log
import AlarmClockShared

/// Shared toast manager for copy-to-clipboard feedback across screens.
/// Shows a capsule at the bottom of the screen for ~2 seconds with a light haptic.
@MainActor
@Observable
final class CopyToastManager {
    static let shared = CopyToastManager()
    
    private let log = OSLog(subsystem: "com.example.alarmclock", category: "CopyToast")
    
    var message: String? = nil
    private var task: Task<Void, Never>? = nil
    
    private init() {}
    
    func show(_ message: String) {
        os_log(.info, log: log, "COPY TOAST: showing message=%{public}s", message)
        SmartWakeDebugLog.log("COPY TOAST show message=\(message)")
        task?.cancel()
        self.message = message
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        task = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds visible
            if !Task.isCancelled {
                await MainActor.run {
                    os_log(.info, log: log, "COPY TOAST: clearing message")
                    SmartWakeDebugLog.log("COPY TOAST clear")
                    withAnimation { self.message = nil }
                }
            }
        }
    }
    
    func hide() {
        task?.cancel()
        task = nil
        SmartWakeDebugLog.log("COPY TOAST clear")
        withAnimation { message = nil }
    }
}

/// Root view that hosts the shared copy toast overlay above all screens
struct RootView: View {
    @State private var toastManager = CopyToastManager.shared
    
    var body: some View {
        ContentView()
            .overlay(alignment: .bottom) {
                if let message = toastManager.message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(ThemeManager.shared.colors.card.opacity(0.95))
                        .clipShape(Capsule())
                        .shadow(radius: 4)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .padding(.bottom, 100)
                }
            }
            .preferredColorScheme(.dark)
    }
}