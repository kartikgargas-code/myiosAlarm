# NOTES for new chat — Phase 9g (read me first)

## WHO I AM / WORKING MODE

- **You are the BUILDER. User is Kartik — talk PLAIN ENGLISH, short answers, say
  "not sure" instead of guessing APIs. You write code; Kartik tests on device.
  Never say "verified on device" — only he can verify.**
- **Repo: D:\myiosAlarm, branch phase1-validation (NEVER main). Shell = Windows
  PowerShell. AltStore-signed, no new entitlements without asking first.**
- **HARD LESSONS: (1) ALWAYS chain edit + `git add` + `git commit` + `git push`
  in ONE command — a background sync can revert edits. (2) PowerShell has NO
  heredoc — write a .py to .agent_tmp and run it; long `Select-String`/
  `gh run view --log` calls wedge the shared terminal. (3) Swift files stay UTF-8.
  (4) Xcode 26/iOS 26: escaping closures need explicit `self.`; `import AlarmKit`
  where used; AlarmKit `Alarm` exposes NO attributes/metadata member.
  (5) Shared-module types the widget constructs need an explicit `public init`.
  (6) xcodegen: **project.yml is the source of truth** — never hand-edit
  project.pbxproj. (7) 57 tests stay green.**
- **First command every session: `git -C D:\myiosAlarm log --oneline -8 ; git -C
  D:\myiosAlarm status -sb` — reconcile before planning.**

## BUILD-IDENTITY RULE (obey it — this has burned us repeatedly)

- `CFBundleVersion` is set by CI to the **GitHub Actions run number**; the app logs
  `BUILD: v1.0 (<run#>) commit=<sha>` once at launch.
- **Never tell Kartik to test without the RUN NUMBER.** Report `RUN_ID` + run
  number + IPA SHA-256, **only from a GREEN run**, and confirm the run is green
  before reporting.
- Recent green builds: **348** (`7d0952f`), **352** (`124f4b2`), **356** (`ffd9536`),
  **357** (`eed3595`, run 37370127880 — the one Kartik last tested).
  Runs 349–353 were RED for five consecutive pushes; Kartik installed 352 while
  thinking it was newest and reported shipped features as broken. Red run = fix
  forward *before* starting anything else.

## VERIFIED WORKING ON BUILD 357 (from Kartik's device log — trust this)

- **Control Center buttons now work.** `WIDGET ACTION QUEUED: adjust-10
  alarm=FAA3F230 …` → `WIDGET ACTION APPLY: handed to commit (adjust-10)` →
  `RECONCILE(adjust): existing=14 desired=14 schedule=1 cancelling=1` →
  `PERF: commit(adjust) done in 41ms`. Skip and ±10 min all took effect. The
  pending-action design (9f-1) is correct — **keep it**.
- **The extension can NEVER be AlarmKit-authorized:**
  `WIDGET AUTH REQUEST FAILED: … (com.apple.AlarmKit.Alarm error 1.)
  (state=notDetermined)`. The app is the only party that can schedule. Stop trying
  to schedule from the extension; always queue. (Keep the probe log.)
- **Snooze silently keeps the app alive now:** `FOREGROUND START: snooze window
  pending — starting loop for takeover`, `SILENT LOOP started (session active)`,
  `SNOOZE: loop after restart running=true`, then 30-second heartbeats for the
  whole snooze window (the 9e-9b throttle works).
- **Snooze banner appears immediately**, and the lock-screen widget shows the
  snoozed ring time.
- **Snooze takeover eventually starts the playlist** (playlist audio confirmed:
  `PLAYBACK started track 1: Tere Bina Jiya volume=0.46`).
- Toggle 39 ms, save 63 ms, sticky precompose reuse, no duplicate alarms,
  row tap opens the editor, imported names cleaned, song durations present.

## CARRIED OVER — THESE WERE NEVER DONE (only 9f-1 shipped last round)

Kartik's build 357 contains **only** commit `eed3595` (9f-1, Control Center). The
following from the previous notes were **not implemented** and are still wanted:

