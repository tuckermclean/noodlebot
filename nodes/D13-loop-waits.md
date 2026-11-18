# D13 — loop-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S01, S02, G01, G06, D11 | none | M |

**Owns:** in the end-to-end loop tests `scheduler/loop-g06-question.test.sh`, `scheduler/loop-s02.test.sh`,
`scheduler/loop-s01.test.sh` and `scheduler/loop-g01-lim.test.sh`: how each case waits, the order of and the waits
between its setup steps, the settings a case starts its loop with (`SCHED_TICK` and the like) and the time bounds its
waits use; in the fixtures they source (`scheduler/testdata/lib/loop-g01.sh`, `loop-g03.sh`, `loop-g06.sh`,
`loop-s01.sh`) and in `scheduler/testdata/lib/loop-prelude.sh`: new helpers, and an existing helper or default setting
only where Change 1 names it as a cause (Change 2); `scheduler/testdata/lib/loop-fakes.sh` stays unchanged (a new
helper goes in `loop-prelude.sh`); the record of the diagnosis and of the runs, in the node's PR and under
`out/node/D13/`. As D05 and M02 did for theirs, this spec allows changing these frozen test lines' waits, setup order
and settings, never what a check expects (Change 3).
**Resolves:** #145

## Purpose
After this node four end-to-end loop tests that failed in CI on timing alone pass on a loaded runner: G06-AC-2 in
`loop-g06-question.test.sh` (after the owner's answer: "no feedback session starts while the answered update runs",
"nothing handed over meanwhile", "the update did not start again"), S02-AC-2 in `loop-s02.test.sh` (its nine checks of
C01, C02, C03 and C05, lines 75–87), S01-AC-1 in `loop-s01.test.sh` ("its process group is gone within a tick") and
G01-AC-6 in `loop-g01-lim.test.sh` ("two starts are both start 1 of 2"). Each failed in CI on a PR that does not touch
it. Their waits are bounded in seconds around loops that tick every second (`SCHED_TICK=1`), and several give up and
let the case go on (S02's `timeout 12 …` and `timeout 10 …`, S01's `wait_until 5`, and the unchecked
`wait_ticks`/`wait_polls` calls), so a loaded tick can turn a "did not happen" check into one made too early. G06's
failure is not a wait bound: its setup changes two things the loop reads (`ANSWER.md`, then PR 11's CONFLICTING state),
and a tick that sees one but not the other starts the feedback. The node finds out from the CI logs and recorded runs
why each check fails, then makes the cases wait for the ticks, starts and status-log lines they check, and set up what
the loop reads so that no tick sees it half done, without loosening any check.

## Tests
- The four test files, changed only as Change 3 allows: every `PASS:` line of the base is a `PASS:` line at the head,
  word for word.
- Every other test file that sources a fixture helper or default the node changes (the `loop-g01*`, `loop-g03*`,
  `loop-g06*`, `loop-s01*`, `loop-u03*` and `loop-R02-prompts` files do today, and, for a change to `loop-prelude.sh`,
  every `scheduler/loop*.test.sh`) passes with the same `PASS:` lines.
- The recorded runs in the PR (Changes 1 and 4), at the node's base and at its head.

## Changes
1. **Diagnose from the CI logs, then under load.** First the CI job logs of the runs named in the issue: each failed
   `ok` prints the loop's status.log. The runs are 44023182252 (G06-AC-2); 44024736160, 43993942491 and 43994554527
   (#133) (S02-AC-2); 44037857263 attempt 2 (S01-AC-1, G01-AC-6, S02-AC-2). Their logs are saved under
   `out/node/D13/` (CI logs expire); a log the session cannot fetch (the forge CLI has no log operation) is recorded as
   such, and the PR uses the excerpts quoted in the owner's review of the spec PR (#188) in its place. What they show:
   - G06-AC-2 (44023182252): after the answer, status.log has `started feedback session of X01 on PR #11 (3 items)`
     and no `started update of PR #11`; the checks of lines 37, 38 and 41 failed and line 40 passed;
   - S02-AC-2 (the four S02 runs): the same nine `FAIL:` lines, three each for C01 and C02 (lines 76–78, 81–83) and
     lines 84, 86 and 87, with C01–C05's second starts still running at the end of status.log: the `timeout 12` of
     line 72 gave up.
   Then, on the scheduler's machine, with one CPU-bound process per CPU running beside it (for example
   `yes >/dev/null`, one per `nproc`), run the four files together, `make test TESTS="<the four files>"` with
   `TEST_JOBS` at its default, at the node's base until one of the checks the Purpose lists fails, up to ten runs; if
   none fails, up to ten more with two such processes per CPU. Whole-suite `make test` runs under the same load (as
   D05's were) may stand in for any of these runs. Each run's log goes under `out/node/D13/`. For each check that
   fails, the PR records the failing run's `FAIL:` line and what the case waited on that the load broke (which bound,
   which tick or start it assumed), from the loop's status log and heartbeat in that run (a run may log more, as D05's
   instrumented run did, in a scratch copy only). The read checks first the causes found before:
   - D05's: under load a tick at `SCHED_TICK=1` took 4.7–7.4 s on average and up to 11.4 s (D05's PR #118), so a
     bound of a few seconds covers less than one tick. (Its turn-liveness cause needs the start queue, which these
     files run off: `SCHED_RAMP=0`.)
   - M02's: the give-up waits (`loop-s02.test.sh`'s `timeout 12 …` at line 72 and `timeout 10 …` at line 99,
     `loop-s01.test.sh`'s `wait_until 5`, and the `wait_ticks` and `wait_polls` calls not under `ok`, each of which
     gives up after its bound and lets the case go on), and a bound in seconds that stands for something else ("within
     a tick" as `waitf 4`);
   - a setup that changes two things the loop reads in one tick: G06-AC-2's `ANSWER.md` (line 33) before PR 11's
     CONFLICTING state (line 34). The loop reads the PR list once a tick but checks the question hold live, so a tick
     that listed PR 11 as MERGEABLE before line 34 and checked the hold after line 33 sees no update to run and nothing
     holding the feedback.
   *D13-AC-1.*
2. **Wait for the condition, not the clock.** Each case waits until the state its next check reads holds: a start the
   check counts is waited for through the loop's run records or status log; a wait that gives up and goes on becomes a
   wait that fails a check naming its condition when it times out; a "did not happen" check waits for the loop's ticks
   to have visibly passed (`wait_ticks`, D03's rule); a setup that changes several things the loop reads may change
   them in an order, or with a wait between them, such that no tick sees them half done, and what each check expects
   stays the same; a case's loop may run with a longer `SCHED_TICK` (or another setting) where Change 1 names it as
   the cause, set per case where the fixture is shared. A wait's timeout may grow only where the check's words state
   no time and Change 1 records why the old one ran out. An existing helper or default in a shared fixture changes only
   where Change 1 names it as a cause, and then every test file that sources it keeps its `PASS:` lines. A fixed sleep
   or a wall-clock bound stays only where no condition can be observed, with a comment saying why. Each file stays
   under `TEST_FILE_BUDGET` in an unloaded run and in CI; the loaded runs of Change 4 record their `TIME` lines.
   *D13-AC-2, D13-AC-3.*
3. **No check loosened.** No expected value, pattern, order, count, event text or check name changes; "order" here is
   the order a check expects (of starts, events or lines), not the order of a case's setup steps. A bound that only
   approximates a check's own words may be replaced by a check of those words that is at least as strict: S01-AC-1's
   "gone within a tick" (`waitf 4`) may become a check in the loop's ticks (for example, the group is gone before the
   second heartbeat the loop writes after the PR is marked merged). *D13-AC-3.*
4. **Show it holds.** At the head, ten consecutive runs of the four files under the heaviest load at which Change 1
   saw a failure (one process per CPU when none was seen) pass with no `FAIL:` line, each run's log under
   `out/node/D13/` and its `TIME` lines in the PR; the files that source a fixture helper or default the node changed
   pass in the quick gate; CI passes on the PR. *D13-AC-2.*

## Gate
- **D13-AC-1** — The PR records, for each check the Purpose lists that failed in the CI runs Change 1 names (from their logs, or the review's excerpts where a log cannot be fetched) or in the loaded runs at the node's base (Change 1's load, up to ten runs at one CPU-bound process per CPU and ten more at two), the failing `FAIL:` line and the cause: what the case waited on or set up and how the load broke it, with D05's loaded tick length, M02's give-up waits and G06-AC-2's two-step setup checked first. If the loaded runs show no failure of those checks, it records the twenty runs, and the node makes Change 2's changes for the causes the CI logs show and for the give-up waits and the bounds Change 1 names. *Verify:* the recorded runs, the saved CI logs (or the record that they could not be fetched) and the diagnosis table in the PR, checked by the fresh reviewer.
- **D13-AC-2** — At the node's head, ten consecutive runs of the four files under Change 4's load pass with no `FAIL:` line, and each of the four files stays under `TEST_FILE_BUDGET` in an unloaded run and in CI; every test file that sources a fixture helper or default the node changed passes; CI passes on the PR. *Verify:* the ten recorded runs (their `FAIL:` count and the four files' `TIME` lines), the unloaded run's and CI's `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D13-AC-3** — The node changes the tests only as Changes 2 and 3 allow: every `PASS:` line of the four files, and of each file that sources a fixture helper or default the node changed, in a base run in which those files passed is the same `PASS:` line at the head; the checks that print only on failure (`loop-s01.test.sh` lines 40 and 43, `loop-g01-lim.test.sh` line 25) are unchanged but for their waits; no expected value, pattern, expected order, count or event text changes; a replaced bound checks the check's own words at least as strictly; no file outside **Owns** changes; each fixed sleep or wall-clock bound left in the waits the node touched has a comment saying why no condition can be observed. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` (the print-only-on-failure checks read in the diff), recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- The load a test can survive is not unlimited: a runner far busier than Change 1's load can still stretch a tick
  past a bound. The recorded runs say what load was shown; the CI `TIME` lines of the runs in Change 1 and of a
  passing run differ up to about 1.8× for the same file (`loop-s01.test.sh`: 29.14–41.75 s in the failing runs).
- Running only the four files beside CPU-bound processes may not reproduce failures seen in a whole loaded
  `make test`; the CI logs and the whole-suite runs Change 1 allows cover that.
- Other loop test files run their loops at `SCHED_TICK=1` with bounds in seconds too; they are not in this node's
  **Owns**, and an issue naming them gets a node of its own, as this one did.
- A cause in the scheduler itself rather than in a test's wait or setup (the loop missing a start, say) is not this
  node's to fix: it is recorded with its evidence and put to the owner as a question.
- Longer ticks or more waited ticks make the files slower; under load the files already took more than 30 s in CI
  (whose budget is 60 s), so the budget is held in an unloaded run and in CI, and the loaded times are recorded.
- A wait for a condition with a long timeout turns a broken loop into a failure at the timeout, so a failing run takes
  longer than a passing one.
