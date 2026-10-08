import SwiftUI
import AlarmClockShared

struct AppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingCustomColors = false
    @State private var customColors = ThemeManager.shared.customThemeColors
    @State private var showingThemeEditor = false
    @State private var editingThemeID: UUID?

    // Button chrome settings bind straight to ThemeManager. Wheel pickers emit
    // discrete changes, so no local mirror / debounce is needed.
    private var glowRadiusBinding: Binding<Int> {
        Binding(
            get: { Int(ThemeManager.shared.buttonGlowRadius.rounded()) },
            set: { ThemeManager.shared.setButtonGlow(radius: Double($0)) }
        )
    }

    private var glowOpacityBinding: Binding<Int> {
        Binding(
            get: { Int(((ThemeManager.shared.buttonGlowOpacity * 100) / 5).rounded()) * 5 },
            set: { ThemeManager.shared.setButtonGlow(opacity: Double($0) / 100) }
        )
    }

    private var glowSpreadBinding: Binding<Int> {
        Binding(
            get: { Int(ThemeManager.shared.buttonGlowSpread.rounded()) },
            set: { ThemeManager.shared.setButtonGlow(spread: Double($0)) }
        )
    }

    private var outlineWidthBinding: Binding<Int> {
        Binding(
            get: { Int((ThemeManager.shared.buttonOutlineWidth * 2).rounded()) },
            set: { ThemeManager.shared.setButtonOutlineWidth(Double($0) / 2) }
        )
    }

    private var outerRingBinding: Binding<Int> {
        Binding(
            get: { Int((ThemeManager.shared.buttonOuterRing * 2).rounded()) },
            set: { ThemeManager.shared.setButtonOuterRing(Double($0) / 2) }
        )
    }

    private var textOutlineBinding: Binding<Int> {
        Binding(
            get: { Int((ThemeManager.shared.buttonTextOutline * 2).rounded()) },
            set: { ThemeManager.shared.setButtonTextOutline(Double($0) / 2) }
        )
    }

    private var editingTheme: UserTheme? {
        guard let editingThemeID else { return nil }
        return ThemeManager.shared.userThemes.first { $0.id == editingThemeID }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Alarm List") {
                    Toggle("Compact Mode", isOn: Binding(
                        get: { ThemeManager.shared.isCompactModeEnabled },
                        set: { ThemeManager.shared.setCompactMode($0) }
                    ))
                    Text("When enabled, each alarm row shows only the time and label - no repeat rule or 'Next:' line.")
                        .font(.footnote)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                }

                Section("Buttons") {
                    WheelSettingRow(
                        title: "Glow Size",
                        selection: glowRadiusBinding,
                        values: Array(0...20),
                        display: { "\($0)" }
                    )
                    WheelSettingRow(
                        title: "Glow Brightness",
                        selection: glowOpacityBinding,
                        values: Array(stride(from: 0, through: 100, by: 5)),
                        display: { "\($0)%" }
                    )
                    WheelSettingRow(
                        title: "Outer Spread",
                        selection: glowSpreadBinding,
                        values: Array(0...20),
                        display: { "\($0)" }
                    )
                    WheelSettingRow(
                        title: "Outline",
                        selection: outlineWidthBinding,
                        values: Array(0...12),
                        display: { String(format: "%.1f", Double($0) / 2) }
                    )
                    WheelSettingRow(
                        title: "Outer Ring",
                        selection: outerRingBinding,
                        values: Array(0...12),
                        display: { String(format: "%.1f", Double($0) / 2) }
                    )
                    WheelSettingRow(
                        title: "Text Outline",
                        selection: textOutlineBinding,
                        values: Array(0...6),
                        display: { String(format: "%.1f", Double($0) / 2) }
                    )

                    Text("Live Preview")
                        .font(.footnote)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                    BottomActionsBar(
                        leadingActions: [],
                        trailingActions: [.primary("Test") {}]
                    )
                    .listRowBackground(Color.clear)
                }
                
                Text("Glow applies to the bottom buttons and the floating + / gear.")
                    .font(.footnote)
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)

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
                    Text("Changes the text size across the entire app (sheets included). Requires supported semantic font styles.")
                        .font(.footnote)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
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

                Section {
                    Text("Theme changes apply immediately across the app. No restart required.")
                        .font(.footnote)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
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
                        .primary("Done") { dismiss() }
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
                        .cancel("Cancel") { dismiss() }
                    ],
                    trailingActions: [
                        .primary("Save") {
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
        case .toggleOff: return toggleOff.color
        case .divider: return divider.color
        case .destructive: return destructive.color
        }
    }
}

/// Create or edit a user theme: name + the existing colour roles.
struct UserThemeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let editingTheme: UserTheme?

    @State private var name: String = ""
    @State private var colors: CustomThemeColors = CustomThemeColors()

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
                        .cancel("Cancel") { dismiss() }
                    ],
                    trailingActions: [
                        .primary("Save", isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
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
            .onAppear {
                if let editingTheme {
                    name = editingTheme.name
                    colors = editingTheme.colors
                } else {
                    colors = ThemeManager.shared.customThemeColors
                }
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

/// One button-chrome setting: a title + value readout above a wheel picker.
/// Kept as its own view so spinning a wheel only re-renders this row.
private struct WheelSettingRow: View {
    let title: String
    let selection: Binding<Int>
    let values: [Int]
    let display: (Int) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text(display(selection.wrappedValue))
                    .font(.body.monospacedDigit())
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            Picker(title, selection: selection) {
                ForEach(values, id: \.self) { value in
                    Text(display(value)).tag(value)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .frame(height: 120)
            .clipped()
        }
    }
}