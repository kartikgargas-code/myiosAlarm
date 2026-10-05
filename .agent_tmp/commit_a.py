#!/usr/bin/env python3
import subprocess
import sys

# Git add and commit
result = subprocess.run(['git', '-C', 'D:\\myiosAlarm', 'add', '-A'], capture_output=True, text=True)
print("git add:", result.returncode, result.stdout, result.stderr)

commit_msg = """Phase 9d-1: Toggle instant + no AlarmKit churn (fix 14-exist states, sticky random, fast-path toggle)

- candidateScheduleIDs: collapse 3 IDs -> 1 stable ID per (alarm, occurrence, kind) without sound.id/selectionHash
- SystemScheduleID.make: remove sound.id from key, add kind (primary/backup) for stable IDs
- pruneExpiredOverrides: keep ALL future occurrences so random overrides persist across reconciles
- setEnabled: fast-path UI flip via engine+persist+publish BEFORE background reconciliation

Co-authored-by: openhands <openhands@all-hands.dev>"""

result = subprocess.run(['git', '-C', 'D:\\myiosAlarm', 'commit', '-m', commit_msg], capture_output=True, text=True)
print("git commit:", result.returncode, result.stdout, result.stderr)