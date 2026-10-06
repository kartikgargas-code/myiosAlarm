# NOTES for new chat — Phase 9f (read me first)

## WHO I AM / WORKING MODE

- **You are the BUILDER. User is Kartik — talk PLAIN ENGLISH, short answers, say
  "not sure" instead of guessing APIs. You write code; Kartik tests on device.
  Never say "verified on device" — only he can verify.**
- **Repo: D:\myiosAlarm, branch phase1-validation (NEVER main). Shell = Windows
  PowerShell. AltStore-signed, no new entitlements without asking first.**
- **HARD LESSONS: (1) ALWAYS chain edit + `git add` + `git commit` + `git push`
  in ONE command — a background sync can revert edits. (2) PowerShell has NO
  heredoc — write a .py to .agent_tmp and run it; long `Select-String`/`gh run
  view --log` calls wedge the shared terminal. (3) Swift files stay UTF-8.
  (4) Xcode 26/iOS 26: escaping closures need explicit `self.`; `import AlarmKit`
  where used; AlarmKit `Alarm` exposes NO attributes/metadata member.
  (5) Shared-module types the widget constructs need an explicit `public init`.
  (6) xcodegen: **project.yml is the source of truth** — never hand-edit
  project.pbxproj. (7) 57 tests stay green.**
- **First command every session: `git -C D:\myiosAlarm log --oneline -8 ; git -C
  D:\myiosAlarm status -sb` — reconcile before planning.**

## BUILD-IDENTITY RULE (this has burned us repeatedly — obey it)

- The app's `CFBundleVersion` is set by CI to the **GitHub Actions run number**,
  and the app logs `BUILD: v1.0 (<run#>) commit=<sha>` once at launch.
- **Kartik must never be told "test this" without the RUN NUMBER.** Report
  `RUN_ID` + `run number` + IPA SHA-256, and only from a GREEN run.
- **Before any new work: confirm the run for your push is green.** In one recent
  stretch CI was RED for **five consecutive pushes** (runs 349–353), so the
  features in them had no downloadable IPA, Kartik installed the last green build
  (352), and reported working features as broken. That wasted a whole test cycle.
  If a run is red: fix forward first, then report.
- Kartik verifies by checking the `BUILD:` line / the build number.
- Builds so far: 348 (`7d0952f`), 352 (`124f4b2`), **356 (`ffd9536`, current
  latest green — contains all of 9e-9a…9e-9h)**.

## VERIFIED STATE ON BUILD 356 (from Kartik's device log — trust this)

CONFIRMED WORKING:
- Toggle: `PERF: commit(toggle) done in 39ms` — instant, no churn.
- Save: `PERF: commit(save) done in 63ms`; `PRECOMPOSE: sticky reuse … (no
  re-render)` — the 2-second save is gone.
- Duplicate alarms on save: fixed (single tap saves one alarm).
- Row tap → editor: works (`EDITOR OPEN: tapped …`, `EDITOR SHEET: appeared`).
- Imported song names: cleaned up. Themes: create/edit/duplicate work.

