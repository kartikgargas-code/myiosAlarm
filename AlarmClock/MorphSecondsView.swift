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
    var canvasWidth: CGFloat = 26
    var canvasHeight: CGFloat = 22

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var previous: Int?
    @State private var progress: Double = 1
    @State private var transitionStart: Date?

    var body: some View {
        digitView(reduceMotion ? MorphSecondsStyle.fade : style)
            .frame(minWidth: 20, alignment: .leading)
            .onChange(of: seconds) { oldValue, _ in
                previous = oldValue
                progress = 0
                transitionStart = Date()
                withAnimation(.easeInOut(duration: 0.35)) {
                    progress = 1
                }
            }
    }

    private func gooProgress(asOf date: Date) -> Double {
        guard let start = transitionStart else { return 1 }
        return min(max(date.timeIntervalSince(start) / 0.35, 0), 1)
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
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                let t = gooProgress(asOf: timeline.date)
                let drop = size.height * 0.12

                // Order is load-bearing: blur is applied to the raw draw first,
                // then alphaThreshold re-solidifies it, so shapes MERGE like liquid.
                context.addFilter(.alphaThreshold(min: 0.5))
                context.addFilter(.blur(radius: max(2, size.height * 0.055)))

                context.opacity = 1 - t
                if let previous {
                    context.draw(
                        Text("\(previous)").font(font).foregroundColor(color),
                        at: CGPoint(x: size.width / 2, y: size.height / 2 + drop * t),
                        anchor: .center
                    )
                }

                context.opacity = t
                context.draw(
                    Text("\(seconds)").font(font).foregroundColor(color),
                    at: CGPoint(x: size.width / 2, y: size.height / 2 - drop * (1 - t)),
                    anchor: .center
                )
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .alignmentGuide(.firstTextBaseline) { _ in canvasHeight * 0.80 }
        }
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
