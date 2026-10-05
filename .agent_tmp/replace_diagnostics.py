with open(r'D:\myiosAlarm\AlarmClock\ContentView.swift', 'r', encoding='utf-8') as f:
    content = f.read()

# Find the exact old diagnosticsView block
idx_start = content.find('private var diagnosticsView: some View {')
idx_end = content.find('    }\n    }', idx_start) + 8

new_block = (
    '    private var diagnosticsView: some View {\n'
    '        NavigationStack {\n'
    '            DiagnosticsScreen()\n'
    '                .navigationTitle("Diagnostics")\n'
    '                .toolbar {\n'
    '                    ToolbarItem(placement: .cancellationAction) {\n'
    '                        Button("Done") { showingDiagnostics = false }\n'
    '                    }\n'
    '                }\n'
    '        }\n'
    '    }\n'
    '    }'
)

content = content[:idx_start] + new_block + content[idx_end:]

with open(r'D:\myiosAlarm\AlarmClock\ContentView.swift', 'w', encoding='utf-8') as f:
    f.write(content)

print('Replaced diagnosticsView')