import AVFoundation
import Observation
import Foundation
import os.log

/// Background audio session manager for "Smart Wake" feature
/// Keeps a silent/near-silent loop running overnight so the app stays alive
/// and can play the real song at alarm time with Now Playing info
@MainActor
@Observable
final class SmartWakeService {
    static let shared = SmartWakeService()

    private let log = OSLog(subsystem: "com.example.alarmclock", category: "SmartWake")
    private let fileManager = FileManager.default
    private var player: AVAudioPlayer?
    private var isSessionActive = false
    private var isEnabled = false
    private var silentLoopURL: URL?
    private let notificationHandler = NotificationHandler()

    // User preference key
    private let enabledKey = "SmartWakeEnabled"

    var isRunning: Bool {
        isSessionActive && player?.isPlaying == true
    }

    init() {
        loadPreference()
        prepareSilentLoop()
        notificationHandler.owner = self
    }

    private func loadPreference() {
        isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
    }

    var isSmartWakeEnabled: Bool {
        get { isEnabled }
        set {
            guard newValue != isEnabled else { return }
            isEnabled = newValue
            UserDefaults.standard.set(newValue, forKey: enabledKey)
            if newValue {
                Task { await startIfAlarmArmed() }
            } else {
                stop()
            }
        }
    }

    /// Prepare the silent loop audio file (generates a 1-second near-silent WAV if needed)
    private func prepareSilentLoop() {
        let documentsDir = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first!
        silentLoopURL = documentsDir.appendingPathComponent("smartwake_silent_loop.wav")

        if fileManager.fileExists(atPath: silentLoopURL!.path) {
            return
        }

        // Generate a 1-second near-silent WAV file programmatically
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.generateSilentLoop()
        }
    }

    private func generateSilentLoop() async {
        guard let url = silentLoopURL else { return }

        let sampleRate = 44100.0
        let duration = 1.0 // 1 second loop
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            os_log(.error, log: log, "Failed to create silent buffer")
            return
        }
        buffer.frameLength = frameCount

        // Fill with near-silence (very low amplitude to keep audio session alive)
        let channels = Int(format.channelCount)
        let frames = Int(buffer.frameLength)
        let amplitude: Float = 0.0001 // -80 dB, barely audible but keeps session alive

        for channel in 0..<channels {
            guard let channelData = buffer.floatChannelData?[channel] else { continue }
            for frame in 0..<frames {
                // Very low frequency tone at near-zero amplitude
                channelData[frame] = amplitude * sin(2.0 * Float.pi * 20.0 * Float(frame) / Float(sampleRate))
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        do {
            let outputFile = try AVAudioFile(forWriting: url, settings: settings)
            try outputFile.write(from: buffer)
            os_log(.info, log: log, "Generated silent loop at %{public}s", url.path)
        } catch {
            os_log(.error, log: log, "Failed to generate silent loop: %{public}s", error.localizedDescription)
        }
    }

    /// Start the background audio session if an alarm is armed for the near future
    func startIfAlarmArmed(coordinator: AlarmCoordinator) async {
        guard isEnabled else { return }
        guard !isRunning else { return }

        let now = Date()
        let soon = now.addingTimeInterval(8 * 3600) // Within next 8 hours

        // Check if any alarm is armed and due soon
        let hasUpcomingAlarm = coordinator.alarms.contains { alarm in
            guard alarm.isEnabled else { return false }
            if let occurrence = coordinator.occurrence(for: alarm.id) {
                return occurrence.effectiveDate <= soon && occurrence.effectiveDate > now
            }
            return false
        }

        guard hasUpcomingAlarm else {
            os_log(.info, log: log, "No upcoming alarm within 8h; not starting Smart Wake")
            return
        }

        await startBackgroundAudio()
    }

    /// Start the silent background audio loop
    private func startBackgroundAudio() async {
        guard let url = silentLoopURL,
              fileManager.fileExists(atPath: url.path) else {
            os_log(.error, log: log, "Silent loop file not ready")
            return
        }

        do {
            try configureAudioSession()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1 // Loop indefinitely
            newPlayer.volume = 0.001 // Near-silent
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                os_log(.error, log: log, "Failed to start silent loop playback")
                return
            }
            player = newPlayer
            isSessionActive = true
            os_log(.info, log: log, "Smart Wake silent loop started")

            // Register for interruption notifications
            registerForInterruptions()
        } catch {
            os_log(.error, log: log, "Failed to start background audio: %{public}s", error.localizedDescription)
        }
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
    }

    /// Stop the background audio session
    func stop() {
        player?.stop()
        player = nil
        isSessionActive = false

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            os_log(.error, log: log, "Failed to deactivate audio session: %{public}s", error.localizedDescription)
        }

        unregisterForInterruptions()
        os_log(.info, log: log, "Smart Wake stopped")
    }

    private func registerForInterruptions() {
        NotificationCenter.default.addObserver(
            notificationHandler,
            selector: #selector(NotificationHandler.handleInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        NotificationCenter.default.addObserver(
            notificationHandler,
            selector: #selector(NotificationHandler.handleRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance()
        )
    }

    private func unregisterForInterruptions() {
        NotificationCenter.default.removeObserver(notificationHandler, name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.removeObserver(notificationHandler, name: AVAudioSession.routeChangeNotification, object: nil)
    }

    fileprivate func handleInterruptionEnded(shouldResume: Bool) {
        if shouldResume {
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setActive(true)
                player?.play()
            }
        }
    }

    fileprivate func handleRouteChange(oldDeviceUnavailable: Bool) {
        if oldDeviceUnavailable {
            player?.pause()
        }
    }
}

/// Separate NSObject subclass to handle @objc notification callbacks without actor isolation issues
private final class NotificationHandler: NSObject {
    weak var owner: SmartWakeService?

    @objc func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

        switch type {
        case .began:
            Task { @MainActor in
                owner?.logInterruptionBegan()
            }
        case .ended:
            guard let optionsValue = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt else { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            Task { @MainActor in
                owner?.logInterruptionEnded(options: options)
                if options.contains(.shouldResume) {
                    owner?.handleInterruptionEnded(shouldResume: true)
                }
            }
        @unknown default:
            break
        }
    }

    @objc func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

        Task { @MainActor in
            owner?.logRouteChange(reason: reason)
            if reason == .oldDeviceUnavailable {
                owner?.handleRouteChange(oldDeviceUnavailable: true)
            }
        }
    }
}

extension SmartWakeService {
    @MainActor func logInterruptionBegan() {
        os_log(.info, log: log, "Audio interruption began")
    }

    @MainActor func logInterruptionEnded(options: AVAudioSession.InterruptionOptions) {
        os_log(.info, log: log, "Audio interruption ended, shouldResume: %{public}d", options.contains(.shouldResume) ? 1 : 0)
    }

    @MainActor func logRouteChange(reason: AVAudioSession.RouteChangeReason) {
        os_log(.info, log: log, "Audio route changed: %{public}d", reason.rawValue)
    }

    @MainActor func handleInterruptionEnded(shouldResume: Bool) {
        if shouldResume {
            Task { @MainActor in
                try? AVAudioSession.sharedInstance().setActive(true)
                player?.play()
            }
        }
    }

    @MainActor func handleRouteChange(oldDeviceUnavailable: Bool) {
        if oldDeviceUnavailable {
            player?.pause()
        }
    }
}