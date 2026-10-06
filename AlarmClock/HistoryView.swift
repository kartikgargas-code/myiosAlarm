import SwiftUI
import AlarmClockShared

/// History screen showing songs that finished playing during alarm rings
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: AlarmCoordinator
    @State private var showingClearAllConfirmation = false
    @State private var showingDeleteSoundConfirmation = false
    @State private var entryToDeleteWithSound: PlayHistoryEntry?
    
    init(coordinator: AlarmCoordinator) {
        _coordinator = State(initialValue: coordinator)
    }
    
    var body: some View {
        NavigationStack {
            Group {
                if coordinator.playHistory.isEmpty {
                    emptyState
                } else {
                    historyList
                }
            }
            .navigationTitle("Play History")
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                if !coordinator.playHistory.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Clear All") {
                            showingClearAllConfirmation = true
                        }
                        .foregroundStyle(ThemeManager.shared.colors.destructive)
                    }
                }
            }
            .confirmationDialog("Clear All History", isPresented: $showingClearAllConfirmation, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) {
                    coordinator.clearAllHistory(deleteSoundFiles: false)
                }
                Button("Clear All + Delete Song Files", role: .destructive) {
                    coordinator.clearAllHistory(deleteSoundFiles: true)
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all history entries. Optionally also delete the song files from the app (only if not used by any alarm or playlist).")
            }
            .alert("Cannot Delete Song File", isPresented: $showingDeleteSoundConfirmation, presenting: entryToDeleteWithSound) { entry in
                Button("OK", role: .cancel) {}
            } message: { entry in
                Text("This song is still used by an alarm or playlist. Only the history entry will be deleted.")
            }
        }
    }
    
    private var emptyState: some View {
        let colors = ThemeManager.shared.colors
        
        return ContentUnavailableView {
            Label("No Play History", systemImage: "music.note.list")
        } description: {
            Text("Songs that finish playing during alarms will appear here")
        }
        .scrollContentBackground(.hidden)
        .background(colors.background)
    }
    
    private var historyList: some View {
        let colors = ThemeManager.shared.colors
        
        return List {
            ForEach(coordinator.playHistory) { entry in
                historyRow(entry)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            coordinator.deleteHistoryEntry(id: entry.id, deleteSoundFile: false)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        if entry.soundID != nil {
                            Button(role: .destructive) {
                                coordinator.deleteHistoryEntry(id: entry.id, deleteSoundFile: true)
                                if coordinator.lastError?.contains("still referenced") == true {
                                    entryToDeleteWithSound = entry
                                    showingDeleteSoundConfirmation = true
                                    coordinator.lastError = nil
                                }
                            } label: {
                                Label("Delete + Song", systemImage: "trash.fill")
                            }
                            .tint(.orange)
                        }
                    }
            }
        }
    }
    
    private func historyRow(_ entry: PlayHistoryEntry) -> some View {
        let colors = ThemeManager.shared.colors
        
        return Button {
            coordinator.playHistoryEntry(entry)
        } label: {
            HStack(spacing: 16) {
                // Song icon
                Image(systemName: "music.note")
                    .font(.title2)
                    .foregroundStyle(colors.accent)
                    .frame(width: 44, height: 44)
                    .background(colors.accent.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                
                VStack(alignment: .leading, spacing: 4) {
                    // Song name
                    Text(entry.songName)
                        .font(.body)
                        .foregroundStyle(colors.primaryText)
                        .lineLimit(1)
                    
                    // Alarm name and timestamp
                    HStack(spacing: 8) {
                        Text(entry.alarmDisplayName)
                            .font(.caption)
                            .foregroundStyle(colors.secondaryText)
                        
                        Text("•")
                            .font(.caption)
                            .foregroundStyle(colors.secondaryText)
                        
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(colors.secondaryText)
                    }
                }
                
                Spacer()
                
                // Play indicator
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(colors.accent)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(colors.card)
        .listRowSeparator(.visible)
        .listRowSeparatorTint(colors.divider)
    }
}

#Preview {
    let coordinator = AlarmCoordinator()
    HistoryView(coordinator: coordinator)
        .preferredColorScheme(.dark)
}