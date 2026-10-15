import SwiftUI

enum MorphSecondsStyle: String, CaseIterable, Identifiable {
    case fade, goo, drip
    var id: String { rawValue }
    var label: String {
        switch self {
        case .fade: return "Fade"
        case .goo:  return "Liquid"
        case .drip: return "Drip"
        }
    }
}

struct MorphSecondsView: View {
    let seconds: Int
    let color: Color
    var style: MorphSecondsStyle = .goo
    var font: Font = .subheadline

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var prevSeconds: Int? = nil
    @State private var progress: Double = 1.0

    var body: some View {
        // effective style: fade when Reduce Motion is on
        let effective: MorphSecondsStyle = reduceMotion ? .fade : style
        
        ZStack {
            switch effective {
            case .fade:  fadeDigit
            case .goo:   gooDigit
            case .drip:  dripDigit
            }
        }
        .frame(minWidth: 20, alignment: .leading)
        .onChange(of: seconds) { oldValue, newValue in
            prevSeconds = oldValue
            progress = 0.0
            withAnimation(.easeInOut(duration: 0.35)) {
                progress = 1.0
            }
        }
    }

    // Fade — exactly the baseline cross-dissolve
    private var fadeDigit: some View {
        Text("\(seconds)")
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.35), value: seconds)
    }

    // Goo — liquid merge using blur + opacity cross-fade
    private var gooDigit: some View {
        let prev = prevSeconds ?? seconds
        ZStack {
            Text("\(prev)")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .opacity(1.0 - progress)
            Text("\(seconds)")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .opacity(progress)
        }
        .blur(radius: 2.5)
        .animation(.easeInOut(duration: 0.35), value: progress)
    }

    // Drip — stretch-down + drop-in, no blur
    private var dripDigit: some View {
        let prev = prevSeconds ?? seconds
        ZStack {
            Text("\(prev)")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .scaleEffect(y: 1.0 + 0.6 * progress, anchor: .top)
                .offset(y: 8 * progress)
                .opacity(1.0 - progress)
            Text("\(seconds)")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .scaleEffect(y: 0.85 + 0.15 * progress, anchor: .bottom)
                .offset(y: -6 * (1.0 - progress))
                .opacity(progress)
        }
        .animation(.easeInOut(duration: 0.4), value: progress)
    }
}

#Preview {
    MorphSecondsView(seconds: 42, color: .accentColor, style: .goo, font: .system(size: 96, weight: .thin, design: .rounded))
}