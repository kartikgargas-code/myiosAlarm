import Foundation
import SwiftUI
import os.log

/// Shared observable object for Sounds UI state (expanded folders)
/// Created once at app level and injected as environment object
@MainActor
final class SoundsUIState: ObservableObject {
    private let log = OSLog(subsystem: "com.example.alarmclock", category: "SoundsUIState")
    private let storageKey = "soundsExpandedSections"
    
    @Published private(set) var expandedIds: Set<String> = []
    
    init() {
        loadFromStorage()
    }
    
    /// Check if a section is expanded
    func isExpanded(_ id: String) -> Bool {
        expandedIds.contains(id)
    }
    
    /// Toggle a section's expanded state
    func toggle(_ id: String) {
        var set = expandedIds
        let wasOpen = set.contains(id)
        if wasOpen {
            set.remove(id)
        } else {
            set.insert(id)
        }
        os_log(.info, log: log, "SECTION toggle id=%{public}s parent=none wasOpen=%{public}d nowOpen=%{public}d openSet=%{public}s",
               id, wasOpen, !wasOpen, Array(set).sorted().joined(separator: ","))
        expandedIds = set
        saveToStorage()
    }
    
    /// Load from UserDefaults with safe fallback
    private func loadFromStorage() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            os_log(.info, log: log, "SECTION set changed old=[] new=%{public}s reason=loadFromStorage",
                   Array(decoded).sorted().joined(separator: ","))
            expandedIds = decoded
        } else {
            os_log(.info, log: log, "SECTION set changed old=[] new=[] reason=loadFromStorage (empty/bad data)")
            expandedIds = []
        }
    }
    
    /// Save to UserDefaults
    private func saveToStorage() {
        let encoded = (try? JSONEncoder().encode(expandedIds)) ?? Data()
        UserDefaults.standard.set(encoded, forKey: storageKey)
    }
    
    /// Seed the set with default expanded sections (called once on first appear)
    func seedIfEmpty(ids: [String]) {
        guard expandedIds.isEmpty, !ids.isEmpty else { return }
        let seed = Set(ids)
        os_log(.info, log: log, "SECTION set changed old=[] new=%{public}s reason=seedDefault",
               Array(seed).sorted().joined(separator: ","))
        expandedIds = seed
        saveToStorage()
    }
}