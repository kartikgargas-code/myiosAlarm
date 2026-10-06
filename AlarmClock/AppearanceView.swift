import SwiftUI

struct AppearanceView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showingCustomColors = false
    @State private var customColors = ThemeManager.shared.customThemeColors
    @State private var showingThemeEditor = false
    @State private var editingThemeID: UUID?

    private var editingTheme: UserTheme? {
        guard let editingThemeID else { return nil }
        return ThemeManager.shared.userThemes.first { $0.id == editingThemeID }
    }

    var body: some View {
        NavigationStack {
            List {
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
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
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
                                    if theme == .custom {
                                        Text("Customize colors below")
                                            .font(.caption)
                                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                                    }
                                }

                                Spacer()

                                if ThemeManager.shared.currentTheme == theme {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(ThemeManager.shared.colors.accent)
                                        .font(.title2)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }

                if ThemeManager.shared.currentTheme == .custom {
                    Section("Custom Colors") {
                        ForEach(ColorRole.allCases) { role in
                            customColorRow(role)
                        }

                        Button("Open Color Picker") {
                            customColors = ThemeManager.shared.customThemeColors
                            showingCustomColors = true
                        }
                        .foregroundStyle(ThemeManager.shared.colors.accent)
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
            .navigationTitle("Appearance")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(customColors)
                        dismiss()
                    }
                }
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
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let editingTheme {
                            ThemeManager.shared.updateUserTheme(id: editingTheme.id, name: name, colors: colors)
                        } else {
                            ThemeManager.shared.createUserTheme(name: name, colors: colors)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
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