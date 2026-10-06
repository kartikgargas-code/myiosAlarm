# NOTES for new chat — Phase 9k (read me first)

## ⚠️ PROCESS RULES (these keep being broken)

1. **Do ALL tasks in this round, ONE COMMIT PER TASK, push them all, then report
   once and stop.** Three earlier rounds shipped only the first task and silently
   dropped the rest, which wasted a full install + device-test cycle each time.
2. **CI is flaky — always confirm the run is GREEN before reporting.** Recent runs
   373, 375 and 377 were RED. Latest green: **378** (`3cafb1e`). A red run means no
   IPA exists, so fix forward before starting anything else.
3. **Report `RUN_ID` + run number + IPA SHA-256 from a green run.** The run number
   IS the app's build number.

## WHO I AM / WORKING MODE

- **You are the BUILDER. User is Kartik — talk PLAIN ENGLISH, short answers, say
  "not sure" instead of guessing APIs. You write code; Kartik tests on device.
  Never say "verified on device" — only he can verify.**
- **Repo: D:\myiosAlarm, branch phase1-validation (NEVER main). Shell = Windows
  PowerShell. AltStore-signed, no new entitlements without asking first.**
- **HARD LESSONS: (1) ALWAYS chain edit + `git add` + `git commit` + `git push`
  in ONE command. (2) PowerShell has NO heredoc — write a .py to .agent_tmp; long
  `Select-String`/`gh run view --log` calls wedge the terminal. (3) Swift files
  stay UTF-8. (4) Xcode 26/iOS 26: escaping closures need explicit `self.`;
  `import AlarmKit` where used; AlarmKit `Alarm` exposes NO attributes/metadata.
  (5) Shared-module types the widget constructs need explicit `public init`.
  (6) xcodegen: **project.yml is the source of truth**. (7) 57 tests stay green.
  (8) Check string interpolation manually — see item 1 below.**
- **First command every session: `git -C D:\myiosAlarm log --oneline -8 ; git -C
  D:\myiosAlarm status -sb`.**

## DO NOT DO THESE (Kartik explicitly declined them)

- Do **NOT** enable the Live Activity / Dynamic Island (deliberately disabled).
- Do **NOT** add lock-screen artwork / "big artwork".
- Do **NOT** change the lock-screen remote-command buttons (previous / play-pause /
  next). Kartik explicitly skipped options A, B and C.

## VERIFIED WORKING (build ~378 unless noted)

- Control Center skip / ±10 through the pending-action queue, with toast/notification
  feedback (`CC FEEDBACK notification posted: Alarm moved -10 min · next 5:11 PM`).
- Snooze: silent loop kept alive for the whole window, playlist starts at the true
  snooze time, delayed floor alarm cancelled before it rings, and lock-screen
  controls are published (`SNOOZE-PLAYLIST: LOCKSCREEN CONTROLS published`).
- Snooze notification is one line now. Toggle 7–45 ms, save 45–74 ms.
- Imported sound names cleaned, durations present.

## OPEN ITEMS — with the evidence

### 0. CORRECTION to an earlier theory — read before touching scheduling
Kartik confirms he has **ONE** user alarm, yet the new instrumentation logs:
```
DESIRED ITEM: occurrenceKey=2026-10-13-BACKUP kind=BACKUP effectiveDate=2026-10-13 11:41:30
DESIRED ITEM: occurrenceKey=2026-10-14-BACKUP kind=BACKUP effectiveDate=2026-10-14 11:41:30
DESIRED ALARMS SUMMARY: total=7 primary=0 backup=7 userAlarms=7
```
So the app is **pre-scheduling ~7 daily occurrences of a single alarm** (note the
consecutive dates), i.e. one AlarmKit alarm per day for about a week. The
`userAlarms=7` label is **misleading** — it is not 7 user alarms; rename it. This
is almost certainly what Kartik sees as "entries I didn't create" in the iOS Clock.
**Decide how many future occurrences should be armed — likely the next one only —
and confirm with Kartik before changing it.** Log the occurrence horizon too.

### 1. Logging was printing Swift source (BLOCKING — verify the fix landed)
For several rounds a log line printed the literal text
`count=\(idsAfterWidget.count) ids=\(idsAfterWidget.map { … })`. Commit `3cafb1e`
claims a fix using raw string literals — **verify on device that real numbers now
appear**, and check every other `SmartWakeDebugLog.log(...)` you added for the same
mistake. The duplicate-alarm investigation has produced **zero** usable data so far
because of this.

