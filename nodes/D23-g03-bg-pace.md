# D23 — g03-bg-pace

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G03 | none | S |

**Owns:** in the end-to-end loop test `scheduler/loop-g03-bg.test.sh`: U-1's pace check (line 46 at this spec's base,
`ticks_in 8 4`), the setup steps of case U-1 (lines 43 to 45 and 48), the helper it uses (`ticks_in`, lines 18 to 29)
and the lines that make the fake `gh` slow (lines 9 and 10), as far as U-1 uses them; a new helper or a new hold file
of the fake for this file goes in this file; `scheduler/testdata/lib/` stays unchanged; the record of the runs, in
the node's PR and under `out/node/D23/`. As D05, M02, D13, D17 and D20 did for theirs, this spec allows changing these
frozen test lines (Change 3), and the PR lists each changed frozen line for the owner's approval.
**Resolves:** #255

## Purpose
After this node G03's check that the loop's ticks keep their pace while a run of `feedback.py` is in flight (U-1 in
`loop-g03-bg.test.sh`) passes on a loaded runner. It failed in CI on timing alone on spec-only PR #242, which touches
no test file: `FAIL: U-1: the ticks keep their pace while the run is in flight: 4 ticks within 8 s (a run takes about
12 s)`. The check is about order, not speed: the ticks must not wait for the background run. Comparing the ticks
against seconds of wall-clock time is what makes it flaky, since a loaded runner stretches ticks at `SCHED_TICK=1` to
several seconds even when nothing blocks them. The node makes the check count the ticks that pass while one run is
held open by the fake, with no bound in seconds other than a generous give-up ceiling, and shows that the check
still fails against a loop that waits for the run.

## Tests
- `scheduler/loop-g03-bg.test.sh`, changed only as Change 3 allows: every `PASS:` line of the base other than U-1's
  pace check is a `PASS:` line at the head, word for word.
- The recorded runs in the PR (Changes 1, 2 and 4), at the node's base and at its head, and the mutant run of
  Change 2.

