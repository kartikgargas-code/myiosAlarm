import re

with open(r'D:\myiosAlarm\AlarmClock\AlarmPlaybackService.swift', 'r', encoding='utf-8') as f:
    content = f.read()

old_block = '''if playbackConfirmed {
                              do {
                                  try await AlarmManager.shared.cancel(id: snoozeID)
                                  SmartWakeDebugLog.log("SNOOZE-PLAYLIST: cancelled delayed backup alarm \\(snoozeID.uuidString)")
                              } catch {
                                  SmartWakeDebugLog.log("SNOOZE-PLAYLIST: cancel delayed backup FAILED: \\(error.localizedDescription)")
                              }
                              AlarmPlaybackService.shared.consumeSnoozeForTakeover()
                              SmartWakeService.shared.stopSilentPlayerOnly(reason: "snooze playlist takeover completed")
                          } else {
                              SmartWakeDebugLog.log("SNOOZE-PLAYLIST: playback did not confirm; delayed backup left as fallback")
                          }'''

new_block = '''if playbackConfirmed {
                              do {
                                  try await AlarmManager.shared.cancel(id: snoozeID)
                                  SmartWakeDebugLog.log("SNOOZE-PLAYLIST: cancelled delayed backup alarm \\(snoozeID.uuidString)")
                              } catch {
                                  SmartWakeDebugLog.log("SNOOZE-PLAYLIST: cancel delayed backup FAILED: \\(error.localizedDescription)")
                              }
                              // Promote to primary session for lock-screen controls (same as wake path)
                              AlarmPlaybackService.shared.promoteToPrimarySessionIfNeeded()
                              SmartWakeDebugLog.log("SNOOZE-PLAYLIST: LOCKSCREEN CONTROLS published")
                              AlarmPlaybackService.shared.consumeSnoozeForTakeover()
                              SmartWakeService.shared.stopSilentPlayerOnly(reason: "snooze playlist takeover completed")
                          } else {
                              SmartWakeDebugLog.log("SNOOZE-PLAYLIST: playback did not confirm; delayed backup left as fallback")
                          }'''

# Use flexible matching with regex
pattern = re.compile(
    r'if playbackConfirmed \{\s*'
    r'do \{\s*'
    r'try await AlarmManager\.shared\.cancel\(id: snoozeID\)\s*'
    r'SmartWakeDebugLog\.log\("SNOOZE-PLAYLIST: cancelled delayed backup alarm \\\(snoozeID\.uuidString\)"\)\s*'
    r'\}\s*'
    r'catch \{\s*'
    r'SmartWakeDebugLog\.log\("SNOOZE-PLAYLIST: cancel delayed backup FAILED: \\\(error\.localizedDescription\)"\)\s*'
    r'\}\s*'
    r'AlarmPlaybackService\.shared\.consumeSnoozeForTakeover\(\)\s*'
    r'SmartWakeService\.shared\.stopSilentPlayerOnly\(reason: "snooze playlist takeover completed"\)\s*'
    r'\}\s*'
    r'else \{\s*'
    r'SmartWakeDebugLog\.log\("SNOOZE-PLAYLIST: playback did not confirm; delayed backup left as fallback"\)\s*'
    r'\}',
    re.DOTALL
)

match = pattern.search(content)
if match:
    print("Found match at position:", match.start())
    new_content = content[:match.start()] + new_block + content[match.end():]
    with open(r'D:\myiosAlarm\AlarmClock\AlarmPlaybackService.swift', 'w', encoding='utf-8') as f:
        f.write(new_content)
    print("Replacement done!")
else:
    print("Pattern not found - trying alternative approach")
    # Try a simpler search
    idx = content.find('if playbackConfirmed {')
    if idx != -1:
        print("Found 'if playbackConfirmed {' at:", idx)
        # Find the end of this block
        brace_count = 0
        start_idx = idx
        for i in range(idx, len(content)):
            if content[i] == '{':
                brace_count += 1
            elif content[i] == '}':
                brace_count -= 1
                if brace_count == 0:
                    end_idx = i + 1
                    print("Block ends at:", end_idx)
                    print("Block content:")
                    print(content[start_idx:end_idx])
                    break
    else:
        print("Could not find 'if playbackConfirmed {'")