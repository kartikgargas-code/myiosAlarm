import SwiftUI
import AlarmClockShared
import UIKit

struct AppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingCustomColors = false
    @State private var customColors = ThemeManager.shared.customThemeColors
    @State private var showingThemeEditor = false
    @State private var editingThemeID: UUID?

    // Button chrome settings bind straight to ThemeManager. Sliders emit
    // continuous changes, so no local mirror / debounce is needed.
    private var glowRadiusSlider: Binding<Double> {
        Binding(
            get: { ThemeManager.shared.buttonGlowRadius },
            set: { ThemeManager.shared.setButtonGlow(radius: $0) }
        )
    }
    private var glowOpacitySlider: Binding<Double> {
        Binding(
            get: { ThemeManager.shared.buttonGlowOpacity * 100 },
            set: { ThemeManager.shared.setButtonGlow(opacity: $0 / 100) }
        )
    }
    private var glowSpreadSlider: Binding<Double> {
        Binding(
            get: { ThemeManager.shared.buttonGlowSpread },
            set: { ThemeManager.shared.setButtonGlow(spread: $0) }
        )
    }
    private var outlineSlider: Binding<Double> {
        Binding(
            get: { ThemeManager.shared.buttonOutlineWidth },
            set: { ThemeManager.shared.setButtonOutlineWidth($0) }
        )
    }
    private var outerRingSlider: Binding<Double> {
        Binding(
            get: { ThemeManager.shared.buttonOuterRing },
            set: { ThemeManager.shared.setButtonOuterRing($0) }
        )
    }
    private var textOutlineSlider: Binding<Double> {
        Binding(
            get: { ThemeManager.shared.buttonTextOutline },
            set: { ThemeManager.shared.setButtonTextOutline($0) }
        )
    }

    private var editingTheme: UserTheme? {
        guard let editingThemeID else { return nil }
        return ThemeManager.shared.userThemes.first { $0.id == editingThemeID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Custom-Day Alarm Color") {
                    Toggle("Use Different Color", isOn: Binding(
                        get: { ThemeManager.shared.customDayAlarmColorEnabled },
                        set: { ThemeManager.shared.setCustomDayAlarmColorEnabled($0) }
                    ))
                    if ThemeManager.shared.customDayAlarmColorEnabled {
                        ColorPicker("Color", selection: Binding(
                            get: { ThemeManager.shared.customDayAlarmColor },
                            set: { ThemeManager.shared.setCustomDayAlarmColor($0) }
                        ), supportsOpacity: false)
                    }
                }
                
                Section("Custom Ringtone Card Color") {
                    Toggle("Use Custom Color for Imported Song Cards", isOn: Binding(
                        get: { ThemeManager.shared.customRingtoneCardColorEnabled },
                        set: { ThemeManager.shared.setCustomRingtoneCardColorEnabled($0) }
                    ))
                    if ThemeManager.shared.customRingtoneCardColorEnabled {
                        ColorPicker("Card Color", selection: Binding(
                            get: { ThemeManager.shared.customRingtoneCardColor },
                            set: { ThemeManager.shared.setCustomRingtoneCardColor($0) }
                        ), supportsOpacity: false)
                    }
                }

                Section("My Themes") {
                    ForEach(ThemeManager.shared.userThemes) { userTheme in
                        Button {
                            ThemeManager.shared.selectUserTheme(userTheme)
                        } label: {
                            HStack(spacing: 16) {
                                themePreview(ThemeManager.shared.userThemeColors(userTheme))
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                Text(userTheme.name)
                                    .font(.body)
                                    .foregroundStyle(ThemeManager.shared.colors.primaryText)

                                Spacer()

                                if ThemeManager.shared.activeUserThemeID == userTheme.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ThemeManager.shared.colors.accent)
                                        .font(.title2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                ThemeManager.shared.deleteUserTheme(id: userTheme.id)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                editingThemeID = userTheme.id
                                showingThemeEditor = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                        .contextMenu {
                            Button("Edit") {
                                editingThemeID = userTheme.id
                                showingThemeEditor = true
                            }
                            Button("Duplicate") {
                                ThemeManager.shared.duplicateUserTheme(userTheme)
                            }
                            Button("Delete", role: .destructive) {
                                ThemeManager.shared.deleteUserTheme(id: userTheme.id)
                            }
                        }
                    }

                    Button {
                        editingThemeID = nil
                        showingThemeEditor = true
                    } label: {
                        Label("New Theme", systemImage: "plus.circle")
                            .foregroundStyle(ThemeManager.shared.colors.accent)
                    }
                }

                Section("Predefined Themes") {
                    ForEach(ThemeManager.shared.availableThemes) { theme in
                        Button {
                            ThemeManager.shared.selectTheme(theme)
                        } label: {
                            HStack(spacing: 16) {
                                themePreview(theme.colors)
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(theme.rawValue)
                                        .font(.body)
                                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                                }

                                Spacer()

                                if ThemeManager.shared.currentTheme == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ThemeManager.shared.colors.accent)
                                        .font(.title2)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                Section("Buttons") {
                    HStack {
                        Spacer()
                        Button("Test") {}
                            .appButtonChrome(shape: .capsule)
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                    
                    VStack(spacing: 0) {
                        // Row 1: Glow Size | Lume
                        HStack(spacing: 24) {
                            WheelSettingRow(
                                title: "Glow Size",
                                value: glowRadiusSlider,
                                range: 0...20,
                                step: 1,
                                format: { "\(Int($0))" }
                            )
                            WheelSettingRow(
                                title: "Lume",
                                value: glowOpacitySlider,
                                range: 0...100,
                                step: 5,
                                format: { "\(Int($0))%" }
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    
                        // Row 2: Spread | Border
                        HStack(spacing: 24) {
                            WheelSettingRow(
                                title: "Spread",
                                value: glowSpreadSlider,
                                range: 0...20,
                                step: 1,
                                format: { "\(Int($0))" }
                            )
                            WheelSettingRow(
                                title: "Border",
                                value: outlineSlider,
                                range: 0...6,
                                step: 0.5,
                                format: { String(format: "%.1f", $0) }
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    
                        // Row 3: Ring | Edge
                        HStack(spacing: 24) {
                            WheelSettingRow(
                                title: "Ring",
                                value: outerRingSlider,
                                range: 0...6,
                                step: 0.5,
                                format: { String(format: "%.1f", $0) }
                            )
                            WheelSettingRow(
                                title: "Edge",
                                value: textOutlineSlider,
                                range: 0...3,
                                step: 0.5,
                                format: { String(format: "%.1f", $0) }
                            )
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                    }
                    .background(ThemeManager.shared.colors.card)
                    .cornerRadius(12)
                }

                Section("Text Size") {
                    Picker("Interface Text Size", selection: Binding(
                        get: { ThemeManager.shared.interfaceTextSize },
                        set: { ThemeManager.shared.setInterfaceTextSize($0) }
                    )) {
                        Text("Small").tag(DynamicTypeSize.medium)
                        Text("Default").tag(DynamicTypeSize.xLarge)
                        Text("Large").tag(DynamicTypeSize.xxLarge)
                        Text("Extra Large").tag(DynamicTypeSize.xxxLarge)
                    }
                    .pickerStyle(.segmented)
                    .tint(ThemeManager.shared.colors.accent)
                }
                
                Section("Alarm List") {
                    Toggle("Compact Mode", isOn: Binding(
                        get: { ThemeManager.shared.isCompactModeEnabled },
                        set: { ThemeManager.shared.setCompactMode($0) }
                    ))
                }
                
                Section("Custom-Day Alarm Color") {
                    Toggle("Use Different Color", isOn: Binding(
                        get: { ThemeManager.shared.customDayAlarmColorEnabled },
                        set: { ThemeManager.shared.setCustomDayAlarmColorEnabled($0) }
                    ))
                    if ThemeManager.shared.customDayAlarmColorEnabled {
                        ColorPicker("Color", selection: Binding(
                            get: { ThemeManager.shared.customDayAlarmColor },
                            set: { ThemeManager.shared.setCustomDayAlarmColor($0) }
                        ), supportsOpacity: false)
                    }
                }
                
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .dynamicTypeSize(ThemeManager.shared.interfaceTextSize)
            .navigationTitle("Appearance")
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [],
                    trailingActions: [
                        .icon("Done", systemImage: "checkmark") { dismiss() }
                    ]
                )
            }
            .sheet(isPresented: $showingCustomColors) {
                CustomColorPickerView(customColors: $customColors) { updated in
                    ThemeManager.shared.updateCustomColors(updated)
                }
            }
            .sheet(isPresented: $showingThemeEditor) {
                UserThemeEditorView(editingTheme: editingTheme)
                    .id(editingThemeID)
            }
        }
    }

    private func themePreview(_ colors: ThemeColors) -> some View {
        ZStack {
            colors.card
            VStack(spacing: 4) {
                Circle()
                    .fill(colors.accent)
                    .frame(width: 12, height: 12)
                RoundedRectangle(cornerRadius: 4)
                    .fill(colors.primaryText.opacity(0.1))
                    .frame(height: 8)
            }
        }
    }

    private func customColorRow(_ role: ColorRole) -> some View {
        let color = bindingForRole(role)
        return HStack(spacing: 12) {
            Circle()
                .fill(color.wrappedValue)
                .frame(width: 28, height: 28)
                .overlay(
                    Circle()
                        .stroke(ThemeManager.shared.colors.divider, lineWidth: 1)
                )

            Text(role.rawValue)
                .foregroundStyle(ThemeManager.shared.colors.primaryText)

            Spacer()

            ColorPicker("", selection: color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 44, height: 44)
        }
    }

    private func bindingForRole(_ role: ColorRole) -> Binding<Color> {
        Binding(
            get: { customColors.color(for: role) },
            set: { newColor in
                customColors.update(color: newColor, for: role)
            }
        )
    }
}

struct CustomColorPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var customColors: CustomThemeColors
    let onSave: (CustomThemeColors) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(ColorRole.allCases) { role in
                    HStack(spacing: 12) {
                        Circle()
                            .fill(customColors.color(for: role))
                            .frame(width: 32, height: 32)
                            .overlay(
                                Circle()
                                    .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                            )

                        Text(role.rawValue)
                            .foregroundStyle(ThemeManager.shared.colors.primaryText)

                        Spacer()

                        ColorPicker("", selection: bindingForRole(role), supportsOpacity: true)
                            .labelsHidden()
                            .frame(width: 44, height: 44)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle("Custom Colors")
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [
                        .icon("Cancel", systemImage: "xmark") { dismiss() }
                    ],
                    trailingActions: [
                        .icon("Save", systemImage: "checkmark") {
                            onSave(customColors)
                            dismiss()
                        }
                    ]
                )
            }
        }
    }

    private func bindingForRole(_ role: ColorRole) -> Binding<Color> {
        Binding(
            get: { customColors.color(for: role) },
            set: { newColor in
                customColors.update(color: newColor, for: role)
            }
        )
    }
}

extension CustomThemeColors {
    func color(for role: ColorRole) -> Color {
        switch role {
        case .background: return background.color
        case .card: return card.color
        case .primaryText: return primaryText.color
        case .secondaryText: return secondaryText.color
        case .accent: return accent.color
        case .toggleOn: return toggleOn.color
        case .toggleOff: return toggleOff.color
        case .divider: return divider.color
        case .destructive: return destructive.color
        }
    }
}

/// Live ticking seconds preview for the Seconds Animation picker
struct PreviewSecondsView: View {
    @State private var currentSecond: Int = 0
    
    var body: some View {
        MorphSecondsView(
            seconds: currentSecond,
            color: ThemeManager.shared.colors.accent,
            style: ThemeManager.shared.secondsMorphStyle,
            font: .title3.monospacedDigit(),
            canvasWidth: 36,
            canvasHeight: 30
        )
        .frame(minWidth: 40, alignment: .trailing)
        .onAppear {
            let calendar = Calendar.current
            currentSecond = calendar.component(.second, from: Date())
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { date in
            currentSecond = Calendar.current.component(.second, from: date)
        }
    }
}

/// Create or edit a user theme: name + the existing colour roles.
struct UserThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let editingTheme: UserTheme?

    @State private var name: String
    @State private var colors: CustomThemeColors

    init(editingTheme: UserTheme?) {
        self.editingTheme = editingTheme
        if let editingTheme {
            self._name = State(initialValue: editingTheme.name)
            self._colors = State(initialValue: editingTheme.colors)
        } else {
            self._name = State(initialValue: "")
            self._colors = State(initialValue: ThemeManager.shared.customThemeColors)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Theme name", text: $name)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                }
                Section("Colors") {
                    ForEach(ColorRole.allCases) { role in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(colors.color(for: role))
                                .frame(width: 28, height: 28)
                                .overlay(
                                    Circle()
                                        .stroke(ThemeManager.shared.colors.divider, lineWidth: 1)
                                )
                            Text(role.rawValue)
                                .foregroundStyle(ThemeManager.shared.colors.primaryText)
                            Spacer()
                            ColorPicker("", selection: colorBinding(role), supportsOpacity: true)
                                .labelsHidden()
                                .frame(width: 44, height: 44)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ThemeManager.shared.colors.background)
            .navigationTitle(editingTheme == nil ? "New Theme" : "Edit Theme")
            .safeAreaInset(edge: .bottom) {
                BottomActionsBar(
                    leadingActions: [
                        .icon("Cancel", systemImage: "xmark") { dismiss() }
                    ],
                    trailingActions: [
                        .icon("Save", systemImage: "checkmark", isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                            if let editingTheme {
                                ThemeManager.shared.updateUserTheme(id: editingTheme.id, name: name, colors: colors)
                            } else {
                                ThemeManager.shared.createUserTheme(name: name, colors: colors)
                            }
                            dismiss()
                        }
                    ]
                )
            }
        }
    }

    private func colorBinding(_ role: ColorRole) -> Binding<Color> {
        Binding(
            get: { colors.color(for: role) },
            set: { colors.update(color: $0, for: role) }
        )
    }
}

private struct SliderSettingRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(ThemeManager.shared.colors.accent)
            }
            Slider(value: value, in: range, step: step)
                .tint(ThemeManager.shared.colors.accent)
        }
    }
}

struct WheelSettingRow: View {
    let title: String
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    
    @State private var lastValue: Double = 0
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                Spacer(minLength: 12)
                Picker("", selection: value) {
                    ForEach(makeValues(), id: \.self) { val in
                        Text(format(val)).tag(val)
                    }
                }
                .pickerStyle(.wheel)
                .frame(width: 65, height: 120)
                .clipped()
                .onChange(of: value.wrappedValue) { _, newValue in
                    if lastValue != newValue {
                        let generator = UIImpactFeedbackGenerator(style: .light)
                        generator.impactOccurred()
                        lastValue = newValue
                    }
                }
            }
        }
    }
    
    private func makeValues() -> [Double] {
        var values: [Double] = []
        var current = range.lowerBound
        while current <= range.upperBound + step / 2 {
            values.append(current)
            current += step
        }
        return values
    }
}