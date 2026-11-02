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
    func toggle(_ id: String, parent: String? = nil) {
        var set = expandedIds
        let wasOpen = set.contains(id)
        if wasOpen {
            set.remove(id)
        } else {
            set.insert(id)
        }
        let parentStr = parent ?? "none"
        os_log(.info, log: log, "SECTION toggle id=%{public}s parent=%{public}s wasOpen=%{public}d nowOpen=%{public}d openSet=%{public}s",
               id, parentStr, wasOpen, !wasOpen, Array(set).sorted().joined(separator: ","))
        let oldSet = expandedIds
        expandedIds = set
        saveToStorage(oldSet: oldSet, newSet: set, reason: "toggle_\(id)")
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
    private func saveToStorage(oldSet: Set<String>? = nil, newSet: Set<String>? = nil, reason: String) {
        let encoded = (try? JSONEncoder().encode(expandedIds)) ?? Data()
        UserDefaults.standard.set(encoded, forKey: storageKey)
        let old = oldSet ?? expandedIds
        let new = newSet ?? expandedIds
        if old != new {
            os_log(.info, log: log, "SECTION set changed old=%{public}s new=%{public}s reason=%{public}s",
                   Array(old).sorted().joined(separator: ","),
                   Array(new).sorted().joined(separator: ","),
                   reason)
        }
    }
    
    /// Seed the set with default expanded sections (called once on first appear)
    func seedIfEmpty(ids: [String]) {
        guard expandedIds.isEmpty, !ids.isEmpty else { return }
        let oldSet = expandedIds
        let seed = Set(ids)
        expandedIds = seed
        saveToStorage(oldSet: oldSet, newSet: seed, reason: "seedDefault")
    }
}