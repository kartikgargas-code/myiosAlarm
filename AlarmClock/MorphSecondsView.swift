import SwiftUI

enum MorphSecondsStyle: String, CaseIterable, Identifiable {
    case fade
    case goo
    case drip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fade: return "Fade"
        case .goo: return "Liquid"
        case .drip: return "Drip"
        }
    }
}

struct MorphSecondsView: View {
    let seconds: Int
    let color: Color
    var style: MorphSecondsStyle = .goo
    var font: Font = .subheadline
    var gooBlur: CGFloat = 2.5

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previous: Int?
    @State private var progress: Double = 1

    var body: some View {
        digitView(reduceMotion ? MorphSecondsStyle.fade : style)
            .frame(minWidth: 20, alignment: .leading)
            .onChange(of: seconds) { oldValue, _ in
                previous = oldValue
                progress = 0
                withAnimation(.easeInOut(duration: 0.35)) {
                    progress = 1
                }
            }
    }

    @ViewBuilder
    private func digitView(_ effective: MorphSecondsStyle) -> some View {
        switch effective {
        case .fade: fadeDigit
        case .goo: gooDigit
        case .drip: dripDigit
        }
    }

    private var fadeDigit: some View {
        Text("\(seconds)")
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
            .contentTransition(.opacity)
            .animation(.easeInOut(duration: 0.35), value: seconds)
    }

    private var gooDigit: some View {
        ZStack {
            if let previous {
                Text("\(previous)")
                    .font(font)
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .opacity(1 - progress)
            }
            Text("\(seconds)")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .opacity(progress)
        }
        .blur(radius: gooBlur)
        .colorEffect(Shader("gooThreshold", Float(0.5), Float(0.25)))
    }

    private var dripDigit: some View {
        ZStack {
            if let previous {
                Text("\(previous)")
                    .font(font)
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .scaleEffect(x: 1, y: 1 + 0.6 * progress, anchor: .top)
                    .offset(y: 8 * progress)
                    .opacity(1 - progress)
            }
            Text("\(seconds)")
                .font(font)
                .foregroundStyle(color)
                .monospacedDigit()
                .scaleEffect(x: 1, y: 0.85 + 0.15 * progress, anchor: .bottom)
                .offset(y: -6 * (1 - progress))
                .opacity(progress)
        }
    }
}
