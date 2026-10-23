import Foundation

/// Resolves the App Group identifier at runtime. AltStore/SideStore resign the
/// entitlement group by RENAMING it (usually by adding the team ID), so a hardcoded
/// group name returns a nil container on device.
///
/// The renaming scheme is not ours to predict, so nothing is guessed from the shape of
/// a name: every candidate is probed with `containerURL(forSecurityApplicationGroupIdentifier:)`
/// and the first one the phone actually grants a container for wins.
public enum AppGroupResolver {
    public static let productionFallback = "group.com.example.alarmclock"

    /// The name project.yml configured for this bundle, whether or not it works.
    public static var configuredIdentifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String)
            ?? productionFallback
    }

    /// Every identifier worth trying, most likely first.
    public static func candidates() -> [String] {
        let configured = configuredIdentifier
        let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []

        var list: [String] = []
        if let match = resigned.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            list.append(match)
        }
        // Then EVERY resigned group, whatever it is called.
        list.append(contentsOf: resigned)
        list.append(configured)

        var seen = Set<String>()
        return list.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The first candidate the phone grants a container for, or nil if there is none.
    public static func resolve() -> String? {
        candidates().first {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) != nil
        }
    }

    /// One line for the on-device Diagnostics screen.
    public static func describe() -> String {
        let configured = configuredIdentifier
        let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        let chosen = resolve() ?? "none"
        return "configured=" + configured
            + " altGroups=" + (resigned.isEmpty ? "none" : resigned.joined(separator: ","))
            + " chosen=" + chosen
    }
}
