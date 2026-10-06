import io

p = r"D:\myiosAlarm\.openhands\memory\MEMORY.md"
s = io.open(p, encoding="utf-8").read().rstrip()
add = (
    "\n\n- Phase 9e-7 (2026-10-05): stale-install root cause fixed — CI stamps "
    "CFBundleVersion=run_number + AlarmClockBuildStamp=sha into app/widget plists "
    "(ac00dd2); app logs `BUILD: v? (run#) commit=...` at launch; toggle flips "
    "instantly via pendingEnabled @State (7d0952f). CI 37341787532 GREEN, IPA "
    "SHA 76FB6190…A259 at .agent_tmp/ci-artifacts-9e7. Acceptance before any new "
    "task: Kartik log starts with BUILD: line + first-tap toggle. Details: "
    ".openhands/memory/2026-10-05-phase9e7.md\n"
)
io.open(p, "w", encoding="utf-8").write(s + add)
print("appended", len(add))
