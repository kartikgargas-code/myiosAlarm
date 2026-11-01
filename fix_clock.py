with open('AlarmClock/FullscreenClockView.swift', 'r') as f:
    content = f.read()

old = '.frame(maxWidth: .infinity, maxHeight: .infinity)\n\n\n\n\n                Spacer(minLength: 0)'
new = '.frame(maxWidth: .infinity, maxHeight: .infinity)\n                .contentShape(Rectangle())\n                .onLongPressGesture(minimumDuration: 1.0) {\n                    showingDiagnostics = true\n                    SmartWakeDebugLog.log("DIAGNOSTICS opened via clock")\n                    UIImpactFeedbackGenerator(style: .light).impactOccurred()\n                }\n\n\n\n                Spacer(minLength: 0)'

if old in content:
    content = content.replace(old, new)
    with open('AlarmClock/FullscreenClockView.swift', 'w') as f:
        f.write(content)
    print('Replacement done')
else:
    print('Pattern not found')