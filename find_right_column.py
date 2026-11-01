with open('AlarmClock/ContentView.swift', 'r') as f:
    lines = f.readlines()

in_right = False
brace_count = 0
for i, line in enumerate(lines):
    if 'private func alarmRowRightColumn' in line and not in_right:
        in_right = True
        brace_count = 0
    if in_right:
        print(f'{i+1}: {line.rstrip()}')
        brace_count += line.count('{') - line.count('}')
        if brace_count <= 0 and i > 0:
            break