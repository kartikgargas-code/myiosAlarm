<!-- talk-to-the-human:start -->
## How to talk to the human (Kartik)

Kartik does not write code. Talk to him in **plain English**, not in a programmer's language.

- Describe what the app **does** and what **he will see or hear** — never how the code is written.
- Do **not** paste code, variable names, function names, file names, line numbers, brace counts,
  log tags, or symbols such as `{ }`, `==`, or `->` in messages to him.
- Do **not** offer choices as letters ("option (b)", "path 3") and do **not** use tool/developer
  jargon ("stash", "diff", "commit", "hash", "push", "early-return", "binding").
- If a technical detail is truly needed, first say what it means for **him**, then the detail in
  one short, everyday sentence.
- Explain bugs and fixes like you would to a friend — e.g. "the alarm sound kept going because
  the phone ignored the app's request to stop it" — then ask only the one or two simple questions
  you actually need.
- Short, warm, concrete. No walls of technical text.
<!-- talk-to-the-human:end -->

<!-- graft:start -->
## Graft — repo context graph

This repo is indexed in `graft/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `graft map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `graft ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `graft grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `graft skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `graft callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `graft/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `graft ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `graft build` (deterministic,
no API key, $0).
<!-- graft:end -->

<!-- builder-discipline:start -->
## Builder discipline rules (learned the hard way — follow these)

1. **If CI is red, READ THE ERROR before changing any code. Never guess twice.**
   Get the real compiler error first:
   - `gh api 'repos/kartikgargas-code/myiosAlarm/actions/runs/<RUN_ID>/jobs' --jq '.jobs[] | [.id,.conclusion,.name] | @tsv'`
   - `gh run view --job <JOB_ID> --log 2>&1 | Select-String 'error:' | Select-Object -First 25`

   Guessing at a compile error cost us eight consecutive red builds for a one-line
   mistake. One read of the log ends it immediately.
2. **Never push a speculative fix.** A red push spends a full CI run (~10 min) and
   produces no IPA, so nothing can be tested. Fix first, then push once.
3. **Do not chain red pushes.** If two attempts in a row fail, STOP and report the
   exact error text instead of trying a third idea.
4. **Do not churn build configuration to explain a compile error.** Moving files
   between targets (`project.yml` membership) is a last resort, not a hypothesis to
   try — it has already broken dependencies and been reverted once.
5. **Do the smallest possible edit.** If the error names a duplicate declaration,
   delete the duplicate. Do not restructure, rename, or reorder anything else.
6. **Read the instruction literally.** "Remove the subtitle" means delete the line,
   not reword it. "Commit locally, do not push yet" means do not push.
7. **Never leave the tree dirty and never commit scratch files.** One commit per
   task, and chain `git add` + `git commit` (+ `git push` only when asked) in a
   single call. `.agent_tmp/` stays ignored.
8. **Report the RUN NUMBER and confirm the run is GREEN.** The run number is the
   app's build number, so a wrong one wastes a device-test cycle.
9. **Never claim "verified on device".** Only the user can verify on device.
10. **When a reported bug is one the code should already handle, first add one log
    line that proves which branch ran.** Do not change logic until the evidence says
    which path is actually taken.
<!-- builder-discipline:end -->
