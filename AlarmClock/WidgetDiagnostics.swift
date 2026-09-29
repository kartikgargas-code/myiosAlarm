import Foundation
import os.log

/// Shared diagnostic logging for the next alarm widget pipeline
/// Uses os.log with stable subsystem and category for device log filtering
public enum WidgetDiagnostics {
    public static let subsystem = "com.example.alarmclock.widget-diagnostics"
    public static let appLog = OSLog(subsystem: subsystem, category: "app")
    public static let widgetLog = OSLog(subsystem: subsystem, category: "widget")
    
    /// App-side diagnostic event
    public static func appLogEvent(
        _ message: String,
        appGroupIdentifier: String? = nil,
        containerAvailable: Bool? = nil,
        fileExists: Bool? = nil,
        fileSize: Int? = nil,
        fileModificationDate: Date? = nil,
        writeSuccess: Bool? = nil,
        writeError: String? = nil,
        snapshotAlarmID: UUID? = nil,
        snapshotLabel: String? = nil,
        snapshotNextOccurrence: Date? = nil,
        snapshotIsEnabled: Bool? = nil,
        widgetReloadRequested: Bool? = nil
    ) {
        var parts = ["MYNEXTALARM_APP_DIAG: \(message)"]
        if let appGroupIdentifier { parts.append("appGroup=\(appGroupIdentifier)") }
        if let containerAvailable { parts.append("containerAvailable=\(containerAvailable)") }
        if let fileExists { parts.append("fileExists=\(fileExists)") }
        if let fileSize { parts.append("fileSize=\(fileSize)") }
        if let fileModificationDate { parts.append("fileModDate=\(ISO8601DateFormatter().string(from: fileModificationDate))") }
        if let writeSuccess { parts.append("writeSuccess=\(writeSuccess)") }
        if let writeError { parts.append("writeError=\(writeError)") }
        if let snapshotAlarmID { parts.append("snapshotAlarmID=\(snapshotAlarmID)") }
        if let snapshotLabel { parts.append("snapshotLabel=\(snapshotLabel)") }
        if let snapshotNextOccurrence { parts.append("snapshotNextOccurrence=\(ISO8601DateFormatter().string(from: snapshotNextOccurrence))") }
        if let snapshotIsEnabled { parts.append("snapshotIsEnabled=\(snapshotIsEnabled)") }
        if let widgetReloadRequested { parts.append("widgetReloadRequested=\(widgetReloadRequested)") }
        
        os_log("%{public}@", log: appLog, type: .default, parts.joined(separator: " | "))
    }
    
    /// Widget-side diagnostic event
    public static func widgetLogEvent(
        _ message: String,
        appGroupIdentifier: String? = nil,
        containerAvailable: Bool? = nil,
        fileExists: Bool? = nil,
        readSuccess: Bool? = nil,
        readError: String? = nil,
        decodeSuccess: Bool? = nil,
        decodeError: String? = nil,
        snapshotAlarmID: UUID? = nil,
        snapshotLabel: String? = nil,
        snapshotNextOccurrence: Date? = nil,
        snapshotIsEnabled: Bool? = nil,
        entryHasAlarm: Bool? = nil
    ) {
        var parts = ["MYNEXTALARM_WIDGET_DIAG: \(message)"]
        if let appGroupIdentifier { parts.append("appGroup=\(appGroupIdentifier)") }
        if let containerAvailable { parts.append("containerAvailable=\(containerAvailable)") }
        if let fileExists { parts.append("fileExists=\(fileExists)") }
        if let readSuccess { parts.append("readSuccess=\(readSuccess)") }
        if let readError { parts.append("readError=\(readError)") }
        if let decodeSuccess { parts.append("decodeSuccess=\(decodeSuccess)") }
        if let decodeError { parts.append("decodeError=\(decodeError)") }
        if let snapshotAlarmID { parts.append("snapshotAlarmID=\(snapshotAlarmID)") }
        if let snapshotLabel { parts.append("snapshotLabel=\(snapshotLabel)") }
        if let snapshotNextOccurrence { parts.append("snapshotNextOccurrence=\(ISO8601DateFormatter().string(from: snapshotNextOccurrence))") }
        if let snapshotIsEnabled { parts.append("snapshotIsEnabled=\(snapshotIsEnabled)") }
        if let entryHasAlarm { parts.append("entryHasAlarm=\(entryHasAlarm)") }
        
        os_log("%{public}@", log: widgetLog, type: .default, parts.joined(separator: " | "))
    }
}