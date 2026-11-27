# D20 — g02-end-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | G02, D17 | none | S |

**Owns:** in the end-to-end loop test `scheduler/loop-g02-end.test.sh`: how each case waits, the order of and the
waits between its setup steps, the settings its loop starts with (`SCHED_TICK` and the like) and the time bounds its
waits use; in the fixture it sources (`scheduler/testdata/lib/loop-g02.sh`) and in
`scheduler/testdata/lib/loop-prelude.sh`: new helpers, and an existing helper or default setting only where Change 1
names it as a cause (Change 2); `scheduler/testdata/lib/loop-fakes.sh` stays unchanged (a new helper goes in
`loop-prelude.sh` or `loop-g02.sh`); the record of the diagnosis and of the runs, in the node's PR and under
`out/node/D20/`. As D05, M02, D13 and D17 did for theirs, this spec allows changing these frozen test lines' waits,
setup order and settings, never what a check expects (Change 3), and the PR lists each changed frozen line for the
owner's approval.
**Resolves:** #233

## Purpose
After this node G02-AC-2's check "when main moves, it is started again (start 1 of 2 again)" in
`loop-g02-end.test.sh` (line 36 at this spec's base, `waitf 8 g02_runsis 201 2`) passes on a loaded runner. It failed
in CI on timing alone on spec-only PR #227, which touches no test file, and was the file's only failure. It is the
class D13 and D17 fixed for six other checks: a check bounded by wall-clock seconds around a loop that ticks every
second (`SCHED_TICK=1`), whose ticks a loaded machine stretches to several seconds. The file's other waits use bounds
in seconds too (`waitf 3` to `waitf 8`, and waits that give up and let the case go on), so the node checks them all.
It finds out from the CI log and recorded loaded runs why each one fails or can fail, then makes the cases wait for
the ticks, starts and status-log lines they check, without loosening any check.

## Tests
- `scheduler/loop-g02-end.test.sh`, changed only as Change 3 allows: every `PASS:` line of the base is a `PASS:` line
  at the head, word for word.
- Every other test file that sources a fixture helper or default the node changes (the `loop-g02*` files for
  `loop-g02.sh`, and, for a change to `loop-prelude.sh`, every `scheduler/loop*.test.sh`) passes with the same `PASS:`
  lines.
- The recorded runs in the PR (Changes 1 and 4), at the node's base and at its head.

## Changes
1. **Diagnose from the CI log, then under load.** First the CI log of the run named in the issue: job 138195774554 of
   run 45319936644, PR #227's CI, head `784ed79`, 2026-11-24. It can be fetched with the forge CLI's `ci logs --run
   45319936644` (G08) and is saved under `out/node/D20/` (CI logs expire); a log the session cannot fetch is recorded
   as such, and the PR uses the excerpts this Change quotes in its place. What it shows: `TIME 45.34
   scheduler/loop-g02-end.test.sh`; every check before line 36 passed, as did lines 40 and 42; `FAIL: G02-AC-2: when
   main moves, it is started again (start 1 of 2 again)`, and the status log the failing check printed has the rc 0
   end of PR #201's first update at 03:36:19, `nothing ready` at 03:36:20 and then, as its last line, PR #201's second
   start (`start 1 of 2`) at 03:36:35: the start was logged by the time the check printed its failure.

   Then, on the scheduler's machine, with the load kept to half its CPUs (at least one) so that other sessions keep
   the rest, each run under one `taskset -c <those CPUs>`, each load process bounded so that it cannot outlive its run
   (for example `timeout 900 yes >/dev/null`, killed when the run ends). At the node's base, until the check of
   line 36 or another check of the file fails: up to ten runs of `make test TESTS=scheduler/loop-g02-end.test.sh`
   beside one CPU-bound process per pinned CPU; if none fails, up to ten runs of `make test` of the `loop-g02*` files
   with `TEST_JOBS` at twice the number of pinned CPUs beside one CPU-bound process per pinned CPU. Each run's log goes
   under `out/node/D20/`. For each check that fails, the PR records the failing run's `FAIL:` line and what the case
   waited on that the load broke (which bound, which tick or start it assumed), from the loop's status log, its
   heartbeat and the fake sessions' run counts in that run (a run may log more, in a scratch copy only). The read
   checks first the causes found before:
   - D05's: under load a tick at `SCHED_TICK=1` took 4.7–7.4 s on average and up to 11.4 s (D05's PR #118), so a
     bound of 8 s can cover a single tick; the PR records how many of the loop's ticks pass, at the base, from
     `g02_mvref main` (line 35) to PR #201's second start in the status log;
   - what the check counts: `g02_runs` reads `runs.<PR>`, which the fake `claude` writes once it runs
     (`loop-g02.sh` line 119), after the loop has logged the start, so the count can lag the status log's start line;
   - M02's, D13's and D17's: the give-up waits (the unchecked `waitf` of lines 21, 27, 37 and 41 and the unchecked
     `wait_ticks` of lines 24, 33 and 38, each of which gives up after its bound and lets the case go on, so a slow
     earlier step can move into the next check's bound) and a bound in seconds that stands for something else.

   The PR's diagnosis table has a row for every `waitf <seconds>` and `wait_ticks` of the file (lines 16, 20, 21, 23,
   24, 27, 31, 32, 33, 36, 37, 38, 40 and 41 at this spec's base): what it waits on, whether it is a check or a setup
   step, whether it fails or gives up at its bound, and whether the loaded runs or the reading above show the load can
   break it. *D20-AC-1.*
2. **Wait for the condition, not the clock.** Each case waits until the state its next check reads holds: a start the
   check counts is waited for through the loop's status log or the fake sessions' run counts; a wait that gives up and
   goes on becomes a wait that fails a check naming its condition when it times out; a "did not happen" check waits
   for the loop's ticks to have visibly passed (`wait_ticks`, D03's rule); a bound that stands for a number of the
   loop's ticks is counted in ticks, not seconds; the file's loop may run with a longer `SCHED_TICK` (or another
   setting) where Change 1 names it as the cause, set for this file only, since `g02_loop` starts the loop of every
   `loop-g02*` file. A wait's timeout may grow only where the check's words state no time and Change 1 records why the
   old one ran out. An existing helper or default in a shared fixture changes only where Change 1 names it as a cause,
   and then every test file that sources it keeps its `PASS:` lines. A fixed sleep or a wall-clock bound stays only
   where no condition can be observed, with a comment saying why. The file stays under `TEST_FILE_BUDGET` in an
   unloaded run (30 s; 18.71 s at this spec's base on the scheduler's machine) and in CI (`test.yml`'s
   `TEST_FILE_BUDGET`, 105 s at this spec's base; 45.34 s in the failing job); the unloaded run's `TIME` lines are
   recorded at the base and at the head, and the loaded runs of Change 4 record theirs. *D20-AC-2, D20-AC-3.*
3. **No check loosened.** No expected value, pattern, order, count, event text or check name changes; "order" here is
   the order a check expects (of starts, events or lines), not the order of a case's setup steps. The check of line 36
   still requires PR #201's run count to reach 2 after `main` moves and no earlier; a wait for the status log's second
   start of PR #201 may come before it, never in its place. The check of line 34 (not started again while `main` and
   the PR's head stay) still reads the count after the loop's ticks have visibly passed. *D20-AC-3.*
4. **Show it holds.** At the head, ten consecutive runs under the heaviest load shape at which Change 1 saw a failure
   (the `loop-g02*` files at twice the pinned CPUs when none was seen) pass with no `FAIL:` line, each run's log under
   `out/node/D20/` and its `TIME` line for `loop-g02-end.test.sh` in the PR; the files that source a fixture helper or
   default the node changed pass in the quick gate; CI passes on the PR. *D20-AC-2.*
5. **Ask for the frozen lines.** The PR lists every frozen test or fixture line the node changes (file, line at the
   base, the line before and after, and the Change 1 cause it answers) and asks the owner to approve them, as U05's
   frozen-line record of the final review names them. *D20-AC-3.*

## Gate
- **D20-AC-1** — The PR records, for the check of line 36 in the CI job Change 1 names (from its log, or Change 1's excerpts where the log cannot be fetched), and for each check of `loop-g02-end.test.sh` that failed in the loaded runs at the node's base (Change 1's two load shapes, up to ten runs each), the failing `FAIL:` line and the cause: what the case waited on or counted and how the load broke it, with D05's loaded tick length, the ticks from `main` moving to PR #201's second start, the lag of `runs.<PR>` behind the status log's start line and the give-up waits checked first; and a diagnosis table with a row for every `waitf <seconds>` and `wait_ticks` of the file (lines 16, 20, 21, 23, 24, 27, 31, 32, 33, 36, 37, 38, 40 and 41 at this spec's base). If the loaded runs show no failure, it records the twenty runs, and the node makes Change 2's changes for the cause the CI log shows and for the give-up waits and the bounds the table names. *Verify:* the recorded runs, the saved CI log (or the record that it could not be fetched) and the diagnosis table in the PR, checked by the fresh reviewer.
- **D20-AC-2** — At the node's head, ten consecutive runs under Change 4's load pass with no `FAIL:` line, and `loop-g02-end.test.sh` stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI (`test.yml`'s `TEST_FILE_BUDGET`, 105 s at this spec's base); every test file that sources a fixture helper or default the node changed passes; CI passes on the PR. *Verify:* the ten recorded runs (their `FAIL:` count and the file's `TIME` lines), the unloaded run's and CI's `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D20-AC-3** — The node changes the tests only as Changes 2 and 3 allow: every `PASS:` line of `loop-g02-end.test.sh`, and of each file that sources a fixture helper or default the node changed, in a base run in which those files passed is the same `PASS:` line at the head; no expected value, pattern, expected order, count or event text changes; line 36's check still requires PR #201's run count to reach 2; no file outside **Owns** changes; each fixed sleep or wall-clock bound left in the waits the node touched has a comment saying why no condition can be observed; the PR lists each changed frozen line (file, base line, before and after, cause) for the owner's approval. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines, recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- The load a test can survive is not unlimited: a runner far busier than Change 1's load can still stretch a tick
  past a bound counted in ticks. The recorded runs say what load was shown.
- Running the file alone or among the `loop-g02*` files may not reproduce a failure seen in a whole loaded `make
  test`; the CI excerpts Change 1 quotes cover that.
- `g02_loop` starts the loop of every `loop-g02*` file, so a setting changed in it reaches the others; a change for
  this file is made for this file only, or every `loop-g02*` file keeps its `PASS:` lines (Change 2).
- A cause in the scheduler itself rather than in a test's wait, setup or count (`loop.sh` not starting an update
  again after `main` moves until some interval longer than a few ticks has passed, say) is not this node's to fix: it
  is recorded with its evidence and put to the owner as a question.
- CI on a PR also enforces the total (`test.yml`'s `TEST_BUDGET`, 630 s at this spec's base), which slow runners
  exceed with no test change; a CI run that fails only on other files' `SLOW` lines, the total, or another file's
  timing failure that this node does not touch is rerun, both run URLs recorded; if the reruns keep failing only on
  those, the node records them and puts it to the owner as a question.
- A wait for a condition with a long timeout turns a broken loop into a failure at the timeout, so a failing run takes
  longer than a passing one.
