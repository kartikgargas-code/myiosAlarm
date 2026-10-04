import Foundation
import os.log

/// File-based black-box recorder for Smart Wake / takeover / playback events.
/// Written to the App Group container (falls back to Application Support when
/// no group container exists) so it can be shown in the Diagnostics screen on
/// device without a Mac. Capped ring buffer of recent lines.
enum SmartWakeDebugLog {
    static let fileName = "smart_wake_debug.log"
    static let maxLines = 300
    private static let queue = DispatchQueue(label: "com.example.alarmclock.smartwakelog")
    private static var inMemoryBuffer: [String] = []

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        queue.async {
            guard let url = logURL() else { return }
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            var lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            lines.append(line)
            if lines.count > maxLines {
                lines = Array(lines.suffix(maxLines))
            }
            let text = lines.joined(separator: "\n") + "\n"
            try? text.write(to: url, atomically: true, encoding: .utf8)
            
            // Update in-memory buffer
            inMemoryBuffer = lines
        }
    }

    static func read() -> String? {
        guard let url = logURL() else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func readFilteredForCopy() -> String? {
        guard let url = logURL() else { return nil }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.contains("STATE DUMP:") }
            .suffix(150)
        return lines.joined(separator: "\n")
    }

    static func clear() {
        queue.async {
            guard let url = logURL() else { return }
            try? FileManager.default.removeItem(at: url)
            inMemoryBuffer.removeAll()
        }
    }

    private static func logURL() -> URL? {
        if let groupID = AppGroupResolver.resolve(),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            return container.appendingPathComponent(fileName)
        }
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        return docs?.appendingPathComponent(fileName)
    }
}
