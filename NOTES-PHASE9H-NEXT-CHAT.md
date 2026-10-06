# NOTES for new chat — Phase 9h (read me first)

## ⚠️ PROCESS FIX FIRST — READ THIS BEFORE PLANNING

**The last three rounds shipped only the first task and stopped:**

- **round A → `eed3595` (9f-1, Control Center) — nothing else**
- **round B → `aea9bc9` (9g-1, snooze delayed backup) — nothing else**

**Everything else in those notes was silently dropped, so Kartik waited a full
install + device-test cycle per single task and kept reporting the same missing
features. Do not do that again.**

**RULE FOR THIS ROUND: implement EVERY task below, as ONE COMMIT PER TASK, push
them all in sequence, then STOP once and let Kartik test them together. Only
stop early if a task is explicitly gated on a report-back, or CI goes red.**

## WHO I AM / WORKING MODE

- **You are the BUILDER. User is Kartik — talk PLAIN ENGLISH, short answers, say
  "not sure" instead of guessing APIs. You write code; Kartik tests on device.
  Never say "verified on device" — only he can verify.**
- **Repo: D:\\myiosAlarm, branch phase1-validation (NEVER main). Shell = Windows
  PowerShell. AltStore-signed, no new entitlements without asking first.**
- **HARD LESSONS: (1) ALWAYS chain edit + `git add` \+ `git commit` \+ `git push`
  in ONE command — a background sync can revert edits. (2) PowerShell has NO
  heredoc — write a .py to .agent_tmp and run it; long `Select-String`/ `gh run
  view --log` calls wedge the shared terminal. (3) Swift files stay UTF-8. (4)
  Xcode 26/iOS 26: escaping closures need explicit `self.`; `import AlarmKit`
  where used; AlarmKit `Alarm` exposes NO attributes/metadata member. (5)
  Shared-module types the widget constructs need an explicit `public init`. (6)
  xcodegen: project.yml is the source of truth — never hand-edit
  project.pbxproj. (7) 57 tests stay green.**
- **First command every session: `git -C D:\\myiosAlarm log --oneline -8 ; git
  \-C D:\\myiosAlarm status -sb` — reconcile before planning.**

## BUILD-IDENTITY RULE

- `CFBundleVersion`** = the GitHub Actions run number; the app logs `BUILD: v1.0
  (\<run#>) commit=\<sha>` once at launch.**
- **Never tell Kartik to test without the RUN NUMBER. Report `RUN_ID` \+ run
  number + IPA SHA-256, green runs only, and confirm green before reporting.**
- **Green builds so far: 348, 352, 356, 357 (`eed3595`), 358 (`aea9bc9`, run
  37408299445 — the one Kartik just tested). Runs 349–353 were red; a red run
  means no IPA exists, so fix forward before anything else.**

## VERIFIED WORKING ON BUILD 358 (from Kartik's device log — trust this)

- **Snooze re-ring is now playlist-first with NO floor alarm. The
  delayed-backup architecture works exactly as designed: `SNOOZE: scheduled
  DELAYED backup alarm … at 04:05:37 (true snooze 04:05:07)` → `PLAYBACK started
  track 1: Let It Be …` → `SNOOZE-PLAYLIST: started playlist at true snooze time
  04:05:07` → `SNOOZE-PLAYLIST: cancelled delayed backup alarm` → and it
  advanced to track 2. Kartik heard his playlist, not the floor sound. This is
  now the proven pattern — reuse it, never regress it.**
- **Control Center skip / ±10 still work through the pending-action queue.**
- **Toggle, save (39–63 ms), sticky precompose, no duplicate alarms from the
  editor, row tap opens the editor, imported names cleaned, song durations
  present.**

## OPEN ITEMS SEEN IN THE 358 LOG

### A. Snooze playlist plays with NO lock-screen controls