- **Pin the build fingerprint** at the top of the Diagnostics screen (+ a small
  version/build footer on the main alarm list) so an install can be verified
  without the clear-and-relaunch dance. Display only.
- **Themes polish** (`AlarmClock/AppearanceView.swift`):
  (a) Kartik's own themes must appear **above** the predefined ones (today
  "My Themes" is the last section); (b) tapping **anywhere on the row** must select
  a theme — today only the name text works, so add `.contentShape(Rectangle())`;
  (c) make **Delete discoverable** — it exists only in a long-press `contextMenu`
  today, so add a swipe action and/or a Delete button in the theme editor; keep the
  fall-back-to-default behaviour when the active theme is deleted; (d) when
  creating a **New Theme**, the colour controls must be visible immediately (today
  the colour section is tied to the `.custom` preset).
- **Play History: deleting an entry does not delete the song's mp3 from the app.**
  `PlayHistoryEntry` (`AlarmClock/AlarmModel.swift` ~L472) stores only `songName`.
  Add an optional `soundID`/stored file name (backward compatible — old persisted
  history must still decode), then make the delete path remove the file via
  `SoundLibrary`. Offer it as an explicit choice (e.g. swipe "Delete" vs
  "Delete + Song"), and refuse/warn if a playlist still references that song.
  Also add a **Clear all** action with confirmation.
- **Loudness slider live preview** (`AlarmClock/AlarmEditorView.swift` ~L137,
  `Slider(value: loudnessBinding, in: 0...100, step: 1)`): Kartik wants to hear the
  volume change as he drags. Play a preview of the selected sound via
  `SoundPreviewService` and **update its volume live** with `loudness.gainFactor`
  while dragging; one preview at a time; stop on sheet dismiss.
- **Investigate the desired-alarm count anomaly — do not guess.** Every reconcile
  now logs `existing=14 desired=14` while the app reports only **2 alarms**
  (`FOREGROUND START attempt: declined … (alarms: 2)`). That is 7 desired system
  alarms per user alarm, not the expected primary+backup pair. Log the desired set
  in full (occurrenceKey, kind, effectiveDate, id, label) and the alarm/enabled
  counts, then report before changing logic. Also still unexplained: **pressing
  Control Center Skip once created a duplicate alarm entry** in the list (a second
  press did not).

## NEW ASKS — one per commit

### TASK 1 (9g-1) — the snooze re-ring must play the playlist, not the floor sound
Kartik's log: the silent loop is alive the whole snooze window, yet at fire time
`AVAUDIOSESSION INTERRUPTION began reason=0` → attempts 1 and 2 fail
(`560557684` = `!int` `AVAudioSessionErrorCodeCannotInterruptOthers`) → attempt 3
succeeds and the playlist starts — but **he hears the AlarmKit floor alarm**, which
is already ringing by then, and the kit alarm is only cancelled *after* playback
confirms (`SmartWakeService.swift` ~L184).

Why the wake path doesn't have this problem: for a playlist alarm with Smart Wake,
the app never schedules a primary that rings — it schedules only the **delayed
-BACKUP floor alarm (+30s)** and cancels that backup during the takeover, so
nothing ever rings and the playlist is first.

Fix: make the snooze re-ring use that same architecture instead of an
immediately-ringing alarm:
- In `AlarmPlaybackService.handleSnoozeCommand`, for a playlist alarm while Smart
  Wake is on, schedule the floor alarm **delayed** (reuse the same backup-delay
  concept) and let the still-alive app start the playlist at the true snooze time
  and cancel the delayed floor alarm before it rings — exactly like the wake path.
- Keep the delayed floor alarm as the guaranteed fallback if the app died.
- Additionally: check the Xcode 26 AlarmKit interface for the documented call that
  **silences an already-alerting alarm** (the CI already has an AlarmKit API
  verification step — use it to confirm what exists; do not guess). If a stop/
  silence call exists, use it and reduce the failure window.
- Do not regress the wake path, which works.

