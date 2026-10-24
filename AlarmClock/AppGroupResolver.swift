import Foundation

/// Resolves the App Group identifier at runtime. A re-signing tool RENAMES every App Group to
/// `<group>.<TEAMID>`, so the build-time name is never granted and `containerURL` returns nil
/// for it. The renamed name used to be recorded in Info.plist as `ALTAppGroups`, but SideStore
/// (commit 7866508) stopped writing it - the granted ids now exist only in the provisioning
/// profile embedded in each bundle, so that is where they are read from.
///
/// Nothing is guessed: every candidate is probed with
/// `containerURL(forSecurityApplicationGroupIdentifier:)` and the first one the phone actually
/// grants a container for wins.
public enum AppGroupResolver {
    public static let productionFallback = "group.com.example.alarmclock"

    /// The name project.yml configured for this bundle, whether or not it works.
    public static var configuredIdentifier: String {
        (Bundle.main.object(forInfoDictionaryKey: "AlarmClockAppGroupIdentifier") as? String)
            ?? productionFallback
    }

    /// The group ids the phone granted THIS process, taken from this bundle's own provisioning
    /// profile. Empty when there is no profile (simulator / CI builds) or it cannot be read.
    public static func profileGroupIdentifiers() -> [String] {
        guard let path = Bundle.main.path(forResource: "embedded", ofType: "mobileprovision"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              // isoLatin1, not utf8: the profile is CMS-signed, so utf8 decoding returns nil.
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>"),
              let plist = try? PropertyListSerialization.propertyList(
                  from: Data(text[start.lowerBound..<end.upperBound].utf8),
                  format: nil
              ) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String]
        else {
            return []
        }
        return groups
    }

    /// Every identifier worth trying, most likely first.
    public static func candidates() -> [String] {
        let configured = configuredIdentifier
        let resigned = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []

        var list: [String] = []
        // Whatever this process was actually granted comes first.
        list.append(contentsOf: profileGroupIdentifiers())
        if let match = resigned.first(where: { $0 == configured || $0.hasPrefix(configured + ".") }) {
            list.append(match)
        }
        // Then EVERY resigned group, whatever it is called, then the configured name.
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
        let fromProfile = profileGroupIdentifiers()
        let chosen = resolve() ?? "none"
        return "configured=" + configured
            + " altGroups=" + (resigned.isEmpty ? "none" : resigned.joined(separator: ","))
            + " profile=" + (fromProfile.isEmpty ? "none" : fromProfile.joined(separator: ","))
            + " chosen=" + chosen
    }
}
