import SwiftUI
import AlarmClockShared

/// A reusable collapsible section with a chevron header that works in both
/// SoundsView (ContentView) and SoundPickerView.
struct CollapsibleSection<Content: View>: View {
    let id: String
    let title: String
    let isExpanded: Bool
    let onToggle: () -> Void
    let content: () -> Content
    
    var body: some View {
        Section {
            if isExpanded {
                content()
            }
        } header: {
            Button {
                onToggle()
            } label: {
                HStack {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(ThemeManager.shared.colors.primaryText)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                        .animation(.easeInOut(duration: 0.2), value: isExpanded)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}