### TASK 2 (9g-2) — snooze banner: one line, so it reads bigger
Kartik wants bigger banner text. **iOS controls notification fonts — do not
attempt to change them.** The only lever is structure: the notification *title*
renders larger than the body, so put everything in the title and drop the body,
e.g. title `Snoozed 5 min · 8:23 am` (keep it short — long titles truncate; keep
the 12-hour format already in place). One line instead of two will look bigger.

### TASK 3 (9g-3) — floor sound: same sequence every time (explain, then decide)
Kartik noticed the floor/backup ring always plays the same song sequence. Cause:
the 9e-8b sticky-precompose cache reuses the first rendered WAV per
(playlist, loudness, cap), so the random selection is now fixed. That cache is what
removed the 2-second save, so **do not simply re-roll on every save.**

Recommended: keep a small **pool of precomposed floor variants** (e.g. 2–3), built
lazily in the background during foreground time (never on the save path), and pick
one per arming. Only do this if Kartik wants variety — ask, and report the
disk-size impact. If he doesn't care, leave it as is and say so.

### TASK 4 (9g-4) — floor sound file size
WAV and AIFF are both uncompressed PCM — **converting WAV→AIFF saves nothing.**
Real savings for the short floor sound: fewer channels + lower sample rate (e.g.
mono 22.05 kHz 16-bit ≈ a quarter of the current size; the file is capped at 60 s
so quality loss is negligible for a fallback ring). Also check whether AlarmKit
accepts a compressed format at all — **verify against the Xcode 26 AlarmKit
interface/docs, do not guess**; if it does, an `.m4a`/`.caf` variant could be much
smaller. Note that with sticky reuse the number of files is now bounded, so the
old unbounded-disk-leak concern is already fixed — measure before optimising.

### TASK 5 (9g-5) — Control Center: lock-screen widget doesn't show the new time
The action now applies (above) but the lock-screen widget kept the old alarm time.
The app does reload timelines (`AlarmCoordinator.swift` ~L958/962,
`WidgetCenter.shared.reloadTimelines(ofKind:)`) and writes
`nextAlarmSnapshot.json` (~L930), so find out which link fails:
- confirm the APPLY path actually reaches the snapshot write **and** the reload;
- log the reload in `smart_wake_debug.log` as well (today it only goes to
  `WidgetDiagnostics`, so it never shows in the diagnostics Kartik sends);
- consider `WidgetCenter.shared.reloadAllTimelines()` so the lock-screen widget
  kind is covered too;
- note WidgetKit throttles reloads — if the call is made and the widget still lags,
  report that as the likely cause rather than looping on code changes.

## WORKFLOW PER TASK

1. Read the actual code around the anchors first — line numbers drift.
2. Minimal change; no drive-by edits; keep all 57 tests green.
3. ONE chained command: edit + `git add` + `git commit -m "Phase 9g-X: <line>
   Co-authored-by: openhands <openhands@all-hands.dev>"` + `git push`.
4. Wait for CI. **Confirm green**, then report the REAL RUN_ID + run number + IPA
   SHA-256. Never report a red or invented artifact.
5. STOP and wait for Kartik's device test after each task that changes runtime
   behaviour; pure-UI polish tasks may be batched.

## DEVICE FACTS (do not break)

- Playlist-first at wake, snooze scheduling, random shuffle at wake, single
  fileImporter import: confirmed working — do not regress.
- Hard iOS rule established from logs: a **background** app cannot *start* an audio
  session, only continue one. `561015905` = `!pla`
  (`AVAudioSessionErrorCodeCannotStartPlaying`), `560557684` = `!int`
  (`CannotInterruptOthers`). This is why the silent loop must already be alive
  before an alarm fires — that part now works; build on it.
- AlarmKit alarms can ring up to ~30 s late — normal.
- Live Activity / Dynamic Island disabled on purpose (`liveActivityEnabled=false`).
- Loudness percentages are user-set on purpose; do not normalise them.
- After-snooze ring uses the AlarmKit floor sound when the app is dead —
  guaranteed fallback, keep it.
- The debug log is a 300-line ring buffer; keep per-tick logging out of it.
