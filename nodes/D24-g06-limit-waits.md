# D24 — g06-limit-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G06 | none | S |

**Owns:** in G06's end-to-end loop test `scheduler/loop-g06-limit.test.sh`, the wait of one check: line 42 at this
spec's base, `G06-AC-3: and the status log says PR #13 is no longer open and its FEEDBACK.md moved`; the record of the
runs, in the node's PR and under `out/node/D24/`. As D05, M02, D13, D17 and D20 did for theirs, this spec allows
changing that one frozen test line's wait, never what it expects (Change 2), and the PR lists the changed line for the
owner's approval.
**Resolves:** #265

## Purpose
After this node G06-AC-3's status-log check in `loop-g06-limit.test.sh` passes on a loaded runner. It failed in CI on
timing alone on spec-only PR #260, which changes no code or test. The cause is known from the code and the log. In the
loop's cleanup of pending `FEEDBACK.md` files (`scheduler/loop.sh`), the loop first moves the file into `answered/`
and then writes the status-log line that says so. The test waits for the first (line 40, `waitf 15 test ! -e
"$p/FEEDBACK.md"`), then greps the status log once, at once (line 42). Under load the grep can run between the move
and the line. The node makes line 42 wait for the line with a bounded wait, as line 40 does for the file. Nothing else
in the test or the scheduler changes.

## Tests
- `scheduler/loop-g06-limit.test.sh`, changed only at line 42 as Change 2 allows: every `PASS:` line of the base is a
  `PASS:` line at the head, word for word.
- The recorded runs in the PR (Changes 1 and 3), among them the two scratch-copy mutant runs of Change 3.

## Changes
1. **Record what failed.** The CI log of the run named in the issue: job 139370355329 of run 45660962904, PR #260's
   CI, 2026-11-25. It can be fetched with the forge CLI's `ci logs --run 45660962904` (G08) and is saved under
   `out/node/D24/` (CI logs expire); a log the session cannot fetch is recorded as such, and the PR uses the excerpts
   this Change quotes in its place. What it shows: the file's first five `G06-AC-3` checks passed, among them `PASS:
   G06-AC-3: a shorter list that lacks PR 13: FEEDBACK.md leaves pr/13/` and `PASS: G06-AC-3: it is in
   pr/13/answered/ as <ts>-FEEDBACK.md`; then `FAIL: G06-AC-3: and the status log says PR #13 is no longer open and
   its FEEDBACK.md moved`, `FAIL: 1 check(s) failed` and `TIME 24.74 scheduler/loop-g06-limit.test.sh`. The PR quotes
   these lines and the two lines of `scheduler/loop.sh` at the node's base that move the file and then write the
   status-log line. *D24-AC-1.*
2. **Wait for the line.** Line 42's check waits until the status log has the line, with the bound line 40's wait uses
   (`waitf 15`), instead of reading it once. Its name, its pattern (`PR #13 is no longer open.*FEEDBACK.md moved`) and
   the file it reads (`$state/status.log`) stay word for word; it still fails, with the same `FAIL:` line, when the
   line has not come by the bound. No other line of the file changes, `scheduler/testdata/` and `scheduler/loop.sh`
   stay unchanged, and the file stays under `TEST_FILE_BUDGET` in CI (`test.yml`'s `TEST_FILE_BUDGET`, 105 s at this
   spec's base; 24.74 s in the failing job). *D24-AC-2.*
3. **Show the wait is what fixes it.** In a scratch copy of the tree (never the node's worktree, as AGENTS.md's rule
   for a mutation sweep says), with a `scheduler/loop.sh` that waits a few seconds (for example `sleep 3`) between
   moving the `FEEDBACK.md` and writing its status-log line, the file at the node's base fails line 42's check and the
   file at the node's head passes it; with a `scheduler/loop.sh` that never writes that line, the file at the head
   fails line 42's check. Each run's log and the file's `TIME` line are recorded. The quick gate passes and CI passes
   on the PR. *D24-AC-2.*
4. **Ask for the frozen line.** The PR lists the frozen test line the node changes (file, line at the base, the line
   before and after, and the cause of Change 1 it answers) and asks the owner to approve it, as U05's frozen-line
   record of the final review names it. *D24-AC-3.*

## Gate
- **D24-AC-1** — The PR records the failing check of the CI job Change 1 names (from its saved log, or Change 1's excerpts where the log cannot be fetched): its `FAIL:` line, the two passing checks before it and the file's `TIME` line; and the lines of `scheduler/loop.sh` at the node's base that move the `FEEDBACK.md` before they write its status-log line. *Verify:* the saved CI log (or the record that it could not be fetched) and the quoted lines in the PR, checked by the fresh reviewer.
- **D24-AC-2** — At the node's head line 42's check waits for its status-log line with a bound of 15 s and fails with its `FAIL:` line when the line does not come; in a scratch copy, a `loop.sh` that writes the line a few seconds after the move fails the check at the base and passes it at the head, and a `loop.sh` that never writes it fails the check at the head; the file stays under `TEST_FILE_BUDGET` in CI (105 s at this spec's base); the quick gate and CI pass on the PR. *Verify:* `sh scheduler/loop-g06-limit.test.sh`; the three mutant runs' logs and `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D24-AC-3** — The node changes only line 42 of `loop-g06-limit.test.sh`, and only its wait: every `PASS:` line of the file in a passing base run is the same `PASS:` line at the head; the check's name, pattern and file are unchanged; no file outside **Owns** changes (`scheduler/loop.sh` and `scheduler/testdata/` unchanged); the PR lists the changed frozen line (file, base line, before and after, cause) for the owner's approval. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines, recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- Other waits of the file (line 40's `waitf 15`, the `wait_ticks` of the limit case) can still give out on a runner
  far busier than CI's usual load; the issue names only line 42, and this node changes no other check. A later
  failure of another check is a new issue.
- CI on a PR runs every other file, and their timing failures are not this node's; a CI run that fails only on those,
  on other files' `SLOW` lines or on the total (`test.yml`'s `TEST_BUDGET`) is rerun, both run URLs recorded; if the
  reruns keep failing only on those, the node records them and puts it to the owner as a question.
- A wait for a condition turns a loop that never writes the line into a failure at the bound, so a failing run takes
  up to 15 s longer than a passing one.
