# NOTES for new chat — Phase 9e build (read me first)

## WHO I AM / WORKING MODE

- **You are the BUILDER in this chat. User is Kartik — talk PLAIN ENGLISH, short
  answers, say "not sure" instead of guessing APIs. You write code; Kartik tests
  on device. Never say "verified on device" — only he can verify.**
- **Repo: D:\myiosAlarm, branch phase1-validation (NEVER main). Shell = Windows
  PowerShell. AltStore-signed, no new entitlements (exception: if AlarmKit
  scheduling from the widget extension requires one, STOP and report first).**
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
  IPA SHAs from GREEN runs — never invent artifacts. (7) 57 tests must stay
  green; tests only for pure logic.**
- **First command every session: `git -C D:\myiosAlarm log --oneline -8 ; git
  -C D:\myiosAlarm status -sb` — reconcile before planning.**

## CRITICAL CONTEXT: Kartik's last device build was STALE

- HEAD today = 92346ce (Phase 9d-1, CI run 37313003712 GREEN).
- Kartik's device test (log 13:14-13:23Z) was run on build 73e374a — the
  PREVIOUS green build — because ba77f54's CI failed (no IPA) and 92346ce's IPA
  appeared AFTER his test window.
- That explains why he reports: banner still 24h (Task C never shipped), Random
  section still bottom (Task D never shipped), action buttons dead (Task B
  never shipped). ONLY 9d-1 (Task A) was ever implemented.
- So: do NOT assume 9d-1 is bad yet — it has never been device-tested. But DO
  verify its semantics (Task A2 below) because his log raised a counting
  question.
- Your FIRST deliverable: green build of current HEAD → give Kartik the IPA →
  he installs and re-tests BEFORE you write more code. Tasks below then apply
  on top, one per commit.

## TASKS — one per commit, in this order

### TASK 0 (Phase 9e-0) — Verify + hand over current HEAD
- Confirm 92346ce is green; download its IPA; report RUN_ID + IPA SHA-256.
- Audit 9d-1 semantics (no code yet): read
  AlarmCoordinator.swift performCommit/desiredSystemAlarms and answer:
  does `existing=14` just mean 7 alarms × (primary + -BACKUP) = 14 AlarmKit
  alarms (NORMAL), or true duplicates? Kartik's log: "RECONCILE(save):
  existing=7 desired=14 schedule=7 cancelling=7" then "existing=14 desired=14
  schedule=7 cancelling=7" then "RECONCILE(toggle): existing=14 desired=7
  schedule=0 cancelling=7".
- THE acceptance criterion for the whole churn problem (report against this):
  a no-op SAVE or toggle must log `schedule=0 cancelling=0`. If 9d-1 already
  achieves it, say so; if not, fix in Task A2.
- Then STOP → Kartik installs + re-tests → following tasks resume.

### TASK A2 (Phase 9e-1) — Save/toggle must be instant (0 AlarmKit RPCs on no-op)
- Root cause of the ~1s save: every save runs schedule=7 cancelling=7 (seven
  AlarmKit cancels + seven schedules) because SystemScheduleID
  (ExtensionAlarmSchedulingService.swift L139-151) hashes the RESOLVED sound,
  and random-playlist alarms re-resolve a different song per reconcile → new
  UUID every save → full cancel+recreate churn → iOS Clock shows "new alarm".
- FIX: make IDs stable per (alarm, occurrence, kind) — remove sound.id (and
  selectionHash) from the ID hash; make the random selection STICKY per
  occurrenceKey (randomOverride must persist for FUTURE occurrences — check
  pruneExpiredOverrides doesn't kill them). Keep backup-cancel working: it
  cancels by scanning AlarmKit alarms' metadata.alarmID (Phase 7d pattern) —
  verify cancelScheduledAlarms (~L713) does NOT depend on the removed hash
  inputs; if it does, convert it to the metadata scan.
- ACCEPTANCE: no-op toggle/save → "schedule=0 cancelling=0"; save is
  instant (no 7-alarm reschedule); system Clock keeps the same alarm entries.
- Add a pure-logic unit test: same occurrence + same engine state → identical
  desired IDs across two reconciles even when random re-resolves.

### TASK B (Phase 9e-2) — Control Center buttons: never shipped, build it
Kartik's 3 Control Center buttons (Skip / −10 / +10) appear but do nothing.
Two stacked causes (verified in code):
  1. AlarmClockWidgetExtension/WidgetAlarmService.swift L14 HARDCODES
     "group.com.example.alarmclock" — AltStore RENAMES the App Group
     (team-ID suffix) and injects ALTAppGroups into Info.plist. The app
     resolves via AlarmClock/AppGroupResolver.swift (~L20); the widget's
     NextAlarmWidgetProvider (AlarmClockWidget.swift ~L88-94) already has the
     correct fallback pattern. FIX: apply that same resolution in
     WidgetAlarmService init. Until then intents read/write the WRONG
     container.
  2. The intents only mutate alarms.json — nothing re-schedules AlarmKit, so
     even a correct write changes no alarm. FIX:
     - Add AlarmClock/ExtensionAlarmSchedulingService.swift to the widget
       extension target membership (project.pbxproj) — it gives
       reconcile(desired:managedIDs:) with AlarmKit.
     - In each intent perform(): load snapshot → find the affected
       occurrence → engine mutation (skipNext / adjustNext) → saveSnapshot →
       reconcile AlarmKit for that alarm (cancel its existing AlarmKit
       alarms, schedule replacement at the new time with a floor sound — for
       the widget use a fixed built-in floor sound if resolving the mp3 sound
       is not feasible; the app re-reconciles on next foreground and restores
       the real sound).
     - Append one log line per intent run to a widget-actions.log in the App
       Group (intents run outside the app; Kartik needs evidence). Keep the
       existing Darwin notification post.
     - If AlarmKit scheduling from the widget extension fails (API or
       entitlement), capture the exact error, report, and STOP — fallback
       (pending-action file consumed on app foreground) only with Kartik's OK.

### TASK C (Phase 9e-3) — Snooze banner + widget refresh
In AlarmClock/AlarmPlaybackService.swift (~L785-800):
  a) 12-hour time: replace `formatter.dateFormat = "HH:mm"` with
     `formatter.setLocalizedDateFormatFromTemplate("j:mm a")` (Kartik is
     en_IN → "5:26 pm"). NOTE: iOS controls notification FONT size — we
     cannot make it bigger; do not attempt.
  b) Banner must disappear when the snoozed alarm fires: when the app detects
     the snooze AlarmKit alarm alerting (the same alarmUpdates/alerting
     detection the wake path uses — SmartWakeService), call
     UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers:)
     for the "SNOOZE-<id>" identifier. Honest caveat (tell Kartik): if the app
     process is dead at fire time, the banner can't be removed and iOS keeps
     it until dismissed.
  c) Lock-screen widget didn't refresh after snooze: when the snooze alarm is
     scheduled, ALSO write nextAlarmSnapshot.json (next fire = snooze date,
     same shape the app writes elsewhere — find writeNextAlarmSnapshot /
     NextAlarmSnapshot usage) and call WidgetCenter.shared.reloadAllTimelines()
     from the APP so the widget shows the snoozed ring time immediately. Do
     the same on handleStopCommand so the widget returns to the regular next
     alarm.

