import Foundation
import UIKit
import AlarmClockShared

/// Shared battery source for both app and widget targets.
/// Priority: app-written cached value if under 600s old, otherwise a live read.
public enum BatterySource {
    private static let appLevelKey = "appBatteryLevel"
    private static let appLevelAtKey = "appBatteryLevelAt"
    private static let freshnessInterval: TimeInterval = 600  // 10 minutes
    private static let maxStaleCacheAge: TimeInterval = 1800  // 30 minutes - never show older as fresh

    /// Source of the battery reading
    public enum Source {
        case cache(ageSeconds: TimeInterval)   // app's cached value, with age
        case live                              // live UIDevice read
        case staleCache(ageSeconds: TimeInterval)  // cache older than 30 min, used only when live unavailable
        case unknown
    }

    /// Detailed battery reading with source info
    public struct Reading {
        public let level: Double?
        public let source: Source
        public let cacheAgeSeconds: TimeInterval?
    }

    /// Returns the current battery level (0.0-1.0) or nil if unavailable.
    /// Reads the app's cached value if fresh (< 600s), otherwise performs a live read.
    public static func current() -> Double? {
        currentDetailed().level
    }

    /// Returns detailed reading with source info for logging
    public static func currentDetailed() -> Reading {
        let defaults = UserDefaults(suiteName: AppGroupResolver.resolve() ?? AppGroupResolver.productionFallback) ?? .standard
        
        let appLevel = defaults.object(forKey: appLevelKey) as? Double
        let appLevelAt = defaults.object(forKey: appLevelAtKey) as? Double
        let now = Date().timeIntervalSince1970
        let cacheAge = appLevelAt.map { now - $0 }
        let appLevelIsFresh = cacheAge.map { $0 < freshnessInterval } ?? false
        
        let ownRead = readBatteryLevel()
        
        if appLevelIsFresh, let level = appLevel {
            return Reading(level: level, source: .cache(ageSeconds: cacheAge ?? 0), cacheAgeSeconds: cacheAge)
        }
        
        if let level = ownRead {
            return Reading(level: level, source: .live, cacheAgeSeconds: cacheAge)
        }
        
        // Live read failed (-1 or 0) - check if we have a cache, even if stale
        if let level = appLevel, let age = cacheAge {
            if age <= maxStaleCacheAge {
                // Cache is stale but not ancient - use it but mark as stale
                return Reading(level: level, source: .staleCache(ageSeconds: age), cacheAgeSeconds: age)
            } else {
                // Cache is older than 30 minutes - don't use it
                return Reading(level: nil, source: .unknown, cacheAgeSeconds: age)
            }
        }
        
        return Reading(level: nil, source: .unknown, cacheAgeSeconds: cacheAge)
    }

    private static func readBatteryLevel() -> Double? {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let level = UIDevice.current.batteryLevel
        return level >= 0 ? Double(level) : nil
    }
}