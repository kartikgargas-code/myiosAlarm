import Foundation

/// Resolves the App Group identifier at runtime. AltStore/SideStore resign the
/// entitlement group by appending the team ID (e.g. "group.x.99H28SAAJ4"), so a
/// hardcoded group name returns a nil container on device. Resolution order:
/// 1. Info.plist "AlarmClockAppGroupIdentifier" matched exactly or as prefix in
///    the resigned ALTAppGroups list (AltStore injects ALTAppGroups into Info.plist)
/// 2. Configured group used directly (Xcode builds / TestFlight keep the original name)
/// 3. nil -> caller must handle a missing shared container gracefully
enum AppGroupResolver {
    static let productionFallback = "group.com.example.alarmclock"

    static func resolve() -> String? {
        // project.yml injects this key per configuration ($(APP_GROUP_IDENTIFIER)),
        // so diagnostic builds naturally resolve the diagnostic group. Works in
        // both processes: Bundle.main is the app bundle in-app and the widget
        // bundle in the extension (both plists carry the key).
        let configured = (Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String)
            ?? productionFallback
        let resignedGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []

        if let match = resignedGroups.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            return match
        }
        // Fall back to the configured name only if a container actually exists for it
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: configured) != nil {
            return configured
        }
        return nil
    }
}
