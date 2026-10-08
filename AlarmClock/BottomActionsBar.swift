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
        self.backgroundColor = backgroundColor ?? .clear  // Changed to .clear so buttons float
    }
    
    var body: some View {
        HStack(spacing: 12) {
            // Leading actions (Cancel, etc.)
            ForEach(leadingActions.indices, id: \.self) { index in
                actionButton(leadingActions[index])
            }
            
            Spacer()
            
            // Trailing actions (Save, Done, etc.)
            ForEach(trailingActions.indices, id: \.self) { index in
                actionButton(trailingActions[index])
            }
        }
        .padding(.horizontal, padding)
        .padding(.vertical, 12)
        .background(backgroundColor)
        // Removed shadow since buttons now float with their own translucent backgrounds
    }
    
    private func actionButton(_ action: ActionButton) -> some View {
        Button(action: action.action) {
            HStack(spacing: 8) {
                if let systemImage = action.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(action.title)
                    .font(.system(size: 17, weight: .semibold))
            }
            .foregroundStyle(action.foregroundColor ?? ThemeManager.shared.colors.accent)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                action.isPrimary
                    ? ThemeManager.shared.colors.accent.opacity(0.30)  // PRIMARY: translucent accent fill
                    : ThemeManager.shared.colors.accent.opacity(0.15)  // SECONDARY: translucent accent fill
            )
            .overlay(
                Capsule().stroke(ThemeManager.shared.colors.accent.opacity(0.55), lineWidth: 1)  // Thin border for both
            )
            .clipShape(Capsule())
            // Removed shadow - buttons float with their own translucent backgrounds
        }
        .disabled(!action.isEnabled)
    }
}

struct ActionButton {
    let title: String
    let action: () -> Void
    var systemImage: String? = nil
    var isPrimary: Bool = false
    var foregroundColor: Color? = nil
    var isEnabled: Bool = true
    
    static func cancel(_ title: String = "Cancel", action: @escaping () -> Void) -> ActionButton {
        ActionButton(title: title, action: action, isPrimary: false)
    }
    
    static func destructive(_ title: String, action: @escaping () -> Void) -> ActionButton {
        ActionButton(title: title, action: action, isPrimary: false, foregroundColor: .red)
    }
    
    static func primary(_ title: String, systemImage: String? = nil, isEnabled: Bool = true, action: @escaping () -> Void) -> ActionButton {
        ActionButton(title: title, action: action, systemImage: systemImage, isPrimary: true, foregroundColor: .white, isEnabled: isEnabled)
    }
    
    static func custom(_ title: String, action: @escaping () -> Void, systemImage: String? = nil, isPrimary: Bool = false, foregroundColor: Color? = nil, isEnabled: Bool = true) -> ActionButton {
        ActionButton(title: title, action: action, systemImage: systemImage, isPrimary: isPrimary, foregroundColor: foregroundColor, isEnabled: isEnabled)
    }
}

// Preview
#Preview {
    BottomActionsBar(
        leadingActions: [.cancel { print("Cancel") }],
        trailingActions: [.primary("Save") { print("Save") }]
    )
}