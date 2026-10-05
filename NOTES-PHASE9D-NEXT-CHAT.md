# NOTES for new chat — Phase 9d build (read me first)

## WHO I AM / WORKING MODE

- **You are the BUILDER in this chat. User is Kartik — talk PLAIN ENGLISH, short
  answers, say "not sure" instead of guessing APIs. You write code; Kartik tests
  on device. Never say "verified on device" — only he can verify.**
- **Repo: D:\myiosAlarm, branch phase1-validation (NEVER main). Shell = Windows
  PowerShell. AltStore-signed, no new entitlements (exception: see Task B — if
  AlarmKit needs an extra entitlement in the widget extension, STOP and report,
  do not add it silently).**
- **CI = GitHub Actions "iOS Build" (unsigned IPA every push). After each push:
  `gh run list --limit 1` → wait green → `gh run download <RUN_ID> --dir
  .\ci-artifacts` → `Get-FileHash` → report RUN_ID + IPA SHA-256. If red: read
  `gh run view <RUN_ID> --log-failed`, fix forward, never delete features.**
- **HARD LESSONS: (1) A background sync can revert edits — ALWAYS chain edit +
  `git add` + `git commit` + `git push` in ONE command. (2) file_editor
  str_replace: send ONLY path + command + old_str + new_str (view_range in the
  same call drops old_str). (3) PowerShell has NO heredoc — write .py to
  .agent_tmp and run it. (4) Swift files stay UTF-8. (5) Xcode 26/iOS 26:
  escaping closures need explicit `self.`; `import AlarmKit` where used;
  AlarmKit Alarm has NO attributes/metadata member. (6) Only report run IDs +
  IPA SHAs from GREEN runs — never invent artifacts.**
- **All 57 tests must stay green. Tests only for pure logic.**
- **First command every session: `git -C D:\myiosAlarm log --oneline -5 ; git
  -C D:\myiosAlarm status -sb` — reconcile what you find before planning.**

## CURRENT STATE (HEAD 73e374a, CI run 37304018085 GREEN, 57 tests)

- IPA SHA-256: 6A3C5C7BF3930C785295AF73BD0960E633FAE7C7C39F02E4B8A002651BBCFA3E
  (this is Kartik's CURRENT device build).
- Working: playlist-first at wake (confirmed repeatedly), snooze schedule +
  re-ring (confirmed: "SNOOZE: scheduled AlarmKit snooze ... for 5 min" and the
  alarm alerts at +5 min), random playlist now actually random at wake, sound
  picker single fileImporter works, Import Diagnostics section removed,
  AlarmClockWidget.swift rebuilt clean after duplicate-struct mangling.
- Kartik device-tested 73e374a and reports (his words, with log evidence):
  1. "toggle button is worse. i have to click 2-3 times, another issue is that
     when i click toggle it is creating new alarm clock."
  2. "snooze button pressed and banner appears but alarm time is 24hrs, i want
     time in am pm."
  3. "snooze alarm didn't fire but then backup alarm fired up." (adviser
     analysed: the snooze AlarmKit alarm DID alert — log 11:56:18
     "SCENE -> background alerting=1" — but it rang with the floor sound /
     native AlarmKit UI, which Kartik recognises as "backup". This is BY
     DESIGN: after snooze the app process cannot be guaranteed alive, so the
     guaranteed floor sound is correct. DO NOT change this. The adviser will
     explain to Kartik. If he later insists, discuss before coding.)
  4. "action buttons do appear but they don't do anything as it seems." (the
     3 Control Center buttons — see Task B.)
  5. "random from playlist is still at the bottom. move this to top."

## LOG EVIDENCE for the toggle bug (2026-10-05 11:50Z run)

```
RECONCILE(toggle): existing=14 desired=7 schedule=0 cancelling=7
RECONCILE(toggle): existing=7 desired=7 schedule=0 cancelling=0
RECONCILE(save): existing=7 desired=7 schedule=7 cancelling=7
```

- existing=14 = SEVEN alarms × TWO AlarmKit IDs each. desiredSystemAlarms
  inserts BOTH a base variant and a selectionHash variant for
  precomposed/random alarms (AlarmCoordinator.swift ~L212-217 — three
  `ids.insert(SystemScheduleID.make(...))` lines).
- SystemScheduleID.make (ExtensionAlarmSchedulingService.swift L139-151) hashes
  alarmID|fireTime|label|sound.id|loudness. For RANDOM alarms the resolved
  sound.id can DIFFER between reconciles (fresh random pick when the override
  is missing/expired) → NEW UUID each reconcile → the old AlarmKit alarm is
  cancelled and a NEW one appears in the system Clock app = Kartik's "creating
  new alarm clock" + churn every save.
- Toggle feels dead 1-3s: commit() → performCommit awaits
  desiredSystemAlarms (sound resolution, possibly precompose!) AND the full
  AlarmKit reconcile BEFORE `coordinator.alarms` reflects, so the row's Toggle
  binding re-renders with the OLD value → Kartik taps again → commits stack in
  commitQueue.

## TASKS — do ONE per commit, in this order

### TASK A (Phase 9d-1) — Toggle: instant + no AlarmKit churn (worst first)
Goal, ALL must hold on device:
  a) ONE tap flips the row immediately.
  b) Toggle OFF→ON repeatedly produces NO new AlarmKit alarm identities in the
     system Clock (log shows reconcile cancelling=0 schedule=0 on a no-op).
  c) No 14-exist states: managedSystemAlarmIDs must not carry 2 IDs per alarm
     for random/precomposed alarms.
