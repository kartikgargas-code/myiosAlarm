with open(r'D:\myiosAlarm\AlarmClock\SoundPickerView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

old = '''    private func randomPlaylistRow(playlist: Playlist) -> some View {
        let randomSound = AlarmSound.random(playlist.id)
        let isSelected = selectedSound.id == randomSound.id
        let selectedCount = playlist.selectedSoundIDs.count
        let totalCount = playlist.soundIDs.count
        let isPlayingThis = preview.playingSoundID == randomSound.id
        
        // Get first song preview URL for the play button
        let firstSoundID = playlist.selectedSoundIDs.first
        let firstPreviewURL = firstSoundID.flatMap { soundID in
            SoundLibrary.shared.importedSounds.first(where: { $0.id == soundID })?.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
        }
        
        return Button {
            selectedSound = randomSound
            // Play first song as preview
            if let firstSoundID = playlist.selectedSoundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let previewURL = sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory) {
                preview.play(url: previewURL, id: randomSound.id)
            }
        } label: {
            HStack {
                // Play/Pause toggle on the left (like playlist editor)
                if let firstPreviewURL {
                    Button {
                        if preview.playingSoundID == randomSound.id {
                            preview.stop()
                        } else {
                            preview.play(url: firstPreviewURL, id: randomSound.id)
                        }
                    } label: {
                        Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "speaker.slash")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("Random — \(playlist.name)")
                        .font(.body)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                    Text("\(selectedCount) of \(totalCount) songs selected")
                        .font(.caption)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
                Spacer()
                if isPlayingThis {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(ThemeManager.shared.colors.accent)
                        .font(.title3)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ThemeManager.shared.colors.accent)
                        .font(.title2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                showingPlaylistEditor = playlist
            } label: {
                Label("Edit Songs", systemImage: "music.note.list")
            }
        }
    }'''

new = '''    private func randomPlaylistRow(playlist: Playlist) -> some View {
        let randomSound = AlarmSound.random(playlist.id)
        let isSelected = selectedSound.id == randomSound.id
        let selectedCount = playlist.selectedSoundIDs.count
        let totalCount = playlist.soundIDs.count
        let isPlayingThis = preview.playingSoundID == randomSound.id
        
        // Get first song preview URL for the play button
        let firstSoundID = playlist.selectedSoundIDs.first
        let firstPreviewURL = firstSoundID.flatMap { soundID in
            SoundLibrary.shared.importedSounds.first(where: { $0.id == soundID })?.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
        }
        
        return Button {
            selectedSound = randomSound
            // Play first song as preview
            if let firstSoundID = playlist.selectedSoundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }),
               let previewURL = sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory) {
                preview.play(url: previewURL, id: randomSound.id)
            }
        } label: {
            HStack(spacing: 12) {
                // Play/Pause toggle on the left (like playlist editor)
                if let firstPreviewURL {
                    Button {
                        if preview.playingSoundID == randomSound.id {
                            preview.stop()
                        } else {
                            preview.play(url: firstPreviewURL, id: randomSound.id)
                        }
                    } label: {
                        Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "speaker.slash")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text("Random — \(playlist.name)")
                        .font(.body)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                    Text("\(selectedCount) of \(totalCount) songs selected")
                        .font(.caption)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
                Spacer()
                if isPlayingThis {
                    Image(systemName: "waveform.circle.fill")
                        .foregroundStyle(ThemeManager.shared.colors.accent)
                        .font(.title3)
                }
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ThemeManager.shared.colors.accent)
                        .font(.title2)
                }
            }
            .padding(.vertical, 4)  // Compact vertical insets
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                showingPlaylistEditor = playlist
            } label: {
                Label("Edit Songs", systemImage: "music.note.list")
            }
        }
    }'''

if old in content:
    content = content.replace(old, new)
    with open(r'D:\myiosAlarm\AlarmClock\SoundPickerView.swift', 'w', encoding='utf-8') as f:
        f.write(content)
    print('Replacement successful')
else:
    print('OLD text not found exactly')