import SwiftUI
import AlarmClockShared

/// Shape type for button chrome
enum ButtonChromeShape {
    case capsule
    case circle
}

/// A reusable button chrome that draws ALL the visual chrome:
/// - Opaque fill
/// - Accent outline (with configurable width)
/// - Dark outer ring (configurable)
/// - Glow shadows (primary + spread)
/// - Text outline (configurable)
struct AppButtonChrome<Content: View>: View {
    let content: Content
    let shape: ButtonChromeShape
    
    @Environment(\.colorScheme) private var colorScheme
    private var theme: ThemeManager { ThemeManager.shared }
    private var colors: ThemeColors { theme.colors }
    
    init(shape: ButtonChromeShape, @ViewBuilder content: () -> Content) {
        self.shape = shape
        self.content = content()
    }
    
    private var shapeView: some Shape {
        switch shape {
        case .capsule: return Capsule()
        case .circle: return Circle()
        }
    }
    
    private var outlineWidth: CGFloat {
        CGFloat(theme.buttonOutlineWidth)
    }
    
    private var outerRingWidth: CGFloat {
        CGFloat(theme.buttonOuterRing)
    }
    
    private var glowRadius: CGFloat {
        CGFloat(theme.buttonGlowRadius)
    }
    
    private var glowOpacity: CGFloat {
        CGFloat(theme.buttonGlowOpacity)
    }
    
    private var glowSpread: CGFloat {
        CGFloat(theme.buttonGlowSpread)
    }
    
    private var textOutlineWidth: CGFloat {
        CGFloat(theme.buttonTextOutline)
    }
    
    @ViewBuilder
    private var backgroundView: some View {
        ZStack {
            // Dark outer ring (behind everything)
            if outerRingWidth > 0 {
                shapeView
                    .fill(Color.black.opacity(0.85))
                    .padding(-outerRingWidth)
            }
            // Opaque fill
            shapeView
                .fill(Color(red: 0.118, green: 0.133, blue: 0.153))
        }
    }
    
    var body: some View {
        content
            .font(.system(size: 17, weight: .bold))
            .foregroundStyle(colors.accent)
            .modifier(TextOutlineModifier(width: textOutlineWidth))
            .padding(.horizontal, shape == .capsule ? 20 : 0)
            .padding(.vertical, shape == .capsule ? 12 : 0)
            .frame(width: shape == .circle ? 44 : nil, height: shape == .circle ? 44 : nil)
            .background(backgroundView)
            .overlay(
                shapeView
                    .stroke(colors.accent, lineWidth: outlineWidth)
            )
            .clipShape(shapeView)
            .shadow(
                color: colors.accent.opacity(glowOpacity),
                radius: glowRadius
            )
            .shadow(
                color: colors.accent.opacity(glowOpacity * 0.3),
                radius: glowRadius + glowSpread
            )
    }
}

/// Text outline modifier using multiple black shadows
struct TextOutlineModifier: ViewModifier {
    let width: CGFloat
    
    func body(content: Content) -> some View {
        if width <= 0 {
            content
        } else {
            content
                .shadow(color: .black, radius: 0, x: width, y: 0)
                .shadow(color: .black, radius: 0, x: -width, y: 0)
                .shadow(color: .black, radius: 0, x: 0, y: width)
                .shadow(color: .black, radius: 0, x: 0, y: -width)
                .shadow(color: .black, radius: 0, x: width, y: width)
                .shadow(color: .black, radius: 0, x: -width, y: width)
                .shadow(color: .black, radius: 0, x: width, y: -width)
                .shadow(color: .black, radius: 0, x: -width, y: -width)
        }
    }
}

extension View {
    func appButtonChrome(shape: ButtonChromeShape) -> some View {
        AppButtonChrome(shape: shape) { self }
    }
}