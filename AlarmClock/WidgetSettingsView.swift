import SwiftUI
import AlarmClockShared
import WidgetKit

/// Reads/writes the widget settings in the shared App Group container.
enum WidgetSettingsStore {
    static var defaults: UserDefaults {
        guard let group = AppGroupResolver.resolve() else { return .standard }
        return UserDefaults(suiteName: group) ?? .standard
    }
}

struct WidgetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    
    @AppStorage("widgetBatteryShowCircle", store: WidgetSettingsStore.defaults) private var batteryShowCircle = true
    @AppStorage("widgetBatteryShowText", store: WidgetSettingsStore.defaults) private var batteryShowText = true
    @AppStorage("widgetBatteryCircleScale", store: WidgetSettingsStore.defaults) private var batteryCircleScale = 1.0
    @AppStorage("widgetBatteryTextScale", store: WidgetSettingsStore.defaults) private var batteryTextScale = 1.0
    @AppStorage("widgetBatteryShowPercentSign", store: WidgetSettingsStore.defaults) private var batteryShowPercentSign = true
    @AppStorage("widgetBatteryPlateOpacity", store: WidgetSettingsStore.defaults) private var batteryPlateOpacity = 1.0
    @AppStorage("widgetInlineShowBattery", store: WidgetSettingsStore.defaults) private var inlineShowBattery = false
    @AppStorage("widgetHomeShowCircle", store: WidgetSettingsStore.defaults) private var homeShowCircle = true
    @AppStorage("widgetHomeShowText", store: WidgetSettingsStore.defaults) private var homeShowText = true
    @AppStorage("widgetMemoryShowCircle", store: WidgetSettingsStore.defaults) private var memoryShowCircle = true
    @AppStorage("widgetMemoryShowText", store: WidgetSettingsStore.defaults) private var memoryShowText = true
    @AppStorage("widgetMemoryCircleScale", store: WidgetSettingsStore.defaults) private var memoryCircleScale = 1.0
    @AppStorage("widgetMemoryTextScale", store: WidgetSettingsStore.defaults) private var memoryTextScale = 1.0
    @AppStorage("widgetMemoryPlateOpacity", store: WidgetSettingsStore.defaults) private var memoryPlateOpacity = 1.0
    
    var body: some View {
        NavigationStack {
            List {
                Section("Lock Screen circle") {
                    Toggle("Show the circle", isOn: $batteryShowCircle)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    Toggle("Show the percentage", isOn: $batteryShowText)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    if batteryShowText {
                        Toggle("Show the % sign", isOn: $batteryShowPercentSign)
                            .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Circle thickness: " + String(format: "%.1f", batteryCircleScale) + "\u{00d7}")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        Slider(value: $batteryCircleScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Percentage size: " + String(format: "%.1f", batteryTextScale) + "\u{00d7}")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        Slider(value: $batteryTextScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plate behind it: " + String(format: "%.0f", batteryPlateOpacity * 100) + "%")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        Slider(value: $batteryPlateOpacity, in: 0.0...1.0)
                    }
                }
                
                Section("One-line widget") {
                    Toggle("Also show the battery", isOn: $inlineShowBattery)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                }
                
                Section("Home Screen widget") {
                    Toggle("Show the circle", isOn: $homeShowCircle)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    Toggle("Show the percentage", isOn: $homeShowText)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                }
                
                Section("Memory widget") {
                    Toggle("Show the circle", isOn: $memoryShowCircle)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    Toggle("Show the percentage", isOn: $memoryShowText)
                        .toggleStyle(ThemedToggleStyle(colors: ThemeManager.shared.colors))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Circle thickness: " + String(format: "%.1f", memoryCircleScale) + "\u{00d7}")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        Slider(value: $memoryCircleScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Percentage size: " + String(format: "%.1f", memoryTextScale) + "\u{00d7}")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        Slider(value: $memoryTextScale, in: 0.5...3.0)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Plate behind it: " + String(format: "%.0f", memoryPlateOpacity * 100) + "%")
                            .font(.caption)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        Slider(value: $memoryPlateOpacity, in: 0.0...1.0)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Widgets")
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
            }
        }
    }
}

#Preview {
    WidgetSettingsView()
}