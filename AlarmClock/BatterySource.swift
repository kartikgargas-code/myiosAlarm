import Foundation
import UIKit
import AlarmClockShared

/// Shared battery source for both app and widget targets.
/// Priority: LIVE read first, then cache if live is invalid or cache is older than 10 minutes.
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
    /// Performs a LIVE read first. Falls back to cache only if live read is invalid
    /// (returns -1/0) OR the cache is fresh (< 10 min). If cache is > 10 min but < 30 min,
    /// use it but mark as stale. If cache > 30 min, return nil.
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
        
        if let level = ownRead {
            // Live read succeeded - use it
            return Reading(level: level, source: .live, cacheAgeSeconds: cacheAge)
        }
        
        // Live read failed (-1 or 0) - check if we have a fresh cache (< 10 min)
        if appLevelIsFresh, let level = appLevel {
            return Reading(level: level, source: .cache(ageSeconds: cacheAge ?? 0), cacheAgeSeconds: cacheAge)
        }
        
        // Live read failed and cache not fresh - check if we have a stale cache (10-30 min)
        if let level = appLevel, let age = cacheAge {
            if age <= maxStaleCacheAge {
                // Cache is stale (10-30 min) but not ancient - use it but mark as stale
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