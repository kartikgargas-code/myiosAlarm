import Foundation

public struct AlarmStoreSnapshot: Codable, Equatable {
    public var alarms: [AlarmRecord]
    public var playlists: [Playlist]
    public var managedSystemAlarmIDs: Set<UUID>
    public var playHistory: [PlayHistoryEntry]

    public static let empty = AlarmStoreSnapshot(alarms: [], playlists: [], managedSystemAlarmIDs: [], playHistory: [])
}

public protocol AlarmPersisting {
    func load() throws -> AlarmStoreSnapshot
    func save(_ snapshot: AlarmStoreSnapshot) throws
}

/// One queued Control Center widget action, written by the widget extension to
/// the App Group and applied by the app (the only AlarmKit-authorized party).
/// The app consumes the file (deletes it) BEFORE applying — a re-apply would
/// double-mutate the schedule.
public struct PendingWidgetAction: Codable, Equatable {
    public let action: String
    public let alarmID: UUID
    public let requestedAt: Date

    public init(action: String, alarmID: UUID, requestedAt: Date) {
        self.action = action
        self.alarmID = alarmID
        self.requestedAt = requestedAt
    }

    public static let fileName = "pendingWidgetAction.json"
    public static let skip = "skip"
    public static let adjustEarlier = "adjust-10"
    public static let adjustLater = "adjust+10"
}

public enum AlarmPersistenceError: LocalizedError {
    case decodeFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case let .decodeFailed(fileName, detail):
            "Could not read \(fileName): \(detail)"
        }
    }
}

public struct JSONAlarmPersistence: AlarmPersisting {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = directory.appendingPathComponent("alarms.json")
        }
    }

    public func load() throws -> AlarmStoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        do {
            return try JSONDecoder.alarmDecoder.decode(AlarmStoreSnapshot.self, from: Data(contentsOf: fileURL))
        } catch {
            // Never destroy persisted data on a decode failure: the file is the
            // only copy of the user's alarms. Surface the failure; recovery is
            // a data problem, not a reason to wipe.
            throw AlarmPersistenceError.decodeFailed(fileURL.lastPathComponent, error.localizedDescription)
        }
    }

    public func save(_ snapshot: AlarmStoreSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.alarmEncoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
    }
}

extension JSONEncoder {
    static var alarmEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var alarmDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
