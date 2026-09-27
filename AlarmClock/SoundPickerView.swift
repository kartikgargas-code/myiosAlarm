import SwiftUI

struct SoundPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedSound: AlarmSound
    @Binding var showingDocumentPicker: Bool

    var body: some View {
        NavigationStack {
            List {
                Section("Default") {
                    soundRow(
                        sound: .systemDefault,
                        label: "Default",
                        description: "System default alarm sound"
                    )
                }

                Section("Built-in Sounds") {
                    ForEach(BuiltInSound.allCases, id: \.self) { builtIn in
                        soundRow(
                            sound: .builtIn(builtIn.rawValue),
                            label: builtIn.rawValue,
                            description: "Built-in alarm sound"
                        )
                    }
                }

                Section("Imported") {
                    ForEach(SoundLibrary.shared.importedSounds) { sound in
                        soundRow(
                            sound: .imported(sound.id),
                            label: sound.name,
                            description: "Imported from Files"
                        )
                    }

                    Button {
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
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Alarm Sound")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func soundRow(sound: AlarmSound, label: String, description: String) -> some View {
        Button {
            selectedSound = sound
            dismiss()
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
                if selectedSound.id == sound.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ThemeManager.shared.colors.accent)
                        .font(.title2)
                }
            }
        }
        .buttonStyle(.plain)
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
}