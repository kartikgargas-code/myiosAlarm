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
                Section("Alarm List") {
                    Toggle("Compact Mode", isOn: Binding(
                        get: { ThemeManager.shared.isCompactModeEnabled },
                        set: { ThemeManager.shared.isCompactModeEnabled = $0 }
                    ))
                    Text("When enabled, each alarm row shows only the time and label - no repeat rule or 'Next:' line.")
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
