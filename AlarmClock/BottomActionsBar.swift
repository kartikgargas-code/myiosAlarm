import SwiftUI
import AlarmClockShared

/// Reusable bottom action bar for sheets/modals
/// Cancel/secondary actions on the left, primary (Save/Done) on the right with accent color
struct BottomActionsBar: View {
    let leadingActions: [ActionButton]
    let trailingActions: [ActionButton]
    let padding: CGFloat
    let backgroundColor: Color
    
    // Dark charcoal fill for solid buttons
    private let buttonFill = Color(red: 0.118, green: 0.133, blue: 0.153)  // #1E2227
    
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
    }
    
    private func actionButton(_ action: ActionButton) -> some View {
        let isDestructive = action.foregroundColor == .red
        let borderColor = isDestructive ? Color.red : ThemeManager.shared.colors.accent
        let textColor = isDestructive ? Color.red : ThemeManager.shared.colors.accent
        
        return Button(action: action.action) {
            HStack(spacing: 8) {
                if let systemImage = action.systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 16, weight: .semibold))
                }
                Text(action.title)
                    .font(.system(size: 17, weight: .bold))
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(buttonFill)  // Opaque dark charcoal
            .overlay(
                Capsule().stroke(borderColor, lineWidth: 2)  // 2pt accent border
            )
            .clipShape(Capsule())
            .shadow(color: borderColor.opacity(0.55), radius: 12)  // Accent glow
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
        // Primary uses accent text per style; use nil so actionButton resolves it at View build time
        ActionButton(title: title, action: action, systemImage: systemImage, isPrimary: true, foregroundColor: nil, isEnabled: isEnabled)
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