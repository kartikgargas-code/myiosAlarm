with open(r'D:\myiosAlarm\AlarmClockWidgetExtension\AlarmClockWidget.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# Find the exact old text
old_text = (
    '}\n\n'
    '/// Enum representing where the control can navigate\n'
    'enum AlarmDestination: String, AppEnum {\n'
    '    case nextAlarm\n\n'
    '    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Alarm Destination")\n\n'
    '    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [\n'
    '        .nextAlarm: DisplayRepresentation(\n'
    '            title: "Next Alarm",\n'
    '            subtitle: "View and control the next scheduled alarm"\n'
    '        )\n'
    '    ]\n'
    '}\n\n'
    '/// Timeline provider for the next alarm widget'
)

new_text = '}\n\n/// Timeline provider for the next alarm widget'

content = content.replace(old_text, new_text)

with open(r'D:\myiosAlarm\AlarmClockWidgetExtension\AlarmClockWidget.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print('Fixed')