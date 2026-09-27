import SwiftUI
import Observation

@MainActor
@Observable
final class ThemeManager {
    static let shared = ThemeManager()

    private let defaults = UserDefaults.standard
    private let themeKey = "selectedTheme"
    private let customColorsKey = "customThemeColors"

    var currentTheme: Theme = .midnightBlack
    var customThemeColors: CustomThemeColors = CustomThemeColors()

    private init() {
        loadTheme()
    }

    var colors: ThemeColors {
        if currentTheme == .custom {
            return customThemeColors.toThemeColors()
        }
        return currentTheme.colors
    }

    var availableThemes: [Theme] = [
        .midnightBlack,
        .charcoalOrange,
        .deepBlue,
        .emeraldDark,
        .crimsonDark,
        .light
    ]

    func selectTheme(_ theme: Theme) {
        currentTheme = theme
        saveTheme()
    }

    func updateCustomColors(_ colors: CustomThemeColors) {
        customThemeColors = colors
        if currentTheme == .custom {
            saveTheme()
        }
    }

    func updateCustomColor(_ color: Color, for role: ColorRole) {
        customThemeColors.update(color: color, for: role)
        if currentTheme == .custom {
            saveTheme()
        }
    }

    private func loadTheme() {
        if let themeName = defaults.string(forKey: themeKey),
           let theme = Theme(rawValue: themeName) {
            currentTheme = theme
        }
        if let data = defaults.data(forKey: customColorsKey),
           let custom = try? JSONDecoder().decode(CustomThemeColors.self, from: data) {
            customThemeColors = custom
        }
    }

