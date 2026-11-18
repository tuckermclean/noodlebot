# D13 — loop-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S01, S02, G01, G06, D11 | none | M |

**Owns:** in the end-to-end loop tests `scheduler/loop-g06-question.test.sh`, `scheduler/loop-s02.test.sh`,
`scheduler/loop-s01.test.sh` and `scheduler/loop-g01-lim.test.sh`: how each case waits, the settings a case starts its
loop with (`SCHED_TICK` and the like) and the time bounds its waits use; in the fixtures they source
(`scheduler/testdata/lib/loop-g01.sh`, `loop-g03.sh`, `loop-g06.sh`, `loop-s01.sh`) and in
`scheduler/testdata/lib/loop-prelude.sh`: new helpers, and an existing helper or default setting only where Change 1
names it as a cause (Change 2); the record of the diagnosis and of the runs, in the node's PR and under `out/node/D13/`.
As D05 and M02 did for theirs, this spec allows changing these frozen test lines' waits and settings, never what a
check expects (Change 3).
**Resolves:** #145

## Purpose
After this node four end-to-end loop tests that failed in CI on timing alone pass on a loaded runner: G06-AC-2's
setup in `loop-g06-question.test.sh` ("the answered update of PR 11 starts and runs" and the three checks after it),
S02-AC-2 in `loop-s02.test.sh` ("and starts again (a third run)", "its start was given back …", "the end is one
status-log event …"), S01-AC-1 in `loop-s01.test.sh` ("its process group is gone within a tick") and G01-AC-6 in
`loop-g01-lim.test.sh` ("two starts are both start 1 of 2"). Each failed on a PR that does not touch it, and passes
alone. Their waits are bounded in seconds around loops that tick every second (`SCHED_TICK=1`), and one of them gives
up and goes on (`loop-s02.test.sh`'s `timeout 12 sh -c "until …"`). The node finds out from recorded runs why each
check fails under load, starting from the causes D05 and M02 found, then makes the cases wait for the ticks, starts
and status-log lines they check, without loosening any check.

## Tests
- The four test files, changed only as Change 3 allows: every `PASS:` line of the base is a `PASS:` line at the head,
  word for word.
- Every other test file that sources a fixture helper or default the node changes (the `loop-g01*`, `loop-g03*`,
  `loop-g06*`, `loop-s01*`, `loop-u03*` and `loop-R02-prompts` files do today) passes with the same `PASS:` lines.
- The recorded runs in the PR (Changes 1 and 4), at the node's base and at its head.

## Changes
1. **Diagnose under load.** On the scheduler's machine, with one CPU-bound process per CPU running beside it (for
   example `yes >/dev/null`, one per `nproc`), run the four files together, `make test TESTS="<the four files>"` with
   `TEST_JOBS` at its default, at the node's base until one of the checks the Purpose lists fails, up to ten runs; if
   none fails, up to ten more with two such processes per CPU. Each run's log goes under `out/node/D13/`. For each check
   that fails, the PR records the failing run's `FAIL:` line and what the case waited on that the load broke (which
   bound, which tick or start it assumed), from the loop's status log and heartbeat in that run (a run may log more,
   as D05's instrumented run did, in a scratch copy only). The read checks first the two causes found before:
   - D05's: `turn.py` counts a loop as live only while its heartbeat is under 3 × `SCHED_TICK` old, so a loop at
     `SCHED_TICK=1` whose tick takes longer than that on a loaded machine is granted no turn, and no session starts;
   - M02's: a wait that gives up and lets the case go on (here `loop-s02.test.sh`'s `timeout 12 sh -c "until …"`
     before S02-AC-1 and S02-AC-2), and a bound in seconds that stands for something else ("within a tick" as
     `waitf 4`).
   The CI failures named in the issue are recorded with their run IDs: 44023182252 (G06-AC-2), 44024736160 (S02-AC-2),
   44037857263 attempt 2 (S01-AC-1, G01-AC-6). *D13-AC-1.*