**The new `SNOOZE-PLAYLIST` path in `AlarmPlaybackService` (~L820-855) starts
playback but never calls `promoteToPrimarySessionIfNeeded()`, so no Now Playing
/ lock-screen controls are published — the wake path does call it (`
SmartWakeService.swift` ~L989, ~L1067, ~L190) and logs `LOCKSCREEN CONTROLS
published`. Fix this in the snooze path too (there is a `self`\-capture/ordering
constraint here — follow the wake path's order).**

### B. Duplicate alarm entry — again (needs instrumentation, do NOT guess)

**Kartik reports a duplicate list entry appearing when he taps Save in the
alarm editor. The 9e-8a guard is still intact in `AlarmEditorView` (`isSaving`, `
draftID`, `existingAlarm?.id ?? draftID` at ~L240-256), so a double-tap should
now upsert the same draft and cannot create a second alarm — which means the
extra record comes from somewhere else. Instrument before changing logic:**

- **log the alarm count + the full alarm ID list immediately before and after
  every `save` and `delete` commit, and after every widget action apply;**
- **log in `AlarmEngine.upsert` when an alarm is *added* (id not already
  present) versus updated, with the id;**
- **capture whether any other writer (widget pending-action apply, App Group
  reload, legacy decoder) adds a record. Report the findings before writing a
  fix.**

### C. Lock-screen widget still not refreshed after a Control Center action

**The action now applies, but the lock-screen widget kept the old time. The app
does write `nextAlarmSnapshot.json` (`AlarmCoordinator.swift` ~~L930) and reload
timelines (~~L958/962 `reloadTimelines(ofKind:)`), so find the broken link:
confirm the APPLY path reaches both, log the reload into `smart_wake_debug.log`
(today it only goes to `WidgetDiagnostics`, so it is invisible in the
diagnostics Kartik sends), and consider `reloadAllTimelines()` to cover the
lock-screen kind. WidgetKit throttles reloads — if the call happens and the
widget still lags, report that as the cause instead of looping on code.**

## TASKS — ONE COMMIT EACH, ALL IN THIS ROUND

### TASK 1 (9h-1) — build fingerprint must be visible in Diagnostics

**This was asked for twice and never implemented — `ContentView.swift` still has
no `CFBundleVersion`/`BUILD:` handling at all, which is why Kartik "tried
refresh and force close" on build 358 and still saw nothing. The `BUILD:` line
is written once at launch by `AlarmClockApp.swift` and is pushed out of the
Diagnostics last-20 window. In `DiagnosticsScreen`: always show the most recent `
BUILD: ` line at the very top (scan `SmartWakeDebugLog.read()` for the last line
whose text starts with `BUILD: ` and display it regardless of the window). Also
add a small version/build footer to the main alarm list so an install can be
checked without opening Diagnostics. Display only.**

### TASK 2 (9h-2) — themes: whole row selects the theme

**Kartik has asked twice. In `AlarmClock/AppearanceView.swift` the theme rows
are `Button { select } label: { HStack … }` with `.buttonStyle(.plain)`, which
only responds on the text. Add `.contentShape(Rectangle())` to the row label
(keep the `Spacer()` so the row fills the width) for both the predefined rows (~~
L19-49) and the user-theme rows (~~L67-102), so tapping anywhere on the row
selects it.**

### TASK 3 (9h-3) — themes: the rest of the polish (carried over, never done)

**In `AlarmClock/AppearanceView.swift`:**

- **Kartik's own themes must appear above the predefined ones (today "My
  Themes" is the last section).**
- **Make Delete discoverable — it exists only in a long-press `contextMenu`
  today; add a swipe action and/or a Delete button in the theme editor. Keep
  the fall-back-to-default behaviour when the active theme is deleted.**
- **When creating a New Theme, the colour controls must be visible immediately
  — today the colour section is tied to the `.custom` preset, so a new theme
  shows no colour pickers.**

### TASK 4 (9h-4) — Play History: Clear all + delete the song's mp3

**In `AlarmClock/HistoryView.swift`:**

- **add a Clear all toolbar action with confirmation;**
- **deleting an entry must be able to delete that song's imported mp3. 
  `PlayHistoryEntry` (`AlarmClock/AlarmModel.swift` ~L472) stores only `songName`
  , so add an optional `soundID`/stored file name — it must stay
  backward-compatible (old persisted history decodes with nil) — and remove the
  file via `SoundLibrary` on delete. Make it an explicit choice (e.g. two swipe
  actions "Delete" vs "Delete + Song"), and refuse/warn if a playlist still
  references that song.**

### TASK 5 (9h-5) — loudness slider plays live (carried over, never done)

`AlarmClock/AlarmEditorView.swift`** ~L137 `Slider(value: loudnessBinding, in:
0...100, step: 1)`. Kartik wants to hear the volume as he drags: play a preview
of the selected sound via `SoundPreviewService` and update that player's volume
live with `loudness.gainFactor` as the slider moves; one preview at a time; stop
shortly after the last change and on sheet dismiss.**

### TASK 6 (9h-6) — feedback when a Control Center button adjusts the alarm

**Kartik wants confirmation that the CC action did something: a small message
shown for about 5 seconds, e.g. "Alarm moved +10 min" / "Next alarm skipped".
When the app is in the foreground while applying the queued action, show a
lightweight in-app toast (auto-dismiss ~5 s). When it is not in the foreground,
post a local notification with the same text (this is the only way to give
feedback in the background). Keep the text short, 12-hour times, and include
the resulting next ring time. Do not use a modal alert.**

## WORKFLOW PER TASK

1.  **Read the actual code around the anchors first — line numbers drift.**
2.  **Minimal change; no drive-by edits; keep all 57 tests green.**
3.  **ONE chained command: edit + `git add` \+ `git commit -m "Phase 9h-X:
    \<line> Co-authored-by: openhands \<openhands@all-hands.dev>"` \+ `git push`.**
4.  **Wait for CI. Confirm green, then report the REAL RUN_ID + run number +
    IPA SHA-256. Never report a red or invented artifact.**
5.  **After ALL tasks in this round are pushed and green, report once and STOP
    for Kartik's device test.**

## DEVICE FACTS (do not break)

- **Playlist-first at wake and the delayed-backup snooze re-ring: confirmed
  working.**
- **Hard iOS rule from the logs: a background app cannot *start* an audio
  session, only continue one. `561015905` = `\!pla` (`
  AVAudioSessionErrorCodeCannotStartPlaying`), `560557684` = `\!int` (`
  CannotInterruptOthers`). The silent loop must already be alive before a ring —
  that now works via `FOREGROUND START: snooze window pending`.**
- **The widget extension can NEVER obtain AlarmKit authorization (`WIDGET AUTH
  REQUEST FAILED: … com.apple.AlarmKit.Alarm error 1, state=notDetermined`) —
  the app must always be the one that schedules.**
- **AlarmKit alarms can ring up to ~30 s late — normal.**
- **Live Activity / Dynamic Island disabled on purpose (
  `liveActivityEnabled=false`).**
- **Loudness percentages are user-set on purpose; do not normalise them.**
- **The AlarmKit floor sound remains the guaranteed fallback when the app is dead.**
- **The debug log is a 300-line ring buffer; keep per-tick logging out of it.**
