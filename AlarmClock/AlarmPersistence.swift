import Foundation

struct AlarmStoreSnapshot: Codable, Equatable {
    var alarms: [AlarmRecord]
    var playlists: [Playlist]
    var managedSystemAlarmIDs: Set<UUID>

    static let empty = AlarmStoreSnapshot(alarms: [], playlists: [], managedSystemAlarmIDs: [])
}

protocol AlarmPersisting {
    func load() throws -> AlarmStoreSnapshot
    func save(_ snapshot: AlarmStoreSnapshot) throws
}

struct JSONAlarmPersistence: AlarmPersisting {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = directory.appendingPathComponent("alarms.json")
        }
    }

    func load() throws -> AlarmStoreSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .empty }
        return try JSONDecoder.alarmDecoder.decode(AlarmStoreSnapshot.self, from: Data(contentsOf: fileURL))
    }

    func save(_ snapshot: AlarmStoreSnapshot) throws {
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
