# D05 — s07-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S07, D03 | none | M |

**Owns:** in the start-queue test files `scheduler/loop-s07*.test.sh` and their fixture `scheduler/testdata/lib/loop-s07.sh`: how each case waits, the settings a case starts its loops with (ticks, `SCHED_START_GAP`, `SCHED_STARVE`, seeded waits) and when it opens or holds the throttle, the time windows its checks use, and the fixture's helpers; never what a check expects (Change 3).
**Resolves:** #92

## Purpose
After this node the start-queue tests pass on a loaded machine under the runner's parallelism, so they no longer fail `make test` (and with it a self-deploy) for reasons of timing alone. Today several of their checks depend on wall-clock windows: two loops' ticks lining up before the first turn, a start "within 2.6 s" of the throttle opening, a gap that must not have passed yet. Under four running sessions and `TEST_JOBS` at twice the CPUs, those windows were missed on a commit that changed no code. The node finds out from recorded runs why each check fails under load, then makes the cases wait for the turns, ticks and status-log lines they check, without loosening any check.

## Tests
- The existing `scheduler/loop-s07*.test.sh` files, changed only as Change 3 allows: every `PASS:` line of the base is a `PASS:` line at the head, but for the two gaps Change 3 names.
- The recorded runs in the PR (Change 1 and 4): `make test` on the scheduler's machine while it is loaded, at the node's base and at its head.

## Changes
1. **Diagnose under load.** On the scheduler's machine, with one CPU-bound process per CPU running beside it (for example `yes >/dev/null`, one per `nproc`) and `TEST_JOBS` at its default, run `make test` at the node's base until the S07 files fail, up to ten runs. For each check that fails, the PR records the failing run's `FAIL:` line and what the case waited on that the load broke (which window, which tick or turn it assumed). The checks seen failing on 2026-11-11 are the starting list:
   - `loop-s07-resume.test.sh`, S07-AC-6: "while the gap has not passed the idle session is not resumed", "… is not stopped", and "the idle session was resumed in its own process";
   - `loop-s07-starve.test.sh`, S07-AC-2: "an M node past SCHED_STARVE starts before the triage and the S node";
   - `loop-s07-units.test.sh`, S07-AC-2 and S07-AC-5: the start order, and "B01's event names A04";
   - `loop-s07-records.test.sh`, S07-AC-1: "the next unit (the S node) starts at the first turn after the throttle opens, within 2.6 s".
   *D05-AC-1.*
2. **Wait for the condition, not the clock.** Each case waits until the state its next check reads holds: every unit that is to compete has its `waiting` record in every loop before the throttle opens or the first turn is taken; a check that the first turn after the throttle opens starts the unit reads the start record and the status logs (no start between the opening and that unit's) instead of a time window; a check that something did not happen while the gap has not passed waits for the loop's ticks to have visibly passed (D03's rule) within a gap long enough that those ticks fit in it under load. Settings may change for this (a longer `SCHED_START_GAP`, say), and the file must stay under `TEST_FILE_BUDGET`. A fixed sleep or a wall-clock window stays only where no condition can be observed, with a comment saying why. *D05-AC-2, D05-AC-3.*
3. **No check loosened.** No expected value, pattern, order, count or event text a check compares against changes. A time bound a check states may change only together with the setting it derives from and stays at least as tight relative to it (a "starts at least the gap apart" check stays at the same fraction of the gap). A window that only approximates a criterion's own words, such as "within 2.6 s" for "at the first turn after the throttle opens", may be replaced by a check of those words that is at least as strict. A `PASS:` line that names a setting this node changes may change that number only, together with the setting, with its bound at the same fraction of the setting or tighter; no other word of the line changes. Two lines do: `loop-s07-resume.test.sh` R1, gap 4 s → 8 s ("a gap (4 s)" → "a gap (8 s)", `qgap_n 3 3.6` → `qgap_n 3 7.2`), and `loop-s07-failed.test.sh` F, gap 1 s → 4 s ("by the gap (1 s)" → "by the gap (4 s)", `qgap_n 2 0.6` → `qgap_n 2 3.6`). *D05-AC-3.*
4. **Show it holds.** At the head, the same loaded runs pass. *D05-AC-2.*

## Gate
- **D05-AC-1** — The PR records, for each S07 check that failed in loaded `make test` runs at the node's base (Change 1's load, up to ten runs), the failing `FAIL:` line and the cause: what the case waited on and how the load broke it. Or, if ten loaded runs at the base show no S07 failure, it records those ten runs, and the node makes only Change 2's waits, for the checks listed in Change 1. *Verify:* the recorded runs and the diagnosis table in the PR, checked by the fresh reviewer.
- **D05-AC-2** — At the node's head, five consecutive `make test` runs on the scheduler's machine under Change 1's load pass with no `FAIL:` line from a `loop-s07*.test.sh` file, and every file stays under `TEST_FILE_BUDGET`; CI passes on the PR. *Verify:* the five recorded runs (their `FAIL:` count and the S07 files' `TIME` lines) and the CI run URL, in the PR.
- **D05-AC-3** — The node changes the start-queue tests only as Changes 2 and 3 allow: every `PASS:` line of the S07 files at the base is a `PASS:` line at the head (except that the two lines Change 3 names carry their new gap, R1 "(8 s)" and F "(4 s)", with their bounds `qgap_n 3 7.2` and `qgap_n 2 3.6`), no expected value, pattern, order, count or event text is changed, every changed time bound is tied to its setting and at least as tight relative to it, every replaced window checks the criterion's own words at least as strictly, no file outside **Owns** changes, and each fixed sleep or window left in `loop-s07*.test.sh` and `testdata/lib/loop-s07.sh` has a comment saying why no condition can be observed. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD`, recorded in the PR with the sorted `PASS:` lines of both runs and their diff.

## Risks
- The load a test can survive is not unlimited: a machine far busier than one CPU-bound process per CPU can still stretch a tick past a gap. The recorded runs say what load was shown.
- Longer gaps or more ticks make the S07 files slower; D03's per-file budget still applies, and a file near it may need to be split as D03 allows.
- A wait for a condition with a long timeout turns a broken loop into a failure at the timeout, so a failing run takes longer than a passing one.
- Other loop test files (`loop-p03-ramp.test.sh`, say) may have the same kind of window; they are not in this node's **Owns**, and the self-deploy's rerun of failed files (D04) keeps such a flake from refusing a commit until an issue names them.