Implementation guidance (verify with code first, adapt if wrong):
  - Investigate the THREE ids.insert lines (~L212-217) — likely collapse to ONE
    stable ID per (alarm, occurrence, kind(primary/backup)) that does NOT
    include sound.id / selectionHash. If backup-cancel logic depends on
    hashing the sound (cancelScheduledAlarms ~L713 computed ID), keep the
    sound-dependent cancel path working — cancel by scanning AlarmKit alarms'
    metadata.alarmID (Phase 7d did this) rather than by computed hash.
  - Make the random selection for an occurrence STICKY: the randomOverride
    cache (~L531-570) must persist across reconciles for the same
    occurrenceKey so sound resolution returns the same song (check
    pruneExpiredOverrides — overrides for FUTURE occurrences must NOT be
    pruned).
  - Fast-path the toggle: on setEnabled, mutate the engine + persist first,
    update the UI state, and run desiredSystemAlarms+reconcile in a
    background Task (not awaited by the UI). The reconcile itself can still
    be serialized through commitQueue.
  - Verify by testing the LOG pattern, and add one unit test for
    "no-op toggle produces identical desired IDs" if pure-logic testable.

### TASK B (Phase 9d-2) — Control Center buttons actually work
Kartik's 3 buttons (Skip / −10 / +10) appear in Control Center but do nothing.
TWO stacked root causes in the widget target (AlarmClockWidgetExtension/):
  1. App Group resolution: WidgetAlarmService.swift L14 HARDCODES
     "group.com.example.alarmclock". AltStore RENAMES the App Group (suffixes
     the team ID) and injects ALTAppGroups into Info.plist. The app handles
     this via AlarmClock/AppGroupResolver.swift (~L20, ALTAppGroups fallback);
     the widget's NextAlarmWidgetProvider (~L88-94) already replicates the
     same fallback pattern — WidgetAlarmService does NOT. Fix: apply the same
     resolution in WidgetAlarmService init (read AlarmClockAppGroupIdentifier
     from Info.plist, fall back through ALTAppGroups like
     NextAlarmWidgetProvider does). Until this is fixed the intents read/write
     the WRONG container (or none).
  2. Nothing schedules AlarmKit: the intents only mutate alarms.json via
     AlarmEngine — AlarmKit alarms are untouched, so even a correct write
     changes nothing visible. Fix properly:
     - Add ExtensionAlarmSchedulingService.swift (currently app-target only)
       to the widget extension TARGET MEMBERSHIP in project.pbxproj. It uses
       AlarmKit + AlarmClockShared and gives you reconcile(desired:managedIDs:).
     - In each intent's perform(): load snapshot → resolve next occurrence →
       engine mutation (skipNext / adjustNext) → saveSnapshot → compute
       desiredSystemAlarms for THAT alarm (reuse coordinator logic? NO — it's
       app-target and heavy; instead build the minimal DesiredSystemAlarm set
       for the single affected occurrence: cancel the alarm's existing AlarmKit
       alarms for that occurrence via AlarmManager cancel + schedule the
       replacement at the new time with the floor sound path. If computing the
       floor sound in the widget is not feasible, use a fixed built-in floor
       sound for shifted/skipped occurrences — the app re-reconciles on next
       foreground anyway and will restore the real sound.)
     - ALSO append one log line to the App Group debug log (the intents run
       outside the app — Kartik needs evidence they ran; use the same
       SmartWakeDebugLog file or a widget-actions.log in the App Group).
     - If AlarmKit scheduling from the widget extension fails (API or
       entitlement), STOP, capture the exact error text, and report — do not
       silently fall back to a fake success. Fallback plan only with Kartik's
       OK: pending-action file consumed on app foreground (NOT headless).
  - Note the existing Darwin notification bridge
    (postDarwinNotification "com.example.alarmclock.widget.changed") — keep
    posting it; the app currently has NO observer (add one later if adviser
    asks; do not add now without instruction).

