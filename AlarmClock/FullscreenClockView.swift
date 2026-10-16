import SwiftUI
import UIKit
import AlarmKit
import AlarmClockShared


struct FullscreenClockView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var currentTime = Date()
    @State private var previousClockText = ""
    @State private var tickStart = Date.distantPast
    @State private var showClockSettings = false
    @State private var lastTouch = Date()
    @State private var controlsVisible = true
    private let hideAfter: TimeInterval = 5
    @AppStorage("fullscreenClockCustomR") private var customRed = -1.0
    @AppStorage("fullscreenClockCustomG") private var customGreen = -1.0
    @AppStorage("fullscreenClockCustomB") private var customBlue = -1.0
    @AppStorage("fullscreenClockScreenR") private var screenRed = -1.0
    @AppStorage("fullscreenClockScreenG") private var screenGreen = -1.0
    @AppStorage("fullscreenClockScreenB") private var screenBlue = -1.0
    @AppStorage("fullscreenClockCycle") private var colourCycle = false
    @AppStorage("fullscreenClockCycleSeconds") private var cycleSeconds = 60.0
    @AppStorage("fullscreenClockMelt") private var meltAmount = 0.02
    @AppStorage("fullscreenClockSpeed") private var meltDuration = 0.8
    @AppStorage("fullscreenClockInk") private var meltInk = 0.18




    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()




    var body: some View {
        ZStack {
            meltScreenColour(red: screenRed, green: screenGreen, blue: screenBlue)
                .ignoresSafeArea()




            VStack(spacing: 8) {
                // Next alarm line at the top
                if let nextAlarm = nextAlarmInfo {
                    Text(nextAlarm)
                        .font(.title3)
                        .foregroundStyle(ThemeManager.shared.colors.secondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.top, 24)
                        .opacity(controlsVisible ? 1 : 0)
                        .allowsHitTesting(controlsVisible)
                        .animation(.easeInOut(duration: 0.5), value: controlsVisible)
                }




                Spacer(minLength: 0)




                MeltClockView(
                    text: clockString,
                    previousText: previousClockText,
                    tickStart: tickStart,
                    duration: meltDuration,
                    color: meltColour(red: customRed, green: customGreen, blue: customBlue),
                    blurFraction: meltAmount,
                    ink: meltInk,
                    cycleSeconds: colourCycle ? cycleSeconds : 0
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)




                Spacer(minLength: 0)


            }
            .padding(.horizontal, 20)
        }
        .sheet(isPresented: $showClockSettings) {
            ClockSettingsSheet()
        }
        .safeAreaInset(edge: .bottom) {
            BottomActionsBar(
                leadingActions: [
                    .icon("Close", systemImage: "xmark", action: { dismiss() })
                ],
                trailingActions: [
                    .icon("Clock settings", systemImage: "gearshape", action: { showClockSettings = true })
                ]
            )
            .opacity(controlsVisible ? 1 : 0)
            .allowsHitTesting(controlsVisible)
            .animation(.easeInOut(duration: 0.5), value: controlsVisible)
        }
        .simultaneousGesture(TapGesture().onEnded {
            lastTouch = Date()
            controlsVisible = true
        })
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            AppDelegate.setClockLandscapeAllowed(true)
            currentTime = Date()
            previousClockText = clockString
            tickStart = Date.distantPast
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            AppDelegate.setClockLandscapeAllowed(false)
        }
        .onReceive(timer) { _ in
            let before = clockString
            currentTime = Date()
            let after = clockString
            if after != before {
                previousClockText = before
                tickStart = Date()
            }
            controlsVisible = Date().timeIntervalSince(lastTouch) < hideAfter
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
    let blurFraction: Double
    let ink: Double
    let cycleSeconds: Double


    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, at: timeline.date)
            }
        }
    }


    // Slowly walks the colour round the colour wheel; seconds <= 0 leaves it alone.
    static func cycled(_ color: Color, seconds: Double, at date: Date) -> Color {
        guard seconds > 0 else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) else { return color }
        let drift = (date.timeIntervalSince1970 / seconds).truncatingRemainder(dividingBy: 1)
        let shifted = (Double(hue) + drift).truncatingRemainder(dividingBy: 1)
        return Color(hue: shifted, saturation: Double(saturation), brightness: Double(brightness))
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


        let scale = max(0.05, min(size.width * 0.98 / totalUnits, size.height * 0.70 / 1.25))
        let fontSize = 100 * scale
        let font = Font.system(size: fontSize, weight: .thin, design: .rounded).monospacedDigit()
        let lineHeight = fontSize * 1.25
        let top = max(0, (size.height - lineHeight) / 2)
        var cursor = max(0, (size.width - totalUnits * scale) / 2)


        let t = min(max(date.timeIntervalSince(tickStart) / max(duration, 0.05), 0), 1)
        let previousCharacters = Array(previousText)
        let paint = MeltClockView.cycled(color, seconds: cycleSeconds, at: date)


        context.addFilter(.alphaThreshold(min: ink, color: paint))
        context.addFilter(.blur(radius: max(1, fontSize * blurFraction)))


        for (index, character) in characters.enumerated() {
            let outgoing: Character? = (t < 1 && index < previousCharacters.count
                                        && previousCharacters[index] != character)
                ? previousCharacters[index]
                : nil


            if let outgoing {
                context.drawLayer { layer in
                    layer.blendMode = .plusLighter
                    layer.opacity = 1 - t
                    layer.draw(
                        Text(String(outgoing)).font(font).foregroundColor(paint),
                        at: CGPoint(x: cursor, y: top),
                        anchor: .topLeading
                    )
                    layer.opacity = t
                    layer.draw(
                        Text(String(character)).font(font).foregroundColor(paint),
                        at: CGPoint(x: cursor, y: top),
                        anchor: .topLeading
                    )
                }
            } else {
                context.draw(
                    Text(String(character)).font(font).foregroundColor(paint),
                    at: CGPoint(x: cursor, y: top),
                    anchor: .topLeading
                )
            }


            cursor += units[index] * scale
        }
    }
}