## Changes
1. **Record what failed.** First the CI log of the run named in the issue: job 138901393476 of run 45523619813, PR
   #242's CI, head `29b43ff`, 2026-11-25. It can be fetched with the forge CLI's `ci logs --run 45523619813` (G08)
   and is saved under `out/node/D23/` (CI logs expire); a log the session cannot fetch is recorded as such, and the
   PR uses the excerpts this Change quotes in its place. What it shows: `TIME 40.69 scheduler/loop-g03-bg.test.sh`
   (about 23 s in the green run 45512562908, 20.95 s unloaded on the scheduler's machine at this spec's base); `PASS:
   U-1 setup: a run of feedback.py is in flight under the slow api`, then the `FAIL:` line above, then `PASS: U-1: and
   a feedback.py is still running (the loop did not wait for it)`: the run was still in flight after the 8 s, so the
   loop did not wait for it; its ticks were only slower than 2 s each. Every other check of the file passed. The same
   job also failed checks of other files (S07-AC-7 in `loop-s07-turnpy.test.sh`, a G02-AC-2 check in a `loop-g02*`
   file), which are not this node's.

   Then, on the scheduler's machine, with the load kept to half its CPUs (at least one) so that other sessions keep
   the rest, each run under one `taskset -c <those CPUs>`, each load process bounded so that it cannot outlive its run
   (for example `timeout 900 yes >/dev/null`, killed when the run ends), at the node's base: up to ten runs of `make
   test` of the `loop-g03*` files with `TEST_JOBS` at twice the number of pinned CPUs beside one CPU-bound process per
   pinned CPU (D20's heaviest load shape), stopping at the first run in which U-1's pace check fails. Each run's log
   goes under `out/node/D23/`, with the file's `TIME` line and, for a failing run, how many times the loop's
   heartbeat changed in the check's 8 s. *D23-AC-1.*
2. **Count ticks against the held run, not the clock.** While U-1's check reads, the one run of `feedback.py` stays
   in flight because the fake `gh` holds it open (a hold the test makes and releases, for example a file the fake
   waits on), not because a sleep of a fixed length has not yet ended; the test releases the hold after the check has
   read its count. The check passes when at least 3 of the loop's ticks have started (its heartbeat changed 3 times)
   after the run was seen in flight and that run is still in flight when the count is read; the run is the same one
   throughout (the file's sampler still finds no second listing run). The check's only time bound is a give-up
   ceiling well above any loaded tick length (60 s or more, inside `TEST_FILE_BUDGET`); reaching it fails the check
   with a `FAIL:` line that names the condition and the count reached, and never passes it. A fixed sleep or a
   wall-clock bound stays only where no condition can be observed, with a comment saying why. U-4's slow api
   (`fb.slow1`, whose 12 s keeps an orphaned run alive at its `fbnone` checks) stays as it is.

   The new check still catches what U-1 is for: in a scratch copy of the tree (never the node's worktree, as
   AGENTS.md's rule for a mutation sweep says), a `scheduler/loop.sh` changed to wait for the feedback run in the
   tick that starts it (for example a `wait "$fb_pid"` after the start) makes U-1's new check fail, recorded with its
   `FAIL:` line and the file's `TIME` line; a mutant that only slows each tick does not have to fail it. The file
   stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI (`test.yml`'s `TEST_FILE_BUDGET`, 105 s at this
   spec's base); the unloaded run's `TIME` lines are recorded at the base and at the head. *D23-AC-2, D23-AC-3.*
3. **No other check loosened.** U-1's pace check is the one check whose words and condition change: it no longer
   states seconds, it counts at least 3 ticks while the one run is held in flight, and its name says so (for
   example `U-1: the ticks keep their pace while the run is in flight: 3 ticks pass while the one run is held open`).
   Every other check keeps its name, expected value, pattern, order and count, among them `U-1: and a feedback.py is
   still running (the loop did not wait for it)` and both of U-1's checks that the listing runs never overlapped.
   U-2 still sees its item from the first whole run under the slow api. *D23-AC-3.*
4. **Show it holds.** At the head, ten consecutive runs under Change 1's load shape have no `FAIL:` line from
   `loop-g03-bg.test.sh`, each run's log under `out/node/D23/` and the file's `TIME` line in the PR; a `FAIL:` line of
   another `loop-g03*` file in those runs is recorded and, if it also fails at the base, is not this node's. The
   quick gate passes and CI passes on the PR. *D23-AC-2.*
5. **Ask for the frozen lines.** The PR lists every frozen test line the node changes (file, line at the base, the
   line before and after, and why) and asks the owner to approve them, as U05's frozen-line record of the final
   review names them. *D23-AC-3.*

## Gate
- **D23-AC-1** — The PR records the failing check of the CI job Change 1 names (from its saved log, or Change 1's excerpts where the log cannot be fetched): its `FAIL:` line, the file's `TIME` line, and that the next check found the run still in flight; and the base runs under Change 1's load shape (up to ten, stopping at the first in which U-1's pace check fails), each with its log, the file's `TIME` line and, for a failing run, the heartbeat changes counted in the check's 8 s. If the ten base runs show no failure, it records them, and the node makes Change 2's change for the cause the CI log shows. *Verify:* the recorded runs and the saved CI log (or the record that it could not be fetched) in the PR, checked by the fresh reviewer.
- **D23-AC-2** — At the node's head U-1's pace check counts at least 3 ticks while the one run of `feedback.py` is held open by the fake, released after the count is read, with no bound in seconds but a give-up ceiling of 60 s or more that fails the check; in a scratch copy, a `loop.sh` that waits for the feedback run in the tick that starts it makes the check fail; ten consecutive runs under Change 4's load have no `FAIL:` line from `loop-g03-bg.test.sh`; the file stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI (105 s at this spec's base); the quick gate and CI pass on the PR. *Verify:* `sh scheduler/loop-g03-bg.test.sh`; the mutant run's `FAIL:` line, the ten recorded runs (their `FAIL:` lines and the file's `TIME` lines), the unloaded run's and CI's `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D23-AC-3** — The node changes the tests only as Changes 2 and 3 allow: every `PASS:` line of `loop-g03-bg.test.sh` in a passing base run other than U-1's pace check is the same `PASS:` line at the head; no other check's expected value, pattern, order, count or name changes; U-4's slow api is unchanged; no file outside **Owns** changes (`scheduler/testdata/lib/` unchanged); each fixed sleep or wall-clock bound left in the lines the node touched has a comment saying why no condition can be observed; the PR lists each changed frozen line (file, base line, before and after, why) for the owner's approval. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines, recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- The load a test can survive is not unlimited: a runner so busy that 3 ticks take longer than the ceiling still
  fails the check. The ceiling is set far above the loaded tick lengths recorded before (D05's PR #118: 4.7–7.4 s on
  average, up to 11.4 s), and the recorded runs say what load was shown.
- A hold the test makes must always be released, also when a check fails or the file exits early, so that no
  `feedback.py` of the loop is left waiting; the file's cleanup releases it, and U-4's checks that no `feedback.py`
  is left running still pass.
- Holding the run open changes what U-2 starts from if the hold outlasts U-1; the hold is released before U-2's
  feedback is added, and U-2's checks keep their `PASS:` lines.
- The loaded `loop-g03*` runs may fail other files' timing checks at the base too (as D20's loaded `loop-g02*` runs
  did); those are recorded and are not this node's, and a cause found in the scheduler itself rather than in the
  check is recorded with its evidence and put to the owner as a question.
- CI on a PR also enforces the total (`test.yml`'s `TEST_BUDGET`, 630 s at this spec's base) and runs every other
  file, whose timing failures (as in the job Change 1 names) are not this node's; a CI run that fails only on those
  is rerun, both run URLs recorded; if the reruns keep failing only on those, the node records them and puts it to
  the owner as a question.