### TASK C (Phase 9d-3) — Snooze banner 12-hour time
AlarmPlaybackService.swift ~L788: `formatter.dateFormat = "HH:mm"` → 24h.
Fix: use `formatter.setLocalizedDateFormatFromTemplate("j:mm a")` (respects
the user's locale — Kartik is en_IN, gives e.g. "5:26 pm"). One-line change +
test if applicable.

### TASK D (Phase 9d-4) — Sound picker: Random section to top
SoundPickerView.swift current order: Import buttons → Selected → Default →
Built-in → Imported → Random from Playlist (last). Kartik's selection is a
random playlist and he wants it near the top. New order:
  [Import buttons] [Selected (pinned)] [Random from Playlist] [Default]
  [Built-in Sounds] [Imported Sounds].
Keep everything else as-is.

## WORKFLOW PER TASK

1. Read the actual code around the anchors first (line numbers drift).
2. Minimal change; no drive-by edits; keep all 57 tests green.
3. ONE chained command: edit + git add + git commit -m "Phase 9d-X: <one line>
   Co-authored-by: openhands <openhands@all-hands.dev>" + git push.
4. Wait CI green. Report the REAL RUN_ID + IPA SHA-256 (green runs only).
5. STOP and wait for Kartik's device test before the next task.

## DEVICE FACTS (do not break)

- Playlist-first at wake, snooze schedule+re-ring, random shuffle at wake:
  all confirmed working — do not regress.
- After-snooze ring uses the AlarmKit floor sound BY DESIGN (app process
  cannot be guaranteed alive) — do not "fix" without adviser instruction.
- AlarmKit alarms can ring up to ~30s late — normal.
- Live Activity / Dynamic Island disabled on purpose (liveActivityEnabled=
  false) — do not re-enable. Loudness percentages are user-set on purpose.

## KEY FILES

- AlarmClock/AlarmCoordinator.swift — setEnabled (~L103), commit/performCommit
  (~L318-330+), desiredSystemAlarms ID inserts (~L212-217, L422, L487),
  random override resolve (~L531-570), backup cancel (~L713).
- AlarmClock/ExtensionAlarmSchedulingService.swift — reconcile (L16),
  SystemScheduleID (L139-151). App-target only today; Task B adds it to the
  widget target.
- AlarmClockWidgetExtension/WidgetAlarmService.swift — hardcoded App Group
  (L14), loadSnapshot (L27), adjustNextAlarm (L37), skipNextAlarm (L106).
- AlarmClockWidgetExtension/AlarmClockWidget.swift — 3 intents + 3 controls
  (~L399-500), postDarwinNotification (~L504), OpenNextAlarmIntent (~L73).
- AlarmClock/AlarmPlaybackService.swift — snooze banner formatter (~L788).
- AlarmClock/SoundPickerView.swift — section order (~L20-115).
- AlarmClock/AppGroupResolver.swift — the ALTAppGroups fallback pattern to
  replicate in the widget (app-target; do NOT move it into shared without
  adviser OK).
