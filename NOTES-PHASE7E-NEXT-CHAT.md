# NOTES for new chat — Phase 7e build (read me first)

## WHO I AM / WORKING MODE

- **I am the senior iOS adviser (design + API answers). A builder model
  (Nemotron/OpenHands) writes code.**
- **User: Kartik. Talk PLAIN ENGLISH, short answers. Ask before reading big logs.
  Say "not sure" instead of guessing APIs.**
- **Repo: D:\\myiosAlarm, branch phase1-validation (NEVER main). AltStore-signed,
  no new entitlements. CI = GitHub Actions "iOS Build" builds unsigned IPA on
  every push; download with `gh run download \<RUN_ID> --dir .\\ci-artifacts`;
  hash with Get-FileHash.**
- **CRITICAL LESSON (this chat): edits can get reverted by a background sync
  (OneDrive?) if you wait between edit and commit. ALWAYS: edit + `git add` \+ `
  git commit` \+ `git push` in ONE chained command. file_editor str_replace
  fails if you pass view_range alongside old_str/new_str (payload drops
  old_str) — send only path+command+old_str+new_str. PowerShell has NO heredoc
  (<<'EOF') — write .py files to .agent_tmp\\ and run `python file.py`, chain
  with commit in same command.**
- **Xcode 26 / iOS 26: Swift UTF-8 only; explicit self. in escaping closures;
  import AlarmKit where used. Tests only for pure logic. Never delete features
  to fix CI — fix the call.**
- **User tests on device after each build. Never say "verified on device" in
  reports.**

## CURRENT STATE (commit ffaccb2, CI 37218739794 GREEN, 57 tests, IPA SHA 12E29C59...10FE)

- **Phase 7a/7c/7d/7e merged: playlist-first works. At wake: NO fullscreen (no
  AlarmKit alarm at wake for playlist alarms), playlist plays in-app, backup
  cancelled on confirmed playback (cancelScheduledAlarms computes -BACKUP
  SystemScheduleID + silences .alerting alarms).**
- **Backup = AlarmKit alarm at wake+30s, floor sound (60s cap, precomposed
  streaming). Native fullscreen Stop+Snooze if app dead/playback failed.**
- **Live Activity/Dynamic Island DISABLED (liveActivityEnabled=false; user hated
  the black banner).**
- **Lock-screen player: prev=STOP, next=SNOOZE, play/pause=pause trap (silent
  loop keeps app alive on pause). Stop command enabled but iOS hides it (see
  Task 3). setupStopNotification removed from playlist-first path (no
  lock-screen banner). Artwork fallback exists but BROKEN (see Task 2).**
- **Play history: every track start recorded; play/stop toggle in diagnostics
  screen.**
- **SmartWakeService.nativeFirstWhenLocked = false.**

## KNOWN BUGS (verified this chat)

1.  **WAKE KEY BUG (main): firedTransitionWakes + armedOccurrences keyed by
    occurrenceKey = just the DATE ("2026-10-05"). One alarm = one key/day. When
    user moves the alarm time (12:10→12:14→12:17) or fires again same day, the
    2nd/3rd wake is SKIPPED ("WAKE DUPLICATE ignored") → no ARMING, no
    TRANSITION WAKE → playlist never starts → backup rings fullscreen. FIX: key
    = alarmID + effectiveDate (fire time), e.g.
    "(occurrence.alarmID.uuidString)|(Int(occurrence.effectiveDate.timeIntervalS
    nce1970))". Apply consistently in firedTransitionWakes, armedOccurrences
    (makeArmingKey), and cleanup logic (SmartWakeService ~L670-706 parses
    "alarmID|occurrenceKey" — update parsing).**
2.  **Artwork fallback broken: appIconImage() reads
    CFBundleIcons/CFBundleIconFiles — modern apps use asset catalog
    (CFBundleIconName). No image found → iOS shows SMALL compact player. FIX:
    UIImage(named: "AppIcon") from asset catalog (try "AppIcon",
    "AppIcon60x60", check asset catalog names in project). Result: big player
    with artwork.**
3.  **PLAYBACK INTERRUPTED spam: logged at 18:44/18:47 when nothing playing
    (isPlaying=false). Minor; gate the log.**
4.  **Diagnostics screen: LAGGY (press buttons 2-3x), Refresh/Clear no-ops (log
    text not @State), Copy dumps 300 lines incl. SESSION DUMP spam, wrong
    timestamps confusion (log is UTC \[Z] — device is IST; label or convert).
    USER'S #1 COMPLAINT.**

## AGREED NEXT BUILD (Phase 7e) — user said build in new chat, WAIT for his "go"