2. **Wait for the condition, not the clock.** Each case waits until the state its next check reads holds: a start the
   check counts is waited for through the loop's run records or status log; a wait that gives up and goes on becomes a
   wait that fails a check naming its condition when it times out; a "did not happen" check waits for the loop's ticks
   to have visibly passed (`wait_ticks`, D03's rule); a case's loop may run with a longer `SCHED_TICK` (or another
   setting) where Change 1 shows the turn liveness broke it, set per case where the fixture is shared. A wait's
   timeout may grow only where the check's words state no time and Change 1 records why the old one ran out. An
   existing helper or default in a shared fixture changes only where Change 1 names it as a cause, and then every test
   file that sources it keeps its `PASS:` lines. A fixed sleep or a wall-clock bound stays only where no condition can
   be observed, with a comment saying why. Each file stays under `TEST_FILE_BUDGET` (30 s) in the runs of Change 4.
   *D13-AC-2, D13-AC-3.*
3. **No check loosened.** No expected value, pattern, order, count, event text or check name changes. A bound that
   only approximates a check's own words may be replaced by a check of those words that is at least as strict:
   S01-AC-1's "gone within a tick" (`waitf 4`) may become a check in the loop's ticks (for example, the group is gone
   before the second heartbeat the loop writes after the PR is marked merged). *D13-AC-3.*
4. **Show it holds.** At the head, ten consecutive runs of the four files under the heaviest load at which Change 1
   saw a failure (one process per CPU when none was seen) pass with no `FAIL:` line, each run's log under
   `out/node/D13/` and its `TIME` lines in the PR; the files that source a fixture helper or default the node changed
   pass in the quick gate; CI passes on the PR. *D13-AC-2.*

## Gate
- **D13-AC-1** — The PR records, for each check the Purpose lists that failed in the loaded runs at the node's base (Change 1's load, up to ten runs at one CPU-bound process per CPU and ten more at two), the failing `FAIL:` line and the cause: what the case waited on and how the load broke it, with D05's turn liveness and M02's give-up waits checked first, and the issue's three CI runs named. Or, if those twenty runs show no failure of those checks, it records the twenty runs, and the node makes only Change 2's waits for the waits Change 1 names (the give-up wait of `loop-s02.test.sh` and the bounds before the listed checks). *Verify:* the recorded runs and the diagnosis table in the PR, checked by the fresh reviewer.
- **D13-AC-2** — At the node's head, ten consecutive runs of the four files under Change 4's load pass with no `FAIL:` line, and each file stays under `TEST_FILE_BUDGET`; every test file that sources a fixture helper or default the node changed passes; CI passes on the PR. *Verify:* the ten recorded runs (their `FAIL:` count and the four files' `TIME` lines), the quick gate's output and the CI run URL, in the PR.
- **D13-AC-3** — The node changes the tests only as Changes 2 and 3 allow: every `PASS:` line of the four files, and of each file that sources a fixture helper or default the node changed, at the base is the same `PASS:` line at the head; no expected value, pattern, order, count or event text changes; a replaced bound checks the check's own words at least as strictly; no file outside **Owns** changes; each fixed sleep or wall-clock bound left in the waits the node touched has a comment saying why no condition can be observed. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD`, recorded in the PR with the sorted `PASS:` lines of a base run and a head run and their diff.

## Risks
- The load a test can survive is not unlimited: a runner far busier than Change 1's load can still stretch a tick
  past a bound. The recorded runs say what load was shown; CI runners vary about 1.6× in speed.
- Other loop test files run their loops at `SCHED_TICK=1` with bounds in seconds too; they are not in this node's
  **Owns**, and an issue naming them gets a node of its own, as this one did.
- A cause in the scheduler itself rather than in a test's wait (the loop missing a start, say) is not this node's to
  fix: it is recorded with its evidence and put to the owner as a question.
- Longer ticks or more waited ticks make the files slower; the 30 s per-file budget still applies.
- A wait for a condition with a long timeout turns a broken loop into a failure at the timeout, so a failing run takes
  longer than a passing one.
