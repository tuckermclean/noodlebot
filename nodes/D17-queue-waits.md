# D17 — queue-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D05, G02, D11 | D20, D22 | S |

**Owns:** in the end-to-end loop tests `scheduler/loop-s07-failed.test.sh` (Phase F) and
`scheduler/loop-g02-review3.test.sh` (review1d #5 with 254): how each case waits, the order of and the waits between its
setup steps, the settings a case starts its loops with (`SCHED_TICK`, `SCHED_START_GAP` and the like) and the time
bounds its waits use; in the fixtures they source (`scheduler/testdata/lib/loop-s07.sh`, `loop-g02.sh`,
`loop-g02-review.sh`) and in `scheduler/testdata/lib/loop-prelude.sh`: new helpers, and an existing helper or default
setting only where Change 1 names it as a cause (Change 2); `scheduler/testdata/lib/loop-fakes.sh` stays unchanged (a
new helper goes in `loop-prelude.sh` or the file's own fixture); the record of the diagnosis and of the runs, in the
node's PR and under `out/node/D17/`. As D05, M02 and D13 did for theirs, this spec allows changing these frozen test
lines' waits, setup order and settings, never what a check expects (Change 3), and the PR lists each changed frozen line
for the owner's approval.
**Resolves:** #202

## Purpose
After this node two end-to-end loop checks that failed in CI on timing alone pass on a loaded runner: S07-AC-4's "and
the queue still spaces them by the gap (4 s)" in `loop-s07-failed.test.sh` (line 54, `qgap_n 2 3.6`, Phase F) and
G02-AC-1's "when the throttle is released, 254 gets its update session" in `loop-g02-review3.test.sh` (line 23,
`waitf 10 g02_runsis 254 1`). Both failed in the same CI job on spec-only PR #194, which touches neither file. They are
the class D13 fixed for four other files: a check bounded by wall-clock time or by tick spacing around loops that tick
every one to two seconds. The node finds out from the CI log and recorded loaded runs why each check fails, then makes
the cases wait for the ticks, turns, starts and status-log lines they check, without loosening any check.

## Tests
- The two test files, changed only as Change 3 allows: every `PASS:` line of the base is a `PASS:` line at the head,
  word for word.
- Every other test file that sources a fixture helper or default the node changes (the `loop-s07*` files and
  `loop-p03-ramp` for `loop-s07.sh`, the `loop-g02*` files for `loop-g02.sh` and `loop-g02-review.sh`, and, for a change
  to `loop-prelude.sh`, every `scheduler/loop*.test.sh`) passes with the same `PASS:` lines.
- The recorded runs in the PR (Changes 1 and 4), at the node's base and at its head.

## Changes
1. **Diagnose from the CI log, then under load.** First the CI log of the run named in the issue: job 135381912924 of
   PR #194's CI, head `23b4db8`, 2026-11-19. It is saved under `out/node/D17/` (CI logs expire); a log the session
   cannot fetch (the forge CLI has no log operation) is recorded as such, and the PR uses the excerpts this Change
   quotes in its place. What it shows:
   - S07-AC-4 (`loop-s07-failed.test.sh`, 55.05 s): `FAIL: S07-AC-4: and the queue still spaces them by the gap (4 s)`
     with `starts: B01 B04`; Phase E's checks and Phase F's line 53 ("a loop whose heartbeat is older than three ticks
     is left out") passed;
   - G02-AC-1 (`loop-g02-review3.test.sh`): `FAIL: G02-AC-1 (review1d #5, ramp=1): when the throttle is released, 254
     gets its update session`; the checks of lines 19 ("the throttle engages") and 21 ("while the throttle holds … 254
     gets no update") passed, and the status.log the test printed ends before an update start for 254 is logged.

   Then, on the scheduler's machine, with the load kept to half its CPUs (at least one) so that other sessions keep
   the rest: the two files and one CPU-bound process per pinned CPU run under one `taskset -c <those CPUs>`, each load
   process bounded so that it cannot outlive its run (for example `timeout 900 yes >/dev/null`, killed when the run
   ends). Run the two files together, `make test TESTS="<the two files>"` with `TEST_JOBS` at its default, at the node's
   base until one of the checks the Purpose lists fails, up to ten runs; if none fails, up to ten more with two such
   processes per pinned CPU. Each run's log goes under `out/node/D17/`. For each check that fails, the PR records the
   failing run's `FAIL:` line and what the case waited on that the load broke (which bound, which tick, turn or start it
   assumed), from the loops' status logs, heartbeats and the start queue's records in that run (a run may log more, in
   a scratch copy only). The read checks first the causes found before:
   - D05's: under load a tick at `SCHED_TICK=1` took 4.7–7.4 s on average and up to 11.4 s (D05's PR #118), so a
     bound of a few seconds covers less than one tick; review3's loop runs with `SCHED_TICK=1` and the queue
     (`SCHED_RAMP=1`, `turn.py`), so after line 22 releases the throttle it must read the new rate-limit event and
     then take a turn before 254 starts, all within line 23's `waitf 10`;
   - M02's and D13's: the give-up waits (review3's unchecked `wait_ticks 3` at line 20, and in Phase F the
     `wait_until 15 qev_ge 2` of line 52, each of which gives up after its bound and lets the case go on) and a bound in
     seconds that stands for something else;
   - for S07's gap: what the bound is measured on. `qgap_ok` compares the start times the fake sessions write to
     `starts.log` by their own clocks, not the turns the queue grants, so a session that the load delays after its turn
     (B01) and one that starts promptly after the next turn (B04) can be logged closer than the gap the queue kept. The
     PR records the turn times of B01 and B04 (the status logs' start events and `turn.py`'s records) beside their
     `starts.log` times.
   *D17-AC-1.*
2. **Wait for the condition, not the clock.** Each case waits until the state its next check reads holds: a start the
   check counts is waited for through the loop's run records, the queue's records or the status log; a wait that gives
   up and goes on becomes a wait that fails a check naming its condition when it times out; a "did not happen" check
   waits for the loop's ticks to have visibly passed (`wait_ticks`, D03's rule); a case's loop may run with a longer
   `SCHED_TICK` (or another setting) where Change 1 names it as the cause, set per case where the fixture is shared. A
   wait's timeout may grow only where the check's words state no time and Change 1 records why the old one ran out. An
   existing helper or default in a shared fixture changes only where Change 1 names it as a cause, and then every test
   file that sources it keeps its `PASS:` lines. A fixed sleep or a wall-clock bound stays only where no condition can
   be observed, with a comment saying why. Each file stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI
   (`test.yml`'s `TEST_FILE_BUDGET`, 60 s at this spec's base); the unloaded run's `TIME` lines of the two files are
   recorded at the base and at the head, and the loaded runs of Change 4 record theirs.
   *D17-AC-2, D17-AC-3.*
3. **No check loosened.** No expected value, pattern, order, count, event text or check name changes; "order" here is
   the order a check expects (of starts, events or lines), not the order of a case's setup steps. The gap check of
   line 54 keeps D05-AC-3's bound: a gap of 4 s checked as at least 3.6 s between B01's and B04's starts. Where Change 1
   shows that the starts it compares are the fake sessions' own clocks and not the queue's turns, it may compare the
   times the loops record for those starts (their turns or status-log start events) instead, at the same bound, which
   checks the check's own words ("the queue … spaces them") at least as strictly; it never compares fewer starts or a
   smaller gap. *D17-AC-3.*
4. **Show it holds.** At the head, ten consecutive runs of the two files under the heaviest load at which Change 1 saw
   a failure (one process per pinned CPU when none was seen) pass with no `FAIL:` line, each run's log under
   `out/node/D17/` and its `TIME` lines in the PR; the files that source a fixture helper or default the node changed
   pass in the quick gate; CI passes on the PR. *D17-AC-2.*
5. **Ask for the frozen lines.** The PR lists every frozen test or fixture line the node changes (file, line at the
   base, the line before and after, and the Change 1 cause it answers) and asks the owner to approve them.
   *D17-AC-3.*

## Gate
- **D17-AC-1** — The PR records, for each check the Purpose lists that failed in the CI job Change 1 names (from its log, or Change 1's excerpts where the log cannot be fetched), and each check of the two files that failed in the loaded runs at the node's base (Change 1's load, up to ten runs at one CPU-bound process per pinned CPU and ten more at two), the failing `FAIL:` line and the cause: what the case waited on or measured and how the load broke it, with D05's loaded tick length, the give-up waits and the clock `qgap_ok` reads checked first, and for S07's gap the turn times of B01 and B04 beside their `starts.log` times. If the loaded runs show no failure of those checks, it records the twenty runs, and the node makes Change 2's changes for the causes the CI log shows and for the give-up waits and the bounds Change 1 names. *Verify:* the recorded runs, the saved CI log (or the record that it could not be fetched) and the diagnosis table in the PR, checked by the fresh reviewer.
- **D17-AC-2** — At the node's head, ten consecutive runs of the two files under Change 4's load pass with no `FAIL:` line, and each of the two files stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI (`test.yml`'s `TEST_FILE_BUDGET`, 60 s at this spec's base); every test file that sources a fixture helper or default the node changed passes; CI passes on the PR. *Verify:* the ten recorded runs (their `FAIL:` count and the two files' `TIME` lines), the unloaded run's and CI's `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D17-AC-3** — The node changes the tests only as Changes 2 and 3 allow: every `PASS:` line of the two files, and of each file that sources a fixture helper or default the node changed, in a base run in which those files passed is the same `PASS:` line at the head; no expected value, pattern, expected order, count or event text changes; the gap check keeps its 4 s gap and 3.6 s bound over the same two starts, and a changed measure compares the loops' own records of those starts; no file outside **Owns** changes; each fixed sleep or wall-clock bound left in the waits the node touched has a comment saying why no condition can be observed; the PR lists each changed frozen line (file, base line, before and after, cause) for the owner's approval. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines, recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- The load a test can survive is not unlimited: a runner far busier than Change 1's load can still stretch a tick
  past a bound. The recorded runs say what load was shown; `loop-s07-failed.test.sh` took 55.05 s in the failing CI
  job, close to CI's 60 s `TEST_FILE_BUDGET`, so a longer wait there can push it over (node D15, open as PR #201, sets
  CI's budgets from measured runs).
- Running only the two files beside CPU-bound processes may not reproduce failures seen in a whole loaded `make test`;
  the CI excerpts Change 1 quotes cover that.
- Other loop test files run their loops at `SCHED_TICK=1` with bounds in seconds too (the other `loop-s07*` and
  `loop-g02*` files among them); they are not in this node's **Owns**, and an issue naming them gets a node of its own,
  as this one did.
- A cause in the scheduler itself rather than in a test's wait, setup or measure (`turn.py` granting B04's turn before
  the gap had passed since B01's, or the loop not starting 254 after the throttle is released, say) is not this node's
  to fix: it is recorded with its evidence and put to the owner as a question.
- CI on a PR also enforces the total (`test.yml`'s `TEST_BUDGET`, 360 s at this spec's base), which slow runners
  exceed with no test change; a CI run that fails only on other files' `SLOW` lines or the total is rerun, both run URLs
  recorded; if the reruns keep failing only on those, the node records them and puts it to the owner as a question.
- A wait for a condition with a long timeout turns a broken loop into a failure at the timeout, so a failing run takes
  longer than a passing one.