private struct ClockSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss


    @AppStorage("fullscreenClockCustomR") private var customRed = -1.0
    @AppStorage("fullscreenClockCustomG") private var customGreen = -1.0
    @AppStorage("fullscreenClockCustomB") private var customBlue = -1.0
    @AppStorage("fullscreenClockScreenR") private var screenRed = -1.0
    @AppStorage("fullscreenClockScreenG") private var screenGreen = -1.0
    @AppStorage("fullscreenClockScreenB") private var screenBlue = -1.0
    @AppStorage("fullscreenClockCycle") private var colourCycle = false
    @AppStorage("fullscreenClockCycleSeconds") private var cycleSeconds = 60.0
    @AppStorage("fullscreenClockMelt") private var meltAmount = 0.02
    @AppStorage("fullscreenClockSpeed") private var meltDuration = 0.8
    @AppStorage("fullscreenClockInk") private var meltInk = 0.18


    private var chosenColour: Color {
        meltColour(red: customRed, green: customGreen, blue: customBlue)
    }


    private var chosenScreenColour: Color {
        meltScreenColour(red: screenRed, green: screenGreen, blue: screenBlue)
    }


    private var customColourBinding: Binding<Color> {
        Binding(
            get: { chosenColour },
            set: { newValue in
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                if UIColor(newValue).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                    customRed = Double(red)
                    customGreen = Double(green)
                    customBlue = Double(blue)
                }
            }
        )
    }


    private var screenColourBinding: Binding<Color> {
        Binding(
            get: { chosenScreenColour },
            set: { newValue in
                var red: CGFloat = 0
                var green: CGFloat = 0
                var blue: CGFloat = 0
                var alpha: CGFloat = 0
                if UIColor(newValue).getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
                    screenRed = Double(red)
                    screenGreen = Double(green)
                    screenBlue = Double(blue)
                }
            }
        )
    }


    var body: some View {
        NavigationStack {
            Form {
                Section {
                    MeltPreview(
                        color: chosenColour,
                        blurFraction: meltAmount,
                        ink: meltInk,
                        duration: meltDuration,
                        cycleSeconds: colourCycle ? cycleSeconds : 0
                    )
                    .frame(height: 96)
                    .listRowBackground(Color.clear)
                }


                Section("Animation") {
                    numberRow("Merging", value: $meltAmount, range: 0.0...0.06, shown: String(format: "%.3f", meltAmount))
                    numberRow("Speed", value: $meltDuration, range: 0.2...1.6, shown: String(format: "%.1f s", meltDuration))
                    numberRow("Ink", value: $meltInk, range: 0.08...0.5, shown: String(format: "%.2f", meltInk))
                }


                Section("Number colour") {
                    ColorPicker("Number colour", selection: customColourBinding, supportsOpacity: false)
                }


                Section("Screen colour") {
                    ColorPicker("Screen colour", selection: screenColourBinding, supportsOpacity: false)
                }


                Section("Colour cycle") {
                    Toggle("Colour keeps changing", isOn: $colourCycle)
                    if colourCycle {
                        numberRow("One full change", value: $cycleSeconds, range: 10...300, shown: String(format: "%.0f s", cycleSeconds))
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
        .presentationDetents([.medium, .large])
    }


    private func numberRow(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, shown: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(shown)
                    .foregroundStyle(ThemeManager.shared.colors.secondaryText)
            }
            Slider(value: value, in: range)
        }
    }
}


// A little living clock at the top of the settings, so the sliders can be tuned while watching.
private struct MeltPreview: View {
    let color: Color
    let blurFraction: Double
    let ink: Double
    let duration: Double
    let cycleSeconds: Double


    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let date = timeline.date
            let now = date.timeIntervalSince1970
            let fraction = now.truncatingRemainder(dividingBy: 1)
            let start = now - fraction
            MeltClockView(
                text: text(for: Date(timeIntervalSince1970: start)),
                previousText: text(for: Date(timeIntervalSince1970: start - 1)),
                tickStart: date.addingTimeInterval(-fraction),
                duration: duration,
                color: color,
                blurFraction: blurFraction,
                ink: ink,
                cycleSeconds: cycleSeconds
            )
        }
    }


    private func text(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss"
        return formatter.string(from: date)
    }
}


@MainActor private func meltColour(red: Double, green: Double, blue: Double) -> Color {
    red >= 0 ? Color(red: red, green: green, blue: blue) : ThemeManager.shared.colors.accent
}


@MainActor private func meltScreenColour(red: Double, green: Double, blue: Double) -> Color {
    red >= 0 ? Color(red: red, green: green, blue: blue) : ThemeManager.shared.colors.background
}




#Preview {
    FullscreenClockView()
}