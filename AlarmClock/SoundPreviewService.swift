import AVFoundation
import Observation
import Foundation

enum StableSoundID {
    static func make(for fileName: String) -> UUID {
        StableOccurrenceID.make(
            alarmID: UUID(uuidString: "b23f4a5e-cc2f-4e71-9cde-979301000001")!,
            occurrenceKey: fileName
        )
    }
}

@MainActor
@Observable
final class SoundPreviewService: NSObject {
    static let shared = SoundPreviewService()

    private(set) var playingSoundID: String?
    private(set) var lastError: String?

    var player: AVAudioPlayer?
    private var sessionConfigured = false

    static func bundledSoundURL(for fileName: String) -> URL? {
        let name = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        if let url = Bundle.main.url(forResource: name, withExtension: ext, subdirectory: "BuiltInSounds") {
            return url
        }
        return Bundle.main.url(forResource: name, withExtension: ext)
    }

    func play(url: URL, id: String, volume: Float = 1.0) {
        stop()
        do {
            try configureSessionIfNeeded()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = volume
            newPlayer.prepareToPlay()
            newPlayer.delegate = self
            guard newPlayer.play() else {
                lastError = "Preview could not start for \(url.lastPathComponent)."
                return
            }
            player = newPlayer
            playingSoundID = id
            lastError = nil
        } catch {
            lastError = "Preview failed for \(url.lastPathComponent): \(error.localizedDescription)"
            playingSoundID = nil
        }
    }

    func stop() {
        player?.stop()
        player = nil
        playingSoundID = nil
    }

    private func configureSessionIfNeeded() throws {
        guard !sessionConfigured else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)
        sessionConfigured = true
    }
}

extension SoundPreviewService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.player = nil
            self.playingSoundID = nil
        }
    }
}