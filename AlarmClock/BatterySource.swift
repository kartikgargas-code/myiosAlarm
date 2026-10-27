import Foundation
import UIKit

/// Shared battery source for both app and widget targets.
/// Priority: app-written cached value if under 600s old, otherwise a live read.
public enum BatterySource {
    private static let appLevelKey = "appBatteryLevel"
    private static let appLevelAtKey = "appBatteryLevelAt"
    private static let freshnessInterval: TimeInterval = 600  // 10 minutes

    /// Returns the current battery level (0.0-1.0) or nil if unavailable.
    /// Reads the app's cached value if fresh (< 600s), otherwise performs a live read.
    public static func current() -> Double? {
        let defaults = UserDefaults(suiteName: AppGroupResolver.resolve() ?? AppGroupResolver.productionFallback) ?? .standard
        
        let appLevel = defaults.object(forKey: appLevelKey) as? Double
        let appLevelAt = defaults.object(forKey: appLevelAtKey) as? Double
        let appLevelIsFresh = appLevelAt.map { Date().timeIntervalSince1970 - $0 < freshnessInterval } ?? false
        
        let ownRead = readBatteryLevel()
        return (appLevelIsFresh ? appLevel : nil) ?? ownRead ?? appLevel
    }

    private static func readBatteryLevel() -> Double? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }
}