### 2. Duplicate alarm entry — still unexplained
Reported four times, most recently "not this time". With item 1 fixed, actually
**read the instrumentation output** (alarm IDs + counts before/after save, delete
and widget apply, and `ALARM ENGINE UPSERT: ADD` vs `UPDATE`) and **report the
findings before changing logic**.

### 3. Control Center feedback shows TWO banners
Kartik gets the in-app toast (top, auto-hides — good) **and** a local notification
(bottom, stays in Notification Center). Show only one: **foreground → toast only,
no notification; background → notification only.** If you can also
`removeDeliveredNotifications` ~6 s later while the app is running, do it; otherwise
document that iOS keeps delivered notifications until dismissed.

### 4. Snooze: delayed backup cancel FAILED, playlist started 2 s late
```
SNOOZE-PLAYLIST: started playlist at true snooze time 11:46:20
SNOOZE-PLAYLIST: cancel delayed backup FAILED: (com.apple.AlarmKit.Alarm error 0.)
```
The parked floor alarm survived, so it could ring after the playlist starts. Add a
retry (a few attempts with a short delay) so the delayed alarm is always cancelled
once playback is confirmed, and log its id so we can match it.

### 5. Play History STILL does not delete the song's mp3 (asked 3 times)
Clear-all landed; the file survives. `PlayHistoryEntry` (`AlarmModel.swift` ~L472)
stores only `songName` — add an optional `soundID`/stored file name (backward
compatible; existing history must still decode) and remove the file via
`SoundLibrary` on a "Delete + Song" action. Refuse/warn if a playlist uses it.

### 6. "Imported Sounds" list: still not compact, subtitle still there
`SoundPickerView.swift` still shows `"Imported from Files"` (~L49, ~L178, ~L429).
Kartik wants that subtitle **gone** and the rows **compact** (smaller vertical
insets, keep the font size) so more tracks fit per screen. If the left play button
still does not actually stop/pause playback, fix the toggle too (the button state
must match reality).

## NEW FEATURES — one commit each

### TASK A — duplicate an alarm from the row's long-press menu
`ContentView.swift` alarm row `contextMenu` already has Custom Time / ±10 min /
Reset etc. **Add "Duplicate"** (Kartik calls it "hold alarm list"). It should copy
the alarm with a **new id**, keep label/time/repeat/sound/loudness/snooze but clear
per-occurrence overrides, insert it, and re-arm through the normal commit path.
Test on device: the copy must appear once (no duplicates) and arm correctly.

### TASK B — back up and restore the whole app
Kartik wants to export and re-import alarms **and imported sounds**. Design notes:
- one archive (zip) containing the alarm store, playlists, user themes, display-name
  overrides, and the imported audio files plus their metadata;
- **Export** via `.fileExporter` to a single file the user can save/share;
- **Restore** via `.fileImporter`, then re-register the imported sounds with the
  SoundLibrary so ids/playlists still resolve, re-arm alarms, and mirror to the
  App Group so the widget is correct;
- be defensive: validate the archive, handle id collisions, and never destroy the
  current data on a failed/partial import (import into a validated staging state
  first, or offer merge vs replace);
- show progress while importing, since many mp3s can be large.
Keep it self-contained: no new entitlements, no network.

## DEVICE FACTS (do not break)

- Playlist-first at wake and the delayed-backup snooze re-ring: confirmed working.
- Hard iOS rule from the logs: a **background** app cannot *start* an audio session,
  only continue one (`561015905` = `!pla`, `560557684` = `!int`). The silent loop
  must already be alive before a ring — `FOREGROUND START: snooze window pending`
  handles that; keep it.
- The widget extension can NEVER obtain AlarmKit authorization
  (`state=notDetermined`) — the app must always be the one that schedules.
- AlarmKit alarms can ring up to ~30 s late — normal.
- Live Activity / Dynamic Island stay disabled. Loudness percentages are user-set
  on purpose. The AlarmKit floor sound is the guaranteed fallback when the app is
  dead.
- The debug log is a 300-line ring buffer; keep per-tick logging out of it.
