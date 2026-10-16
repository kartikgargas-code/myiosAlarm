import SwiftUI
import AlarmKit
import AlarmClockShared


struct FullscreenClockView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentTime = Date()
    @State private var previousClockText = ""
    @State private var tickStart = Date.distantPast
    @State private var showClockSettings = false
    @AppStorage("fullscreenClockTint") private var clockTint = "accent"




    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let meltDuration: Double = 0.8




    var body: some View {
        ZStack {
            ThemeManager.shared.colors.background
                .ignoresSafeArea()




            VStack(spacing: 8) {
                // Next alarm line at the top
                if let nextAlarm = nextAlarmInfo {
                    Text(nextAlarm)
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                }




                Spacer(minLength: 0)




                MeltClockView(
                    text: clockString,
                    previousText: previousClockText,
                    tickStart: tickStart,
                    duration: meltDuration,
                    color: clockColor
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)




                Spacer(minLength: 0)




                // X bottom left, clock settings bottom right
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            .padding(16)
                    }
                    .buttonStyle(.plain)




                    Spacer()




                    Button {
                        showClockSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                            .padding(16)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
        }
        .sheet(isPresented: $showClockSettings) {
            ClockSettingsSheet(tint: $clockTint)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            currentTime = Date()
            previousClockText = clockString
            tickStart = Date.distantPast
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(timer) { _ in
            let before = clockString
            currentTime = Date()
            let after = clockString
            if after != before {
                previousClockText = before
                tickStart = Date()
            }
        }
    }




    private var clockColor: Color {
        switch clockTint {
        case "white": return .white
        case "amber": return Color(red: 1.0, green: 0.72, blue: 0.20)
        case "cyan": return Color(red: 0.25, green: 0.85, blue: 1.0)
        case "green": return Color(red: 0.35, green: 0.95, blue: 0.55)
        case "violet": return Color(red: 0.72, green: 0.55, blue: 1.0)
        case "red": return Color(red: 1.0, green: 0.42, blue: 0.42)
        default: return ThemeManager.shared.colors.accent
        }
    }




    private var clockString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss"
        return formatter.string(from: currentTime)
    }




    private var nextAlarmInfo: String? {
        // Get the next alarm from the coordinator's published nextOccurrence
        guard let coordinator = AlarmCoordinator.sharedInstance,
              let nextOccurrence = coordinator.nextOccurrence,
              let alarm = coordinator.currentEngine.alarm(id: nextOccurrence.alarmID) else {
            return nil
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE h:mm a"
        let timeString = formatter.string(from: nextOccurrence.effectiveDate)
        let label = alarm.label.isEmpty ? "Alarm" : alarm.label
        return "Next alarm: \(label) at \(timeString)"
    }
}




// The whole time is drawn in ONE canvas: it can never wrap, every character shares one
// baseline, and the size is worked out from the space available, so it fits portrait,
// landscape and the big landscape font alike.
private struct MeltClockView: View {
    let text: String
    let previousText: String
    let tickStart: Date
    let duration: Double
    let color: Color




    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, at: timeline.date)
            }
        }
    }




    private func draw(_ context: inout GraphicsContext, size: CGSize, at date: Date) {
        let characters = Array(text)
        guard !characters.isEmpty, size.width > 40, size.height > 40 else { return }


        let probe = Font.system(size: 100, weight: .thin, design: .rounded).monospacedDigit()
        var units: [CGFloat] = []
        units.reserveCapacity(characters.count)
        for character in characters {
            let resolved = context.resolve(Text(String(character)).font(probe))
            let measured = resolved.measure(in: CGSize(width: 1000, height: 1000)).width
            units.append(max(measured, 1))
        }
        let totalUnits = units.reduce(0, +)
        guard totalUnits > 0 else { return }


        // fit the width, but never let the line take more than ~70% of the height
        let scale = max(0.05, min(size.width * 0.98 / totalUnits, size.height * 0.70 / 1.25))
        let fontSize = 100 * scale
        let font = Font.system(size: fontSize, weight: .thin, design: .rounded).monospacedDigit()
        let lineHeight = fontSize * 1.25
        let top = max(0, (size.height - lineHeight) / 2)
        var cursor = max(0, (size.width - totalUnits * scale) / 2)


        let t = min(max(date.timeIntervalSince(tickStart) / duration, 0), 1)
        let previousCharacters = Array(previousText)


        // The cut-off must be low: in the middle of a change both glyphs are half strength, and a high
        // cut-off throws both of them away - that is what made the melt look like a blink/fade.
        // Constant fill colour is REQUIRED here: the default is black, which is invisible.
        context.addFilter(.alphaThreshold(min: 0.18, color: color))
        context.addFilter(.blur(radius: max(1, fontSize * 0.02)))


        for (index, character) in characters.enumerated() {
            let outgoing: Character? = (t < 1 && index < previousCharacters.count
                                        && previousCharacters[index] != character)
                ? previousCharacters[index]
                : nil


            if let outgoing {
                // Both glyphs go into ONE layer, in the same place, with opacities that add up to 1.
                // The layer as a whole is what gets blurred and cut off, so the two shapes are seen
                // together and the outline travels from the old digit into the new one.
                context.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    layer.opacity = 1 - t
                    layer.draw(
                        Text(String(outgoing)).font(font).foregroundColor(color),
                        at: CGPoint(x: cursor, y: top),
                        anchor: .topLeading
                    )
                    layer.opacity = t
                    layer.draw(
                        Text(String(character)).font(font).foregroundColor(color),
                        at: CGPoint(x: cursor, y: top),
                        anchor: .topLeading
                    )
                }
            } else {
                context.draw(
                    Text(String(character)).font(font).foregroundColor(color),
                    at: CGPoint(x: cursor, y: top),
                    anchor: .topLeading
                )
            }


            cursor += units[index] * scale
        }
    }
}




// Settings button on the clock screen: colour of the numbers.
private struct ClockTintOption: Identifiable {
    let id: String
    let name: String
    let color: Color
}




private struct ClockSettingsSheet: View {
    @Binding var tint: String
    @Environment(\.dismiss) private var dismiss




    private let options: [ClockTintOption] = [
        ClockTintOption(id: "accent", name: "App colour", color: ThemeManager.shared.colors.accent),
        ClockTintOption(id: "white", name: "White", color: .white),
        ClockTintOption(id: "amber", name: "Amber", color: Color(red: 1.0, green: 0.72, blue: 0.20)),
        ClockTintOption(id: "cyan", name: "Cyan", color: Color(red: 0.25, green: 0.85, blue: 1.0)),
        ClockTintOption(id: "green", name: "Green", color: Color(red: 0.35, green: 0.95, blue: 0.55)),
        ClockTintOption(id: "violet", name: "Violet", color: Color(red: 0.72, green: 0.55, blue: 1.0)),
        ClockTintOption(id: "red", name: "Red", color: Color(red: 1.0, green: 0.42, blue: 0.42))
    ]




    var body: some View {
        NavigationStack {
            List {
                Section("Number colour") {
                    ForEach(options) { option in
                        HStack {
                            Circle()
                                .fill(option.color)
                                .frame(width: 22, height: 22)
                            Text(option.name)
                                .foregroundStyle(ThemeManager.shared.colors.primaryText)
                            Spacer()
                            if tint == option.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(ThemeManager.shared.colors.accent)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { tint = option.id }
                    }
                }
            }
            .navigationTitle("Clock")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}




#Preview {
    FullscreenClockView()
}