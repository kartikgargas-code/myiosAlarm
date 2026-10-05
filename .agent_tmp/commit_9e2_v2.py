#!/usr/bin/env python3
import subprocess
import sys

result = subprocess.run(['git', '-C', 'D:\\myiosAlarm', 'add', '-A'], capture_output=True, text=True)
print("git add:", result.returncode, result.stdout, result.stderr)

commit_msg = """Phase 9e-2: Control Center buttons - fix App Group + add AlarmKit reconciliation

- ExtensionAlarmSchedulingService moved to AlarmClockShared framework (buildable module)
- SmartWakeDebugLog added to AlarmClockShared for widget extension logging
- WidgetAlarmService: dynamic App Group resolution (matches NextAlarmWidgetProvider)
- Skip/Minus10/Plus10 intents: mutate engine + persist + AlarmKit reconcile for affected alarm
- Per-intent App Group debug logging (SmartWakeDebugLog)

Co-authored-by: openhands <openhands@all-hands.dev>"""

result = subprocess.run(['git', '-C', 'D:\\myiosAlarm', 'commit', '-m', commit_msg], capture_output=True, text=True)
print("git commit:", result.returncode, result.stdout, result.stderr)