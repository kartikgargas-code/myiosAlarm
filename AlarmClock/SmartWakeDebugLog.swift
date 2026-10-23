import Foundation
import os.log

/// File-based black-box recorder for Smart Wake / takeover / playback events.
/// Written to the App Group container (falls back to Application Support when
/// no group container exists) so it can be shown in the Diagnostics screen on
/// device without a Mac. Capped ring buffer of recent lines.
public enum SmartWakeDebugLog {
    static let fileName = "smart_wake_debug.log"
    static let maxLines = 1000
    static let copyMaxLines = 1000
    private static let queue = DispatchQueue(label: "com.example.alarmclock.smartwakelog")
    private static var inMemoryBuffer: [String] = []
    private static var hasLoggedInterruption = false

    public static func log(_ message: String, force: Bool = false) {
        // Log diet: suppress verbose messages unless forced
        let suppressedPrefixes = [
            "FOREGROUND START attempt: declined",
            "START attempt: declined",
            "FOREGROUND START: silent loop already running",
            "FOREGROUND: loop already running"
        ]
        if !force && suppressedPrefixes.contains(where: message.hasPrefix) {
            return
        }
        
        // Suppress per-id RECONCILE CANCEL lines
        if !force && message.contains("RECONCILE(") && message.contains("CANCEL:") && !message.contains("FAILED") {
            return
        }
        
        // Suppress RECONCILE CANCEL SUCCESS lines
        if !force && message.contains("RECONCILE CANCEL SUCCESS") {
            return
        }
        
        // Suppress duplicate interruption logs
        if message.contains("INTERRUPTION") || message.contains("AVAUDIOSESSION INTERRUPTION") {
            if hasLoggedInterruption {
                return
            }
            hasLoggedInterruption = true
        }
        
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)"
        queue.async {
            var lines: [String] = []
            var wrote = false
            for url in logURLs() {
                let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                var candidate = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                candidate.append(line)
                if candidate.count > maxLines {
                    candidate = Array(candidate.suffix(maxLines))
                }
                let text = candidate.joined(separator: "\n") + "\n"
                // Application Support does not exist in a fresh app container, so the
                // directory has to be made before the write or the write silently fails.
                try? FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                do {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                    lines = candidate
                    wrote = true
                    break
                } catch {
                    continue
                }
            }
            guard wrote else { return }

            // Update in-memory buffer
            inMemoryBuffer = lines
        }
    }
    
    static func logSessionDump(_ message: String) {
        // Only log SESSION DUMP when something failed
        log(message, force: true)
    }

    static func read() -> String? {
        existingLogText()
    }

    static func readFilteredForCopy() -> String? {
        let text = existingLogText() ?? ""
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { !$0.contains("STATE DUMP:") }
            // Return the full filtered buffer (up to copyMaxLines which is now 1000)
        return lines.joined(separator: "\n")
    }
    
    static func clear() {
        queue.sync {
            guard let url = logURL() else { return }
            try? FileManager.default.removeItem(at: url)
            inMemoryBuffer.removeAll()
            hasLoggedInterruption = false
            // Write a marker so the clear is visible
            let marker = "[\(ISO8601DateFormatter().string(from: Date()))] LOG CLEARED BY USER\n"
            try? marker.write(to: url, atomically: true, encoding: .utf8)
        }
    }
    
    /// Returns the most recent BUILD: line from the log, or - when the log has rolled
    /// past it - the build the CI stamped into this bundle.
    static func latestBuildLine() -> String? {
        if let text = existingLogText() {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
                .reversed()
            for line in lines {
                if line.contains("BUILD: ") {
                    // Extract just the BUILD: part
                    if let buildIdx = line.range(of: "BUILD: ") {
                        return String(line[buildIdx.lowerBound...])
                    }
                    return line
                }
            }
        }
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        let stamp = info?["AlarmClockBuildStamp"] as? String ?? "unknown"
        return "BUILD: v\(version) (\(build)) commit=\(stamp)"
    }
    
    static func resetInterruptionLogFlag() {
        hasLoggedInterruption = false
    }

    private static func logURLs() -> [URL] {
        var urls: [URL] = []
        if let groupID = AppGroupResolver.resolve(),
           let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) {
            urls.append(container.appendingPathComponent(fileName))
        }
        let docs = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        if let docs {
            urls.append(docs.appendingPathComponent(fileName))
        }
        return urls
    }

    private static func logURL() -> URL? {
        logURLs().first
    }

    /// The first location that actually holds log lines.
    private static func existingLogText() -> String? {
        for url in logURLs() {
            if let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }
}