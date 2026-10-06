import io

p = r"D:\myiosAlarm\.openhands\memory\2026-10-05-phase9e7.md"
s = io.open(p, encoding="utf-8").read().rstrip()
add = """

---

# Phase 9e-8 (2026-10-05 late) — five device-log defects, one commit each

- Build 348 (7d0952f) install VERIFIED by Kartik (BUILD: v1.0 (348) commit=7d0952f).
- Commits (branch phase1-validation, HEAD 124f4b2):
  - 6275f51 9e-8a duplicates: AlarmEditorView isSaving guard + draftID
    (second tap updates same draft); ContentView .id(editorAlarm?.id ??
    editorIdentity) — editorIdentity regenerated ONLY in "+" action. The old
    .id(...UUID()) re-rolled every body eval and rebuilt the editor mid-typing.
  - 837b5ca 9e-8b save lag: sticky precompose — AudioProcessingService
    reuses newest existing playlist_<name>_<id8>_*_<pct>pct[_capN].wav file
    for random mode instead of re-rolling selectRandomSongs each commit
    (re-roll → new selectionHash → cache miss → full WAV render every save).
    Filename now encodes cap (_cap60) so backup (60s) never reuses the long
    primary file. AlarmCoordinator backup copyItem → Task.detached off main.
    desiredSelectionHash hashes playlist.selectedSoundIDs (user selection),
    not the random pick — IDs stay stable, schedule=0 cancelling=0 preserved.
  - 5b43cc4 9e-8c snooze takeover: banner removeDeliveredNotifications
    ["SNOOZE-<id>"] synchronous FIRST; ensureAudioSessionActive 3× retries
    BEFORE playback; kit alarm cancelled ONLY after isPlaying confirmed;
    on failure keep kit ringing + context + loop (next 2s tick retries);
    consumeSnoozeForTakeover moved to success path; kit-alarm-gone branch
    clears stale context; SNOOZE-WATCH log per tick during window;
    AlarmPlaybackService logs "SNOOZE: loop after restart running=...".
  - 377eb22 (+076a1c6 rawValue fix) 9e-8d widget skip: authorizationState
    gate BEFORE any cancel (cancel-then-throw lost the alarm); do/catch logs
    exact reconcile error + auth state, rethrows. LESSON:
    AlarmManager.AuthorizationState has NO rawValue — use
    String(describing:).
  - 735e4dc 9e-8e PERF logs: setEnabled start/done + performCommit
    start/done/FAILED with elapsed ms and reason. Diagnostics only.
  - 124f4b2 9e-8b fix2: sticky finder must use processedSoundsDirectory
    (helper had no processedDir local) + explicit URLResourceKey.
- CI run 37350591964 GREEN on 124f4b2 (37349823089 and 37350192824 red on the
  two compile errors above). IPA .agent_tmp\\ci-artifacts-9e8\\AlarmClock-unsigned.ipa
  SHA-256 D62D564AE27CC2C0DAEA24639759941CABA1E6B96B3934DA978099E705E59EB5.
- gh run download <id> --dir can silently no-op when dir doesn't exist; use
  --name AlarmClock-unsigned-ipa --dir <newdir>.
- DEVICE TEST PENDING: all five fixes unverified on device; Kartik to test
  save-duplication, save latency, snooze takeover banner/audio, widget skip,
  PERF lines. If WIDGET RECONCILE SCHEDULE FAILED shows auth/permission error
  under AltStore free provisioning → STOP; pending-action-file fallback needs
  his OK.
"""
io.open(p, "w", encoding="utf-8").write(s + add)
print("appended", len(add))
