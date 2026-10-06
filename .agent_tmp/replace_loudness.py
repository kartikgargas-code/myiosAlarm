import re

with open(r'D:\myiosAlarm\AlarmClock\AlarmEditorView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

old_section = '''    private var loudnessSection: some View {
        Section("Alarm Sound Loudness") {
            HStack {
                Text("Loudness")
                Spacer()
                Text(selectedLoudness.displayName)
                    .monospacedDigit()
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            Slider(value: loudnessBinding, in: 0...100, step: 1)
        }
    }
    
    private var loudnessBinding: Binding<Double> {
        Binding(
            get: { Double(selectedLoudness.percentage) },
            set: { selectedLoudness = AlarmLoudness(Int($0.rounded())) }
        )
    }'''

new_section = '''    private var loudnessSection: some View {
        Section("Alarm Sound Loudness") {
            HStack {
                Text("Loudness")
                Spacer()
                Text(selectedLoudness.displayName)
                    .monospacedDigit()
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            Slider(
                value: loudnessBinding,
                in: 0...100,
                step: 1,
                onEditingChanged: { editing in
                    if editing {
                        startLoudnessPreview()
                    } else {
                        stopLoudnessPreview()
                    }
                }
            )
        }
    }
    
    private var loudnessBinding: Binding<Double> {
        Binding(
            get: { Double(selectedLoudness.percentage) },
            set: { selectedLoudness = AlarmLoudness(Int($0.rounded())) }
        )
    }
    
    @State private var loudnessPreviewTask: Task<Void, Never>?
    @State private var loudnessPreviewURL: URL?
    @State private var loudnessPreviewSoundID: String?
    
    private func startLoudnessPreview() {
        // Get the sound URL for the selected sound
        let soundID = getSoundIDForPreview()
        guard let url = getSoundURLForPreview() else { return }
        
        loudnessPreviewURL = url
        loudnessPreviewSoundID = soundID
        
        // Start playing the preview with initial volume
        SoundPreviewService.shared.play(url: url, id: soundID ?? "loudness-preview")
        updatePreviewVolume()
        
        // Update volume continuously while slider is being dragged
        loudnessPreviewTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
                if !Task.isCancelled {
                    updatePreviewVolume()
                }
            }
        }
    }
    
    private func stopLoudnessPreview() {
        loudnessPreviewTask?.cancel()
        loudnessPreviewTask = nil
        SoundPreviewService.shared.stop()
        loudnessPreviewURL = nil
        loudnessPreviewSoundID = nil
    }
    
    private func updatePreviewVolume() {
        if let player = SoundPreviewService.shared.player,
           SoundPreviewService.shared.playingSoundID == (loudnessPreviewSoundID ?? "loudness-preview") {
            let volume = selectedLoudness.gainFactor
            player.volume = Float(volume)
        }
    }
    
    private func getSoundURLForPreview() -> URL? {
        switch selectedSound {
        case .systemDefault:
            return SoundPreviewService.bundledSoundURL(for: "system_default")
        case .builtIn(let name):
            return SoundPreviewService.bundledSoundURL(for: name)
        case .imported(let id):
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }),
               let soundsDir = SoundLibrary.shared.soundsDirectory {
                return sound.localURL(soundsDirectory: soundsDir)
            }
            return nil
        case .random(let playlistID):
            // For random playlists, pick the first sound
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
               let firstSoundID = playlist.soundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let soundsDir = SoundLibrary.shared.soundsDirectory {
                return sound.localURL(soundsDirectory: soundsDir)
            }
            return nil
        case .precomposedPlaylist(let playlistID, _):
            // For precomposed playlists, we can't easily get a single sound
            // Fall back to first sound in the playlist
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
               let firstSoundID = playlist.soundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let soundsDir = SoundLibrary.shared.soundsDirectory {
                return sound.localURL(soundsDirectory: soundsDir)
            }
            return nil
        }
    }
    
    private func getSoundIDForPreview() -> String? {
        switch selectedSound {
        case .systemDefault:
            return "system_default"
        case .builtIn(let name):
            return name
        case .imported(let id):
            return id.uuidString
        case .random(let pid):
            return "random-\(pid.uuidString)"
        case .precomposedPlaylist(let pid, _):
            return "precomposed-\(pid.uuidString)"
        }
    }'''

# Replace
new_content = content.replace(old_section, new_section)

with open(r'D:\myiosAlarm\AlarmClock\AlarmEditorView.swift', 'w', encoding='utf-8') as f:
    f.write(new_content)

print("Replacement done!")