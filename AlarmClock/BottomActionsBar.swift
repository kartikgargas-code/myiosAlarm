import SwiftUI
import AlarmClockShared

/// Reusable bottom action bar for sheets/modals
/// Cancel/secondary actions on the left, primary (Save/Done) on the right with accent color
struct BottomActionsBar: View {
    let leadingActions: [ActionButton]
    let trailingActions: [ActionButton]
    let padding: CGFloat
    let backgroundColor: Color
    
    init(
        leadingActions: [ActionButton] = [],
        trailingActions: [ActionButton] = [],
        padding: CGFloat = 16,
        backgroundColor: Color? = nil
    ) {
        self.leadingActions = leadingActions
        self.trailingActions = trailingActions
        self.padding = padding
        self.backgroundColor = backgroundColor ?? .clear  // .clear so bar is not an opaque strip
    }
    
    var body: some View {
        // A plain HStack is required so the Spacer can push the trailing actions
        // (Save/Done) to the right edge. Inside a horizontal ScrollView the Spacer
        // collapses, which is what pushed the buttons to the centre. The scroll
        // fallback is only used when the actions cannot fit on one line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                leadingActionsView
                Spacer(minLength: 12)
                trailingActionsView
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    leadingActionsView
                    trailingActionsView
                }
            }
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 12)
        .background(backgroundColor)
    }
    
    @ViewBuilder
    private var leadingActionsView: some View {
        ForEach(leadingActions.indices, id: \.self) { index in
            actionButton(leadingActions[index])
        }
    }
    
    @ViewBuilder
    private var trailingActionsView: some View {
        ForEach(trailingActions.indices, id: \.self) { index in
            actionButton(trailingActions[index])
        }
    }
    
    private func actionButton(_ action: ActionButton) -> some View {
        let isDestructive = action.foregroundColor == .red
        let accent = isDestructive ? Color.red : ThemeManager.shared.colors.accent
        
        if action.isIconOnly {
            if let menu = action.menu {
                return AnyView(
                    Menu {
                        menu
                    } label: {
                        Image(systemName: action.systemImage ?? "")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                            .appButtonChrome(shape: .circle, size: 48)
                    }
                    .disabled(!action.isEnabled)
                    .accessibilityLabel(action.title)
                    .buttonStyle(.plain)
                )
            } else {
                return AnyView(
                    Button(action: action.action) {
                        Image(systemName: action.systemImage ?? "")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(accent)
                            .appButtonChrome(shape: .circle, size: 48)
                    }
                    .disabled(!action.isEnabled)
                    .accessibilityLabel(action.title)
                    .buttonStyle(.plain)
                )
            }
        } else {
            return AnyView(
                Button(action: action.action) {
                    HStack(spacing: 8) {
                        if let systemImage = action.systemImage {
                            Image(systemName: systemImage)
                                .font(.body.weight(.semibold))
                        }
                        Text(action.title)
                    }
                    .foregroundStyle(accent)
                    .appButtonChrome(shape: .capsule)
                }
                .disabled(!action.isEnabled)
                .buttonStyle(.plain)
            )
        }
    }
}

struct ActionButton {
    let title: String
    let action: () -> Void
    var systemImage: String? = nil
    var isPrimary: Bool = false
    var foregroundColor: Color? = nil
    var isEnabled: Bool = true
    var isIconOnly: Bool = false
    var menu: AnyView? = nil
    
    static func cancel(_ title: String = "Cancel", action: @escaping () -> Void) -> ActionButton {
        ActionButton(title: title, action: action, isPrimary: false)
    }
    
    static func destructive(_ title: String, action: @escaping () -> Void) -> ActionButton {
        ActionButton(title: title, action: action, isPrimary: false, foregroundColor: .red)
    }
    
    static func primary(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) -> ActionButton {
        // Primary uses accent text per style; use nil so actionButton resolves it at View build time
        ActionButton(title: title, action: action, systemImage: systemImage, isPrimary: true, foregroundColor: nil, isEnabled: isEnabled)
    }
    
    static func custom(_ title: String, action: @escaping () -> Void, systemImage: String? = nil, isPrimary: Bool = false, foregroundColor: Color? = nil, isEnabled: Bool = true) -> ActionButton {
        ActionButton(title: title, action: action, systemImage: systemImage, isPrimary: isPrimary, foregroundColor: foregroundColor, isEnabled: isEnabled)
    }
    
    static func icon(_ accessibilityLabel: String, systemImage: String,
                     destructive: Bool = false, isEnabled: Bool = true,
                     action: @escaping () -> Void) -> ActionButton {
        ActionButton(title: accessibilityLabel, action: action, systemImage: systemImage,
                     isPrimary: false, foregroundColor: destructive ? .red : nil,
                     isEnabled: isEnabled, isIconOnly: true)
    }
    
    func menu(_ menu: AnyView) -> ActionButton {
        var copy = self
        copy.menu = menu
        return copy
    }
}

// Preview
#Preview {
    BottomActionsBar(
        leadingActions: [.cancel { print("Cancel") }],
        trailingActions: [.icon("Save", systemImage: "checkmark") { print("Save") }]
    )
}