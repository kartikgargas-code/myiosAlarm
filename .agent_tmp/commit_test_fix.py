#!/usr/bin/env python3
import subprocess
import sys

commit_msg = """Phase 9d-1: Fix test for stable SystemScheduleID (sound no longer changes ID)

Co-authored-by: openhands <openhands@all-hands.dev>"""

result = subprocess.run(['git', '-C', 'D:\\myiosAlarm', 'commit', '-m', commit_msg], capture_output=True, text=True)
print("git commit:", result.returncode, result.stdout, result.stderr)