1.  **Diagnostics rebuild (top priority): new clean screen, ONLY: last alarm
    result, next alarm time, loop alive/dead, last ~20 useful log lines.
    Refresh + Clear buttons that actually work (log text in @State). Copy =
    last 40 useful lines, EXCLUDE lines with "SESSION DUMP", "play() FALSE",
    "STATE DUMP", "BACKUP: skipping", or starting "  id=". No lag (lazy load,
    don't render whole file). Fix timestamps display (UTC→local or label as
    UTC).**
2.  **Artwork fix: proper app-icon lookup → big player on lock screen.**
3.  **Two-button player: disable
    playCommand/pauseCommand/togglePlayPauseCommand/previousTrackCommand during
    alarm ringing; keep ONLY stopCommand (■ = stop alarm) + nextTrackCommand (⏭
    = snooze). User explicitly approved losing pause while alarm rings. Keep
    pause trap code (used only if pause ever re-enabled). Note: iOS shows ■ on
    lock screen when stopCommand enabled AND pause/toggle disabled (verified
    via web search + Stack Overflow).**
4.  **Wake-key fix (bug 1 above) — include fire time in keys.**
5.  **After each step: push → CI green → user tests on device → next.**

## KEY FILES

- **AlarmClock/SmartWakeService.swift — wake path (~~L745-830: WAKE DUPLICATE
  GUARD, PLAYLIST-FIRST, cancelScheduledAlarms L713), ARMING (L677-687),
  checkAndArmUpcomingAlarms (~~L626, now internal not private),
  scheduleTransitionWake (~L714), takeOverShared logic L801-814, backup cancel
  = computed SystemScheduleID via
  cancelScheduledAlarms(forAlarmID:backupOccurrence:label:sound:loudness:selecti
  nHash:).**
- **AlarmClock/AlarmPlaybackService.swift — remote commands (setupRemoteCommands ~~
  L608-661: prev=STOP handler, next=SNOOZE handler, stopCommand added 7d;
  removeRemoteCommands L664), pause trap (L786), resume (~~L800),
  handleStopCommand (~~L684: cancel backup + stop + rearm + loop restart),
  handleSnoozeCommand (~~L707: cancel backup + schedule AlarmKit alarm
  now+snoozeDurationMinutes with floor sound, addEmergencyReRingID),
  publishNowPlayingInfo (~L563, artwork block ~~L587), appIconImage() static (~~
  L598, BROKEN lookup).**
- **AlarmClock/AlarmCoordinator.swift — desiredSystemAlarms (~~L391+): skips
  primary for playlist+smartWake (shouldSchedulePrimaryAtWake L419), schedules
  \-BACKUP (L427-500, precompose 60s cap), backupDelaySeconds=30 (L15),
  SystemScheduleID hash inputs = effectiveDate|label|sound.id|loudness
  (ExtensionAlarmSchedulingService L139-151), liveActivityEnabled=false (L44),
  recordPlayHistory (~~L941), playHistoryEntry toggle (~L977).**
- **AlarmClock/AlarmPlaybackService.swift setupStopCommand (~L344) — legacy stop
  handler (stop only, no backup cancel) — consolidate to handleStopCommand when
  touching.**
- **AlarmClock/ContentView.swift — diagnostics screen (~~L413 diagnosticsView),
  Play History UI (~~L483-517), play toggle uses
  SoundPreviewService.playingSoundID == "history-(entry.id.uuidString)".**
- **AlarmClock/SoundPreviewService.swift — NSObject subclass,
  AVAudioPlayerDelegate clears playingSoundID on finish.**
- **AlarmClock/ExtensionAlarmSchedulingService.swift — reconcile (L16), schedule
  (L64: metadata ScheduledOccurrenceMetadata(alarmID, occurrenceKey,
  baseDate)), Alarm has NO attributes member (compile-error lesson).**

## DEVICE FACTS (user-verified)

- **Playlist-first at wake: works, no fullscreen, tracks play, backup cancelled.
  100% confirmed 18:40Z run.**
- **2nd/3rd same-day alarm (moved times): backup rang fullscreen (bug 1). NOT
  fixed yet.**
- **Small artwork player (no artwork). NOT fixed yet.**
- **Stop ■ NOT visible on lock screen (pause still enabled). Task 3 fixes.**
- **User's loudness tests: 34%/43%/46% are user-set on purpose (to tell backup
  from playlist). Not a bug.**
- **AlarmKit alarms can ring up to ~30s LATE (16:27:31 for a 16:27:00 schedule) —
  normal, don't "fix".**
- **Old test alarm caused a second ring once (8B0F7930) — user may have deleted
  it; not confirmed.**

## USER PREFERENCES

- **Doesn't care about "Smart Wake Active" indicator (dropped).**
- **Wants: minimal UI, real Stop ■ + Snooze ⏭ buttons only in player, big
  artwork, fast diagnostics, play history toggle.**
- **Hates: black banner, 300-line dumps, laggy buttons, wrong/no explanations.**
- **Talk first, get approval, THEN code. Never auto-fix without his ask (explicit
  rule from him this chat).**
