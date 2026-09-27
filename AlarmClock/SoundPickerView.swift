import SwiftUI
import UniformTypeIdentifiers

struct SoundPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedSound: AlarmSound

    @State private var showingDocumentPicker = false
    @State private var importError: String?
    @State private var importStatus: String?
    @State private var pickerEventLog: [String] = []

    private let preview = SoundPreviewService.shared

    var body: some View {
        NavigationStack {
            List {
                diagnosticsSection

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

                Section("Imported") {
                    ForEach(SoundLibrary.shared.importedSounds) { sound in
                        soundRow(
                            sound: .imported(sound.id),
                            label: sound.name,
                            description: "Imported from Files",
                            previewURL: sound.localURL(soundsDirectory: SoundLibrary.shared.soundsDirectory)
                        )
                    }

                    Button {
                        pickerEventLog.append("[\(timestamp())] Import button tapped")
                        showingDocumentPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                            Text("Import MP3 from Files")
                                .foregroundStyle(ThemeManager.shared.colors.accent)
                        }
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
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showingDocumentPicker,
                allowedContentTypes: [.mp3, .audio, .movie],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else {
                        pickerEventLog.append("[\(timestamp())] Picker returned no file")
                        return
                    }
                    pickerEventLog.append("[\(timestamp())] File selected: \(url.lastPathComponent)")
                    Task { await importSound(from: url) }
                case .failure(let error):
                    pickerEventLog.append("[\(timestamp())] Picker failed: \(error.localizedDescription)")
                    importError = "Files picker failed: \(error.localizedDescription)"
                }
            }
            .onDisappear {
                preview.stop()
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("Import Diagnostics") {
            Text("Import status: \(importStatus ?? (importError == nil ? "none yet" : "failed"))")
            if let importError {
                Text(importError)
                    .foregroundStyle(ThemeManager.shared.colors.destructive)
            }
            ForEach(Array(pickerEventLog.suffix(6).enumerated().reversed()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption2.monospaced())
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
        }
        .font(.caption)
    }

    private func soundRow(sound: AlarmSound, label: String, description: String, previewURL: URL?) -> some View {
        let isSelected = selectedSound.id == sound.id
        return Button {
            // Selection updates immediately and independently of preview playback.
            selectedSound = sound
            if let previewURL {
                preview.play(url: previewURL, id: sound.id)
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.body)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }
                Spacer()
                if preview.playingSoundID == sound.id {
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
        .accessibilityLabel("\(label), \(isSelected ? "selected" : description)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func builtInSoundURL(_ builtIn: BuiltInSound) -> URL? {
        let url = SoundPreviewService.bundledSoundURL(for: builtIn.fileName)
        if url == nil, !pickerEventLog.contains(where: { $0.contains(builtIn.fileName) }) {
            pickerEventLog.append("[\(timestamp())] Missing bundled resource: \(builtIn.fileName)")
        }
        return url
    }

    private func importSound(from url: URL) async {
        do {
            let sound = try await SoundLibrary.shared.importMP3(from: url)
            pickerEventLog.append("[\(timestamp())] Import succeeded: \(sound.fileName)")
            importStatus = "Imported \(sound.name)"
            importError = nil
            selectedSound = .imported(sound.id)
        } catch {
            pickerEventLog.append("[\(timestamp())] Import failed: \(error.localizedDescription)")
            importError = error.localizedDescription
            importStatus = nil
        }
    }

    private func timestamp() -> String {
        Date.now.formatted(date: .omitted, time: .standard)
    }
}

enum BuiltInSound: String, CaseIterable {
    case classicBell = "Classic Bell"
    case digital = "Digital"
    case gentleWake = "Gentle Wake"
    case morning = "Morning"
    case pulse = "Pulse"
    case chime = "Chime"
    case soft = "Soft"
    case bright = "Bright"

    var fileName: String {
        switch self {
        case .classicBell: "classic-bell.wav"
        case .digital: "digital.wav"
        case .gentleWake: "gentle-wake.wav"
        case .morning: "morning.wav"
        case .pulse: "pulse.wav"
        case .chime: "chime.wav"
        case .soft: "soft.wav"
        case .bright: "bright.wav"
        }
    }

    static func fileName(for displayName: String) -> String? {
        allCases.first { $0.rawValue == displayName }?.fileName
    }
}