### TASK D (Phase 9e-4) — Picker: Random section near top
SoundPickerView.swift current order: Selected (91) → Import (102) → Default
(128) → Built-in (137) → Imported (148) → Random from Playlist (159, LAST).
Kartik's selection IS a random playlist; move the section right after the
pinned Selected one. New order: Selected → Import → Random from Playlist →
Default → Built-in Sounds → Imported Sounds → (Import Error when present).

### TASK E (Phase 9e-5) — Alarm row + editor fixes
1. Edit prefill bug: Kartik edits an alarm and the sound picker shows
   "Default" instead of the previously selected sound. AlarmEditorView.swift
   L53 inits `@State selectedSound` from `existingAlarm?.sound` — but
   @State(initialValue:) only applies at FIRST view init; if the sheet is
   re-presented for a DIFFERENT alarm without changing view identity, the
   stale first value persists. FIX: force fresh identity per alarm — add
   `.id(existingAlarm.id)` (or the editorAlarm's id) on the editor root view
   inside the sheet presentation (ContentView sheet + anywhere
   AlarmEditorView is presented), OR re-sync selectedSound in .onAppear/
   .onChange. Verify the edit flow shows the stored sound (including Random).
2. Remove the explicit "Edit" text button on the alarm row
   (ContentView.swift ~L300-313). Make tapping ANYWHERE on the row open the
   editor (onTapGesture → editorAlarm = alarm; showingEditor = true). Keep
   the Toggle and the context menu.
3. Accent-color the row subtitle texts ("everyday", "Next=<date time>") —
   they currently use colors.secondaryText; switch to
   ThemeManager.shared.colors.accent.

### TASK F (Phase 9e-6) — Playlist after snooze (Kartik asked twice — build it)
Today the snoozed re-ring is a native AlarmKit alarm with the floor sound
(Kartik sees "backup with fullscreen"). Upgrade: if our app process is STILL
ALIVE at snooze-fire time, give playlist-first for the re-ring too.
- In handleSnoozeCommand (AlarmPlaybackService ~L729): after scheduling the
  AlarmKit snooze alarm, RESTART the silent loop (SmartWakeService
  startIfReadyForeground) so the process stays alive during the snooze
  window.
- In SmartWakeService's AlarmKit alarmUpdates/alerting handling: treat alarms
  whose metadata.occurrenceKey starts with "SNOOZE-" like a wake event:
  start the playlist (playlist-first takeover), cancel/silence the AlarmKit
  snooze alarm, re-arm normally afterwards. Keep the wake-key logic
  consistent (alarmID|fireTime keys).
- Fallback unchanged: if the app was killed anyway, the AlarmKit floor sound
  rings (guaranteed). That is the correct degradation — do not fight iOS.
- Log lines: "SNOOZE-TAKEOVER: starting playlist for <key>" / on failure
  explain why.

## WORKFLOW PER TASK

1. Read the actual code around the anchors first (line numbers drift).
2. Minimal change; no drive-by edits; keep all 57 tests green.
3. ONE chained command: edit + git add + git commit -m "Phase 9e-X: <one line>
   Co-authored-by: openhands <openhands@all-hands.dev>" + git push.
4. Wait CI green. Report the REAL RUN_ID + IPA SHA-256 (green runs only).
5. STOP and wait for Kartik's device test before the next task.

## DEVICE FACTS (do not break)

- Playlist-first at wake, snooze schedule+re-ring, random shuffle at wake,
  single fileImporter import, Import Diagnostics removed: all confirmed.
- After-snooze ring uses the AlarmKit floor sound when the app is dead —
  guaranteed fallback, keep it.
- AlarmKit alarms can ring up to ~30s late — normal.
- Live Activity / Dynamic Island disabled on purpose
  (liveActivityEnabled=false) — do not re-enable.
- Loudness percentages are user-set on purpose.
