# D25 — s12-end-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S12 | none | S |

**Owns:** in S12's end-to-end loop test `scheduler/loop-s12.test.sh`, the waits of two checks: lines 134 and 135 at
this spec's base, `S12-AC-4: the two ends of X03 are two end lines, both naming out of memory and the ceiling` and
`S12-AC-4: the second end line says FAILED`; the record of the runs, in the node's PR and under `out/node/D25/`. As
D05, M02, D13, D17, D20 and D24 did for theirs, this spec allows changing these two frozen test lines' waits, never
what they expect (Change 2), and the PR lists the changed lines for the owner's approval.
**Resolves:** #266

## Purpose
After this node S12-AC-4's two end-line checks in `loop-s12.test.sh` pass on a loaded runner. Both failed in CI on
timing alone on spec-only PR #264, which changes no code or test. The cause is known from the code and the log. When
a node's session ends a second time with no PR and no question, the loop's `ended` (`scheduler/loop.sh`) first writes
the node's `FAILED` file and then writes the status-log line that says so (`... 2 starts used: wrote FAILED`). The
test waits for the first (line 133, `wait_until 25 test -e "$state/node/X03/FAILED"`), then greps the status log
once, at once, for the second end line (lines 134 and 135). Under load the greps can run between the file and the
line. The node makes lines 134 and 135 wait for what they check with a bounded wait, as line 133 does for the file.
Nothing else in the test or the scheduler changes.

## Tests
- `scheduler/loop-s12.test.sh`, changed only at lines 134 and 135 as Change 2 allows: every `PASS:` line of the base
  is a `PASS:` line at the head, word for word.
- The recorded runs in the PR (Changes 1 and 3), among them the scratch-copy mutant runs of Change 3.

## Changes
1. **Record what failed.** The CI log of the run named in the issue: job 139471259160 of run 45689606832, PR #264's
   CI (merge ref `23c8e3a` of PR head `6e1dc33` into `b4beb7a`), 2026-11-25. It can be fetched with the forge CLI's
   `ci logs --run 45689606832` (G08) and is saved under `out/node/D25/` (CI logs expire); a log the session cannot
   fetch is recorded as such, and the PR uses the excerpts this Change quotes in its place. What it shows: `PASS:
   S12-AC-4: its one status.log end line names out of memory and the ceiling` and `PASS: S12-AC-4: a second such end
   writes FAILED`; then `FAIL: S12-AC-4: the two ends of X03 are two end lines, both naming out of memory and the
   ceiling` and `FAIL: S12-AC-4: the second end line says FAILED`; then `PASS: S12-AC-4: X03 is held, not started a
   third time`, `FAIL: 2 check(s) failed` and `TIME 15.77 scheduler/loop-s12.test.sh`. The PR quotes these lines and
   the lines of `scheduler/loop.sh` at the node's base that write `FAILED` and then the end line (lines 536 and 538 at
   this spec's base). *D25-AC-1.*
2. **Wait for the line.** Lines 134 and 135 each wait until what they check holds, with the bound line 133's wait uses
   (`wait_until 25`), instead of reading the status log once. Each check's name, its patterns (`session X03 ended`,
   `out of memory`, `3G`, `wrote FAILED`), its counts (two end lines, both naming out of memory and the ceiling) and
   the file it reads (`$state/status.log`) stay word for word; each still fails, with the same `FAIL:` line, when its
   condition has not come by the bound. No other line of the file changes, `scheduler/testdata/` and
   `scheduler/loop.sh` stay unchanged, and the file stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in
   CI (`test.yml`'s `TEST_FILE_BUDGET`, 105 s at this spec's base; 15.77 s in the failing job). *D25-AC-2.*
3. **Show the wait is what fixes it.** In a scratch copy of the tree (never the node's worktree, as AGENTS.md's rule
   for a mutation sweep says), with a `scheduler/loop.sh` that waits a few seconds (for example `sleep 3`) between
   writing a node's `FAILED` file and writing its `wrote FAILED` end line, the file at the node's base fails the
   checks of lines 134 and 135 and the file at the node's head passes them; with a `scheduler/loop.sh` that never
   writes that end line, the file at the head fails both checks. Each run's log and the file's `TIME` line are
   recorded. The quick gate passes and CI passes on the PR. *D25-AC-2.*
4. **Ask for the frozen lines.** The PR lists the frozen test lines the node changes (file, line at the base, the line
   before and after, and the cause of Change 1 it answers) and asks the owner to approve them, as U05's frozen-line
   record of the final review names them. *D25-AC-3.*

## Gate
- **D25-AC-1** — The PR records the failing checks of the CI job Change 1 names (from its saved log, or Change 1's excerpts where the log cannot be fetched): their two `FAIL:` lines, the two passing checks before them and the file's `TIME` line; and the lines of `scheduler/loop.sh` at the node's base that write a node's `FAILED` file before they write its `wrote FAILED` end line. *Verify:* the saved CI log (or the record that it could not be fetched) and the quoted lines in the PR, checked by the fresh reviewer.
- **D25-AC-2** — At the node's head the checks of lines 134 and 135 each wait for their status-log condition with a bound of 25 s and fail with their `FAIL:` lines when it does not come; in a scratch copy, a `loop.sh` that writes the `wrote FAILED` end line a few seconds after the `FAILED` file fails both checks at the base and passes them at the head, and a `loop.sh` that never writes that line fails both at the head; the file stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI (105 s at this spec's base); the quick gate and CI pass on the PR. *Verify:* `sh scheduler/loop-s12.test.sh`; the three mutant runs' logs and `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D25-AC-3** — The node changes only lines 134 and 135 of `loop-s12.test.sh`, and only their waits: every `PASS:` line of the file in a passing base run is the same `PASS:` line at the head; the checks' names, patterns, counts and file are unchanged; no file outside **Owns** changes (`scheduler/loop.sh` and `scheduler/testdata/` unchanged); the PR lists the changed frozen lines (file, base line, before and after, cause) for the owner's approval. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines, recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- Other waits of the file (the `wait_until` bounds of the X03, X04 and X05 checks, the `wait_ticks` before X04's
  start count) can still give out on a runner far busier than CI's usual load; the issue names only lines 134 and
  135, and this node changes no other check. A later failure of another check is a new issue.
- S14 (spec PR #249, not merged at this spec's base) changes other lines of `loop-s12.test.sh` (the runtime names of
  its Change 5); the two nodes change different lines, and whichever merges second takes the other's lines when it
  merges `main`, with each frozen line it changes listed as its PR says.
- CI on a PR runs every other file, and their timing failures are not this node's; a CI run that fails only on those,
  on other files' `SLOW` lines or on the total (`test.yml`'s `TEST_BUDGET`) is rerun, both run URLs recorded; if the
  reruns keep failing only on those, the node records them and puts it to the owner as a question.
- A wait for a condition turns a loop that never writes the line into a failure at the bound, so a failing run takes
  up to 25 s longer per check than a passing one.