    private func saveTheme() {
        defaults.set(currentTheme.rawValue, forKey: themeKey)
        if let data = try? JSONEncoder().encode(customThemeColors) {
            defaults.set(data, forKey: customColorsKey)
        }
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case midnightBlack = "Midnight Black"
    case charcoalOrange = "Charcoal Orange"
    case deepBlue = "Deep Blue"
    case emeraldDark = "Emerald Dark"
    case crimsonDark = "Crimson Dark"
    case light = "Light"
    case custom = "Custom"

    var id: String { rawValue }

    var colors: ThemeColors {
        switch self {
        case .midnightBlack:
            return ThemeColors(
                background: Color(red: 0, green: 0, blue: 0),
                card: Color(red: 0.11, green: 0.11, blue: 0.12),
                primaryText: Color.white,
                secondaryText: Color(red: 0.65, green: 0.65, blue: 0.68),
                accent: Color(red: 1.0, green: 0.58, blue: 0.0),
                toggleOn: Color(red: 1.0, green: 0.58, blue: 0.0),
                toggleOff: Color(red: 0.33, green: 0.33, blue: 0.35),
                divider: Color(red: 0.22, green: 0.22, blue: 0.24),
                destructive: Color(red: 1.0, green: 0.23, blue: 0.19)
            )
        case .charcoalOrange:
            return ThemeColors(
                background: Color(red: 0.06, green: 0.06, blue: 0.07),
                card: Color(red: 0.13, green: 0.13, blue: 0.14),
                primaryText: Color.white,
                secondaryText: Color(red: 0.62, green: 0.58, blue: 0.55),
                accent: Color(red: 1.0, green: 0.5, blue: 0.1),
                toggleOn: Color(red: 1.0, green: 0.5, blue: 0.1),
                toggleOff: Color(red: 0.33, green: 0.33, blue: 0.35),
                divider: Color(red: 0.2, green: 0.19, blue: 0.18),
                destructive: Color(red: 1.0, green: 0.23, blue: 0.19)
            )
        case .deepBlue:
            return ThemeColors(
                background: Color(red: 0.02, green: 0.04, blue: 0.08),
                card: Color(red: 0.08, green: 0.12, blue: 0.18),
                primaryText: Color.white,
                secondaryText: Color(red: 0.58, green: 0.65, blue: 0.75),
                accent: Color(red: 0.3, green: 0.6, blue: 1.0),
                toggleOn: Color(red: 0.3, green: 0.6, blue: 1.0),
                toggleOff: Color(red: 0.25, green: 0.3, blue: 0.4),
                divider: Color(red: 0.15, green: 0.2, blue: 0.3),
                destructive: Color(red: 1.0, green: 0.3, blue: 0.3)
            )
        case .emeraldDark:
            return ThemeColors(
                background: Color(red: 0.02, green: 0.08, blue: 0.04),
                card: Color(red: 0.06, green: 0.14, blue: 0.08),
                primaryText: Color.white,
                secondaryText: Color(red: 0.55, green: 0.68, blue: 0.6),
                accent: Color(red: 0.2, green: 0.8, blue: 0.4),
                toggleOn: Color(red: 0.2, green: 0.8, blue: 0.4),
                toggleOff: Color(red: 0.2, green: 0.33, blue: 0.25),
                divider: Color(red: 0.12, green: 0.22, blue: 0.15),
                destructive: Color(red: 1.0, green: 0.3, blue: 0.3)
            )
        case .crimsonDark:
            return ThemeColors(
                background: Color(red: 0.08, green: 0.02, blue: 0.03),
                card: Color(red: 0.16, green: 0.06, blue: 0.08),
                primaryText: Color.white,
                secondaryText: Color(red: 0.7, green: 0.55, blue: 0.58),
                accent: Color(red: 1.0, green: 0.3, blue: 0.4),
                toggleOn: Color(red: 1.0, green: 0.3, blue: 0.4),
                toggleOff: Color(red: 0.35, green: 0.2, blue: 0.22),
                divider: Color(red: 0.25, green: 0.15, blue: 0.17),
                destructive: Color(red: 1.0, green: 0.35, blue: 0.35)
            )
        case .light:
            return ThemeColors(
                background: Color(red: 0.98, green: 0.98, blue: 0.98),
                card: Color(red: 1.0, green: 1.0, blue: 1.0),
                primaryText: Color(red: 0.11, green: 0.11, blue: 0.12),
                secondaryText: Color(red: 0.42, green: 0.42, blue: 0.44),
                accent: Color(red: 1.0, green: 0.45, blue: 0.0),
                toggleOn: Color(red: 1.0, green: 0.45, blue: 0.0),
                toggleOff: Color(red: 0.75, green: 0.75, blue: 0.77),
                divider: Color(red: 0.85, green: 0.85, blue: 0.86),
                destructive: Color(red: 0.9, green: 0.18, blue: 0.2)
            )
        case .custom:
            return customThemeColors.toThemeColors()
        }
    }
}

struct ThemeColors {
    let background: Color
    let card: Color
    let primaryText: Color
    let secondaryText: Color
    let accent: Color
    let toggleOn: Color
    let toggleOff: Color
    let divider: Color
    let destructive: Color
}

struct CustomThemeColors: Codable {
    var background: ColorData = ColorData(red: 0, green: 0, blue: 0, alpha: 1)
    var card: ColorData = ColorData(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    var primaryText: ColorData = ColorData(red: 1, green: 1, blue: 1, alpha: 1)
    var secondaryText: ColorData = ColorData(red: 0.65, green: 0.65, blue: 0.68, alpha: 1)
    var accent: ColorData = ColorData(red: 1, green: 0.58, blue: 0, alpha: 1)
    var toggleOn: ColorData = ColorData(red: 1, green: 0.58, blue: 0, alpha: 1)
    var toggleOff: ColorData = ColorData(red: 0.33, green: 0.33, blue: 0.35, alpha: 1)
    var divider: ColorData = ColorData(red: 0.22, green: 0.22, blue: 0.24, alpha: 1)
    var destructive: ColorData = ColorData(red: 1, green: 0.23, blue: 0.19, alpha: 1)

    func toThemeColors() -> ThemeColors {
        ThemeColors(
            background: background.color,
            card: card.color,
            primaryText: primaryText.color,
            secondaryText: secondaryText.color,
            accent: accent.color,
            toggleOn: toggleOn.color,
            toggleOff: toggleOff.color,
            divider: divider.color,
            destructive: destructive.color
        )
    }

    mutating func update(color: Color, for role: ColorRole) {
        let colorData = ColorData(from: color)
        switch role {
        case .background: background = colorData
        case .card: card = colorData
        case .primaryText: primaryText = colorData
        case .secondaryText: secondaryText = colorData
        case .accent: accent = colorData; toggleOn = colorData
        case .toggleOff: toggleOff = colorData
        case .divider: divider = colorData
        case .destructive: destructive = colorData
        }
    }
}

struct ColorData: Codable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    var color: Color {
        Color(red: red, green: green, blue: blue, opacity: alpha)
    }

    init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(from color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let uiColor = UIColor(color)
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        self.red = Double(r)
        self.green = Double(g)
        self.blue = Double(b)
        self.alpha = Double(a)
    }
}

enum ColorRole: String, CaseIterable, Identifiable {
    case background = "Background"
    case card = "Card"
    case primaryText = "Primary Text"
    case secondaryText = "Secondary Text"
    case accent = "Accent"
    case toggleOff = "Toggle Off"
    case divider = "Divider"
    case destructive = "Destructive"

    var id: String { rawValue }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 1)
        }
        self.init(
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}