STILL BROKEN / OPEN:
- **Control Center buttons**: `WIDGET RECONCILE ABORT: not authorized
  (state=notDetermined); nothing cancelled, nothing scheduled`. The extension's
  `AlarmClockWidgetExtension/Info.plist` has **no `NSAlarmKitUsageDescription`**
  (the app's does). See Task A.
- **Two writers, one reader on the App Group**: the app *mirrors* `alarms.json`
  into the App Group (`AlarmCoordinator.writeAlarmsToAppGroup`) but **never reads
  it back**; the widget reads AND writes that same file. So every widget-side
  change is thrown away the next time the app commits. This is the deeper reason
  "skip does nothing". See Task A.
- **Pressing Control Center Skip once produced a DUPLICATE alarm entry** in the
  list (a second press did not). Root cause unknown — investigate, do not guess.
- `RECONCILE(toggle): existing=0 desired=7` then `RECONCILE(save): existing=7
  desired=14 schedule=7 cancelling=0` while the app reports only 1–2 alarms.
  The desired counts look inflated/duplicated. Log what those IDs actually are.
- `FOREGROUND START attempt: declined — no enabled alarm within 8h (alarms: 1)`
  fires in ordinary foreground use. The 9e-9a snooze bypass is UNTESTED (Kartik
  cannot test snooze at night — morning test pending).
- Snooze banner was missing on one run (that was build 352) — recheck on 356.
- `WIDGET ACTION TARGET: … (snapshot order: ?/on)` — the `?` is a logging gap.

## TASKS — one per commit, in this order

### TASK A (9f-1) — Control Center buttons actually work
Two stacked problems, both must be fixed.
1. **Authorization.** Add `NSAlarmKitUsageDescription` (same string as the app's)
   to `AlarmClockWidgetExtension/Info.plist` — it is a real plist referenced by
   `INFOPLIST_FILE`, edit it directly. Then log, in each intent, the full
   `AlarmManager.shared.authorizationState` and the result/error of
   `try await AlarmManager.shared.requestAuthorization()`. **Report the result
   and STOP.** An app extension may be *unable* to obtain AlarmKit authorization
   at all — if the state stays `.notDetermined`, do not thrash: move to (2).
2. **Ownership.** The app never reads the App Group `alarms.json`, so the
   widget's write is always lost. Fix the ownership properly: the intent writes a
   small **pending-action file** in the App Group (e.g.
   `pendingWidgetAction.json`: `{action, alarmID, requestedAt}`) instead of
   rewriting the whole alarm snapshot, and the **app** applies it (the app is the
   only writer of `alarms.json` and the only party with working AlarmKit auth).
   Add a `CFNotificationCenterAddObserver` for
   `com.example.alarmclock.widget.changed` (the notification is already posted)
   so a *running* app applies the action immediately; otherwise it applies on
   next foreground in `synchronize()`. Keep the existing abort gate so nothing is
   ever cancelled without authorization.
   Also: log which alarm the intent targeted — `snapshot.alarms.first(where: {
   $0.isEnabled })` may not be the alarm Kartik means.

### TASK B (9f-2) — pin the build fingerprint where Kartik can see it
Diagnostics currently shows only the last ~20 filtered lines, so the `BUILD:`
line (written once at launch) is pushed out and verifying an install needs a
clear-and-relaunch dance. In `DiagnosticsScreen`, always show the most recent
`BUILD: ` line at the very top, even when it is outside that window. Also add a
small version/build footer on the main alarm list. Display only.

### TASK C (9f-3) — investigate the duplicate entry + the desired-count anomaly
Do NOT guess. Add targeted logging: in `desiredSystemAlarms`, log the desired set
(occurrenceKey + kind + effectiveDate) and its count; log the alarm count and
enabled count; and log the snapshot alarm IDs the widget writes vs. the ones the
app has. Then report the findings before changing any logic.

### TASK D (9f-4) — Themes polish (Kartik's asks)
In `AlarmClock/AppearanceView.swift`:
1. Kartik's own themes must appear **above** the predefined ones (today the
   "My Themes" section is last, after "Predefined Themes").
2. Tapping **anywhere on the theme row** must select it — today only the name
   text works. Add `.contentShape(Rectangle())` to the row label (and keep
   `Spacer()` so the row fills the width).
3. Make **Delete discoverable**: today `Delete` only exists in a long-press
   `contextMenu`. Add a swipe action (and/or a Delete button inside the theme
   editor). Keep the existing "fall back to the default theme when the active
   theme is deleted" behaviour.
4. When creating a **New Theme**, the custom colour controls must be visible
   immediately — today the colour section appears tied to the `.custom` preset
   state, so a new theme shows no colour pickers.

### TASK E (9f-5) — Play History: clear all + delete the mp3
In `AlarmClock/HistoryView.swift`:
1. Add a **Clear** action (toolbar) that empties the play history after a
   confirmation.
2. Add an option so that deleting a history entry **also deletes that song's
   imported mp3** from the app. This needs a model change: `PlayHistoryEntry`
   (`AlarmClock/AlarmModel.swift` ~L472) currently stores only `songName` — add
   an optional `soundID` (and/or the stored file name) so the delete path can
   remove the file via `SoundLibrary`. It must stay backward-compatible with
   already-persisted history (optional field, decodes as nil). Offer it as an
   explicit choice (e.g. two swipe actions: "Delete" vs "Delete + Song", or a
   confirmation), because deleting a song also affects any playlist using it —
   refuse or warn if the song is referenced by a playlist.

### TASK F (9f-6) — loudness slider plays instantly at that volume
`AlarmClock/AlarmEditorView.swift` ~L137: `Slider(value: loudnessBinding, in:
0...100, step: 1)`. Kartik wants to hear the volume as he drags. Use
`SoundPreviewService` to play a short preview of the currently selected sound
(looping the preview or debouncing), and **update the player volume live** with
`loudness.gainFactor` as the slider moves, stopping shortly after the last
change. Only one preview at a time; stop it on sheet dismiss.

### TASK G (9f-7) — snooze takeover (MORNING TEST, do not chase yet)
9e-9a (bypass the 8h guard while a snooze is pending) is in build 356 and has
never been device-tested. Do not change the snooze code until Kartik reports the
morning result (`loop after restart running=true` would mean it works). If the
loop still shows `running=false`, investigate *why the restart is declined*
first — `startIfReadyForeground()` needs a real reason code, not a bare false.
Remember the hard iOS rule established from the logs: a background app cannot
*start* an audio session, only continue one — `561015905` = `!pla`
(`AVAudioSessionErrorCodeCannotStartPlaying`). So the session must already be
alive before the snooze alarm fires.

## WORKFLOW PER TASK

1. Read the actual code around the anchors first — line numbers drift.
2. Minimal change; no drive-by edits; keep all 57 tests green.
3. ONE chained command: edit + `git add` + `git commit -m "Phase 9f-X: <line>
   Co-authored-by: openhands <openhands@all-hands.dev>"` + `git push`.
4. Wait for CI. **Confirm green**, then report the REAL RUN_ID + run number + IPA
   SHA-256. Never report a red or invented artifact.
5. STOP and wait for Kartik's device test before the next task, unless a task
   explicitly says otherwise.

## DEVICE FACTS (do not break)

- Playlist-first at wake, snooze schedule, random shuffle at wake, single
  fileImporter import: all confirmed working — do not regress them.
- AlarmKit alarms can ring up to ~30s late — normal.
- Live Activity / Dynamic Island disabled on purpose (`liveActivityEnabled=false`).
- Loudness percentages are user-set on purpose; do not "normalise" them.
- After-snooze ring uses the AlarmKit floor sound when the app is dead —
  guaranteed fallback, keep it.
- The 300-line log ring buffer is easy to flood; keep per-tick logging out of it
  (9e-9b already throttled SNOOZE-WATCH — keep it that way).
