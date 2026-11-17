import SwiftUI

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var sections: [(title: String, icon: String, color: Color, points: [String])] {
        [
            ("What this app does", "alarm.fill", .orange, [
                "myNextAlarm wakes you with music from your own playlists.",
                "A backup system alarm is scheduled so you are not left in silence if music does not start."
            ]),
            ("Alarms", "clock.fill", .blue, [
                "Choose a sound or playlist, set loudness and fade-in, choose a snooze time, change alarm time without changing actual time and skip the next alarm.",
                "You can also set vibration, how long sound plays, and whether it loops. The lock-screen Stop control ends the alarm."
            ]),
            ("Sounds", "music.note.list", .pink, [
                "Make playlists, import music files or folders, and add songs to a playlist.",
                "Songs are linked from their original files rather than copied. Deleting a playlist keeps its songs.",
                "Choose random or sequential play order, and sort songs by name, file size, date added, or date modified.",
                "Built-in sounds include Classic Bell, Digital, Gentle Wake, Morning, Pulse, Chime, Soft, and Bright."
            ]),
            ("Smart Wake", "waveform", .purple, [
                "Smart Wake keeps a quiet audio loop running overnight so the app can start your playlist at alarm time.",
                "For playlist alarms, a backup system alarm is scheduled 30 seconds later in case music has not started."
            ]),
            ("Clock and appearance", "paintbrush", .teal, [
                "Choose a theme, text size, compact alarm list, and the look of alarm buttons and cards.",
                "The full-screen clock has animated seconds, adjustable animation, custom number and screen colours, and an optional colour cycle."
            ]),
            ("Widgets and controls", "square.grid.2x2", .indigo, [
                "The Lock Screen Next Alarm widget shows the next alarm and its time in inline, round, or rectangular styles. The Battery widget shows battery level on the Lock Screen or Home Screen; the round Memory widget shows memory in use on the Lock Screen.",
                "A Next Alarm Lock Screen control skips the next occurrence. Control Center buttons skip it or move it 10 minutes earlier or later.",
                "The Next Alarm Live Activity shows the upcoming alarm and offers Skip or Undo, time adjustments, and Reset."
            ]),
            ("Play History", "clock.arrow.circlepath", .blue, [
                "Songs that finish playing during alarms appear in Play History.",
                "You can clear history, and choose whether to delete its song files when clearing all entries."
            ]),
            ("Backup", "externaldrive", .green, [
                "Export and import saves alarms, playlists, sound details, themes, and appearance, clock, widget, and button settings.",
                "Music files are not included. After reinstalling the app, import your songs again to reconnect them to playlists."
            ]),
            ("Memory", "memorychip", .gray, [
                "Clear memory removes cached alarm audio that is no longer needed. It does not delete your playlists or song files."
            ]),
            ("Hidden gestures and tips", "hand.tap", .orange, [
                "Alarm list: long-press an alarm for skip or undo skip, time adjustments, duplicate, custom time, and delete. Swipe an alarm to delete it.",
                "Long-press the plus button on the alarm list to switch between Compact and Extended layouts.",
                "Sounds: long-press a song name to copy it. Swipe a song to delete it. Long-press a playlist for Delete Playlist; swipe it to delete it. The sort menu also has Delete All Tracks and folder delete actions.",
                "In the alarm sound picker, long-press a playlist to edit its songs. In Appearance, long-press a saved theme to edit, duplicate, or delete it; swipe it to edit or delete it.",
                "Play History: long-press a song name to copy it; swipe an entry to delete it. Deleting an entry can also delete its song file after confirmation."
            ])
        ]
    }

    var body: some View {
        let colors = ThemeManager.shared.colors

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("myNextAlarm")
                            .font(.largeTitle.bold())
                            .foregroundStyle(colors.primaryText)
                        Text("Wake up to the music you choose.")
                            .font(.body)
                            .foregroundStyle(colors.secondaryText)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(colors.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    ForEach(sections.indices, id: \.self) { index in
                        sectionCard(sections[index], colors: colors)
                    }
                }
                .padding(16)
            }
            .scrollContentBackground(.hidden)
            .background(colors.background)
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
            .navigationTitle("About")
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
            }
        }
    }

    private func sectionCard(
        _ section: (title: String, icon: String, color: Color, points: [String]),
        colors: ThemeColors
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: section.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(section.color)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(section.title)
                    .font(.headline)
                    .foregroundStyle(colors.primaryText)
            }

            ForEach(section.points, id: \.self) { point in
                HStack(alignment: .top, spacing: 8) {
                    Text("•")
                        .foregroundStyle(colors.accent)
                    Text(point)
                        .foregroundStyle(colors.primaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.subheadline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(colors.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
