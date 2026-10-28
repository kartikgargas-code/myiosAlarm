import SwiftUI
import AlarmClockShared
import UIKit

/// History screen showing songs that finished playing during alarm rings
struct HistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var coordinator: AlarmCoordinator
    @State private var showingClearAllConfirmation = false
    @State private var toastMessage: String? = nil
    @State private var toastTask: Task<Void, Never>? = nil
    
    init(coordinator: AlarmCoordinator) {
        _coordinator = State(initialValue: coordinator)
    }
    
    private func showToast(_ message: String) {
        SmartWakeDebugLog.log("HISTORY TOAST: showing message=\(message)")
        toastTask?.cancel()
        withAnimation { toastMessage = message }
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()
        toastTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if !Task.isCancelled {
                await MainActor.run {
                    SmartWakeDebugLog.log("HISTORY TOAST: clearing message")
                    withAnimation { toastMessage = nil }
                }
            }
        }
    }
    
    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        showToast("Copied")
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
            .onAppear {
                SmartWakeDebugLog.log("HISTORY VIEW: built with \(coordinator.playHistory.count) entries")
            }
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
            .navigationTitle("Play History")
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [
                        .icon("Clear All", systemImage: "trash", destructive: true) {
                            showingClearAllConfirmation = true
                        }
                    ],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
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
            // Delete + Song confirmation dialog
            .alert("Delete Song File", isPresented: $coordinator.showingDeleteWithSoundConfirmation, presenting: coordinator.pendingDeletePlaylists) { playlists in
                Button("Cancel", role: .cancel) {
                    coordinator.cancelDeleteSoundFile()
                }
                Button("Delete Song", role: .destructive) {
                    coordinator.confirmDeleteSoundFile()
                }
            } message: { _ in
                Text("Delete this song?")
            }
            .overlay(alignment: .bottom) {
                if let toastMessage {
                    Text(toastMessage)
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
                            // Single Delete action - confirmation dialog handles song deletion
                            coordinator.deleteHistoryEntry(id: entry.id, deleteSoundFile: entry.soundID != nil)
                        } label: {
                            Label("Delete", systemImage: "trash")
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
                    // Song name - long press to copy
                    Text(entry.songName)
                        .font(.body)
                        .foregroundStyle(colors.primaryText)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            copyToClipboard(entry.songName)
                        }
                    
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
        .overlay(alignment: .bottom) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.callout)
                    .foregroundStyle(colors.primaryText)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(colors.card.opacity(0.95))
                    .clipShape(Capsule())
                    .shadow(radius: 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 100)
            }
        }
    }
}

#Preview {
    let coordinator = AlarmCoordinator()
    HistoryView(coordinator: coordinator)
        .preferredColorScheme(.dark)
}