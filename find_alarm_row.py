with open('AlarmClock/ContentView.swift', 'r') as f:
    lines = f.readlines()

in_alarm_row = False
brace_count = 0
for i, line in enumerate(lines):
    if 'private func alarmRow' in line and not in_alarm_row:
        in_alarm_row = True
        brace_count = 0
    if in_alarm_row:
        print(f'{i+1}: {line.rstrip()}')
        brace_count += line.count('{') - line.count('}')
        if brace_count <= 0 and i > 0:
            break