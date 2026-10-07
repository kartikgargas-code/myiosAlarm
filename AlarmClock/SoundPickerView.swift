import SwiftUI
import UniformTypeIdentifiers
import UserNotifications

struct SoundPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedSound: AlarmSound
    let alarms: [AlarmRecord]

    @State private var showingDocumentPicker = false
    @State private var showingPlaylistPicker = false
    @State private var importError: String?
    @State private var importStatus: String?
    // pickerEventLog removed - diagnostics section deleted
    @State private var showingDeleteConfirmation = false
    // Single fileImporter driven by enum — avoids SwiftUI conflict of two modifiers
    @State private var pickerMode: PickerMode = .files
    private enum PickerMode { case files, folder }

    // Local copy for Cancel/Save behavior
    @State private var initialSelection: AlarmSound
    
    init(selectedSound: Binding<AlarmSound>, alarms: [AlarmRecord]) {
        self._selectedSound = selectedSound
        self.alarms = alarms
        self._initialSelection = State(initialValue: selectedSound.wrappedValue)
    }

    private let preview = SoundPreviewService.shared
    
    // Computed properties for Selected section
    private var selectedSoundDisplayName: String {
        switch selectedSound {
        case .systemDefault: return "Default"
        case .builtIn(let name): return name
        case .imported(let id):
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                return sound.name
            }
            return "Imported"
        case .random(let playlistID):
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID) {
                return "Random — \(playlist.name)"
            }
            return "Random"
        case .precomposedPlaylist(let playlistID, _):
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID) {
                return "Precomposed — \(playlist.name)"
            }
            return "Precomposed"
        }
    }
    
    private var selectedSoundDescription: String {
        switch selectedSound {
        case .systemDefault: return "System default alarm sound"
        case .builtIn: return "Bundled alarm sound"
        case .imported: return "Imported"
        case .random(let playlistID):
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID) {
                return "Random from \(playlist.selectedSoundIDs.count) songs in \(playlist.name)"
            }
            return "Random from playlist"
        case .precomposedPlaylist(let playlistID, _):
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID) {
                return "Precomposed playlist: \(playlist.name)"
            }
            return "Precomposed playlist"
        }
    }
    
    private var selectedSoundPreviewURL: URL? {
        switch selectedSound {
        case .systemDefault: return nil
        case .builtIn(let name):
            return SoundPreviewService.bundledSoundURL(for: BuiltInSound.fileName(for: name) ?? "")
        case .imported(let id):
            if let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == id }) {
                return sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
            }
            return nil
        case .random(let playlistID):
            if let playlist = try? SoundLibrary.shared.playlist(for: playlistID),
               let firstSoundID = playlist.selectedSoundIDs.first,
               let sound = SoundLibrary.shared.importedSounds.first(where: { $0.id == firstSoundID }) {
                return sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
            }
            return nil
        case .precomposedPlaylist(let playlistID, _):
            // Precomposed playlists don't have a single preview URL
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // Selected sound at top (pinned) - only show if not system default
                if selectedSound != .systemDefault {
                    Section("Selected") {
                        soundRow(
                            sound: selectedSound,
                            label: selectedSoundDisplayName,
                            description: selectedSoundDescription,
                            previewURL: selectedSoundPreviewURL
                        )
                    }
                }

                // Import actions at top for easy access
                Section("Import") {
                    Button {
                        pickerMode = .files
                        showingDocumentPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Import MP3 from Files")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                        }
                    }

                    Button {
                        pickerMode = .folder
                        showingDocumentPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Import MP3 Folder as Playlist")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                        }
                    }
                }

                Section("Random from Playlist") {
                    if SoundLibrary.shared.playlists.isEmpty {
                        Text("No playlists available. Import a folder to create one.")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    } else {
                        ForEach(SoundLibrary.shared.playlists) { playlist in
                            randomPlaylistRow(playlist: playlist)
                        }
                    }

                    if !SoundLibrary.shared.playlists.isEmpty {
                        Button {
                            showingPlaylistPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "music.note.list")
                                    .foregroundStyle(ThemeManager.shared.colors.accent)
                                Text("Create New Playlist")
                                    .foregroundStyle(ThemeManager.shared.colors.accent)
                            }
                        }
                    }
                }

                Section("Default") {
                    soundRow(
                        sound: .systemDefault,
                        label: "Default",
                        description: "System default alarm sound",
                        previewURL: nil
                    )
                }

                Section("Built-in Sounds") {
                    ForEach(BuiltInSound.allCases, id: \.self) { builtIn in
                        soundRow(
                            sound: .builtIn(builtIn.rawValue),
                            label: builtIn.rawValue,
                            description: "Bundled alarm sound",
                            previewURL: builtInSoundURL(builtIn)
                        )
                    }
                }

                Section("Imported Sounds") {
                    ForEach(SoundLibrary.shared.importedSounds.filter { sound in
                        // Skip sounds that no longer exist on disk
                        guard let url = sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory) else { return false }
                        return FileManager.default.fileExists(atPath: url.path)
                    }) { sound in
                        soundRow(
                            sound: .imported(sound.id),
                            label: sound.name,
                            description: "",
                            previewURL: sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
                        )
                    }
                }

                if let importError {
                    Section("Import Error") {
                        Text(importError)
                            .font(.footnote)
                            .foregroundStyle(ThemeManager.shared.colors.destructive)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Alarm Sound")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selectedSound = initialSelection
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { dismiss() }
                    .disabled(false)
                }
            }
        }
        .fileImporter(
            isPresented: $showingDocumentPicker,
            allowedContentTypes: pickerMode == .files ? [.mp3, .audio, .movie] : [.folder],
            allowsMultipleSelection: pickerMode == .files
        ) { result in
            switch result {
            case .success(let urls):
                if pickerMode == .files {
                    guard !urls.isEmpty else {
                        return
                    }
                    for url in urls {
                        Task { await importSound(from: url) }
                    }
                } else {
                    // Folder mode
                    guard let url = urls.first else {
                        return
                    }
                    Task { await importFolder(from: url) }
                }
            case .failure(let error):
                importError = "Picker failed: \(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $showingPlaylistPicker) {
            PlaylistCreatorView(onSave: { name, soundIDs in
                let _ = SoundLibrary.shared.createPlaylist(name: name, soundIDs: soundIDs)
            })
        }
        .sheet(item: $showingPlaylistEditor) { playlist in
            PlaylistEditorView(playlist: playlist, alarms: alarms)
        }
        .onDisappear {
            preview.stop()
        }
    }

    

    private func soundRow(sound: AlarmSound, label: String, description: String, previewURL: URL?) -> some View {
        let isSelected = selectedSound.id == sound.id
        let isPlayingThis = preview.playingSoundID == sound.id
        
        return Button {
            // Selection updates immediately and independently of preview playback.
            selectedSound = sound
        } label: {
            HStack(spacing: 12) {
                // Play/Pause toggle on the left (like playlist editor)
                if let previewURL {
                    Button {
                        if preview.playingSoundID == sound.id {
                            preview.stop()
                        } else {
                            preview.play(url: previewURL, id: sound.id)
                        }
                    } label: {
                        Image(systemName: isPlayingThis ? "pause.circle.fill" : "play.circle")
                            .font(.title3)
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                } else {
                    // Placeholder for sounds without preview (e.g., system default)
                    Image(systemName: "speaker.slash")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .frame(width: 36, height: 36)
                }
                
                VStack(alignment: .leading, spacing: 1) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                    if !description.isEmpty {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    }
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
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .accessibilityLabel("\(label), \(isSelected ? "selected" : description)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func randomPlaylistRow(playlist: Playlist) -> some View {
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
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                } else {
                    Image(systemName: "speaker.slash")
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .frame(width: 36, height: 36)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
        .contextMenu {
            Button {
                showingPlaylistEditor = playlist
            } label: {
                Label("Edit Songs", systemImage: "music.note.list")
            }
        }
    }

    @State private var showingPlaylistEditor: Playlist? = nil

    private func builtInSoundURL(_ builtIn: BuiltInSound) -> URL? {
        let url = SoundPreviewService.bundledSoundURL(for: builtIn.fileName)
        if url == nil {
            return nil
        }
        return url
    }

    private func importSound(from url: URL) async {
        do {
            let sound = try await SoundLibrary.shared.importMP3(from: url)
            importError = nil
            selectedSound = .imported(sound.id)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func importFolder(from url: URL) async {
        do {
            let playlist = try await SoundLibrary.shared.importFolder(from: url)
            importError = nil
            selectedSound = .random(playlist.id)
        } catch {
            importError = error.localizedDescription
        }
    }

    private func timestamp() -> String {
        Date.now.formatted(date: .omitted, time: .standard)
    }
}

struct PlaylistCreatorView: View {
    @Environment(\.dismiss) private var dismiss
    let onSave: (String, [UUID]) -> Void

    @State private var playlistName = ""
    @State private var selectedSoundIDs: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Section("Playlist Name") {
                    TextField("Name", text: $playlistName)
                }

                Section("Select Songs") {
                    ForEach(SoundLibrary.shared.importedSounds) { sound in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sound.name)
                                    .font(.body)
                                    .foregroundStyle(ThemeManager.shared.colors.primaryText)
                                Text("Imported")
                                    .font(.caption)
                                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            }
                            Spacer()
                            if selectedSoundIDs.contains(sound.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ThemeManager.shared.colors.accent)
                                    .font(.title2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedSoundIDs.contains(sound.id) {
                                selectedSoundIDs.remove(sound.id)
                            } else {
                                selectedSoundIDs.insert(sound.id)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Create Playlist")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = playlistName.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty, !selectedSoundIDs.isEmpty else { return }
                        onSave(trimmed, Array(selectedSoundIDs))
                        dismiss()
                    }
                    .disabled(playlistName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedSoundIDs.isEmpty)
                }
            }
        }
    }
}

struct PlaylistEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    let alarms: [AlarmRecord]
    @State private var selectedSoundIDs: Set<UUID>
    @State private var initialSelectedSoundIDs: Set<UUID>
    @State private var showingDeleteConfirmation = false
    @State private var deleteError: String?
    @State private var sortOption: PlaylistSortOption
    @State private var playOrder: PlaylistPlayOrder
    private let previewService = SoundPreviewService.shared

    init(playlist: Playlist, alarms: [AlarmRecord]) {
        self.playlist = playlist
        self.alarms = alarms
        let initial = Set(playlist.selectedSoundIDs)
        self._selectedSoundIDs = State(initialValue: initial)
        self._initialSelectedSoundIDs = State(initialValue: initial)
        self._sortOption = State(initialValue: playlist.sortOption)
        self._playOrder = State(initialValue: playlist.playOrder)
    }

    private var sortedSounds: [ImportedSound] {
        let sounds = playlist.soundIDs.compactMap { soundID in
            SoundLibrary.shared.importedSounds.first(where: { $0.id == soundID })
        }
        switch sortOption {
        case .name:
            return sounds.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .fileSize:
            return sounds.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        case .dateAdded:
            return sounds.sorted { $0.dateAdded > $1.dateAdded }
        case .dateModified:
            return sounds.sorted { $0.fileName > $1.fileName } // fallback to filename for modified
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Playlist Name") {
                    Text(playlist.name)
                        .font(.headline)
                }

                Section {
                    Picker("Play Order", selection: $playOrder) {
                        ForEach(PlaylistPlayOrder.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    
                    Picker("Sort By", selection: $sortOption) {
                        ForEach(PlaylistSortOption.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Songs (\(selectedSoundIDs.count) of \(playlist.soundIDs.count) selected)") {
                    ForEach(sortedSounds, id: \.id) { sound in
                        HStack {
                            // Preview: plays this song; only one at a time
                            Button {
                                if previewService.playingSoundID == sound.fileName {
                                    previewService.stop()
                                } else if let url = sound.localURL(
                                    soundsDirectory: SoundLibrary.shared.soundsDirectory) {
                                    previewService.play(url: url, id: sound.fileName)
                                }
                            } label: {
                                Image(systemName: previewService.playingSoundID == sound.fileName
                                      ? "pause.circle.fill" : "play.circle")
                                    .font(.title3)
                                    .foregroundStyle(ThemeManager.shared.colors.accent)
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sound.name)
                                    .font(.body)
                                    .foregroundStyle(ThemeManager.shared.colors.primaryText)
                                Text(sound.duration.map { String(format: "%.1f seconds", $0) } ?? "Unknown duration")
                                    .font(.caption)
                                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            }
                            Spacer()
                            if selectedSoundIDs.contains(sound.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(ThemeManager.shared.colors.accent)
                                    .font(.title2)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            if selectedSoundIDs.contains(sound.id) {
                                selectedSoundIDs.remove(sound.id)
                            } else {
                                selectedSoundIDs.insert(sound.id)
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        Button("Select All") {
                            selectedSoundIDs = Set(playlist.soundIDs)
                        }
                        .disabled(selectedSoundIDs.count == playlist.soundIDs.count)

                        Spacer()

                        Button("Deselect All") {
                            selectedSoundIDs.removeAll()
                        }
                        .disabled(selectedSoundIDs.isEmpty)
                    }
                }

                Section {
                    Button("Delete Playlist", role: .destructive) {
                        showingDeleteConfirmation = true
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Edit Playlist")
            .onDisappear { previewService.stop() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        selectedSoundIDs = initialSelectedSoundIDs
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var updatedPlaylist = playlist
                        updatedPlaylist.selectedSoundIDs = playlist.soundIDs.filter(selectedSoundIDs.contains)
                        updatedPlaylist.sortOption = sortOption
                        updatedPlaylist.playOrder = playOrder
                        SoundLibrary.shared.updatePlaylist(updatedPlaylist)
                        dismiss()
                    }
                }
            }
            .alert("Delete Playlist", isPresented: $showingDeleteConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Delete", role: .destructive) {
                    if let error = SoundLibrary.shared.deletePlaylist(playlist, referencedBy: alarms) {
                        deleteError = error.localizedDescription
                    } else {
                        dismiss()
                    }
                }
            }
            .alert("Unable to Delete Playlist", isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            )) {
                Button("OK", role: .cancel) { deleteError = nil }
            } message: {
                Text(deleteError ?? "")
            }
        }
    }
}

extension AlarmSound {
    var systemFileName: String? {
        switch self {
        case .systemDefault, .imported, .random, .precomposedPlaylist: nil
        case .builtIn(let name): BuiltInSound.fileName(for: name)
        }
    }
}
