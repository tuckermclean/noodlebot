# D22 — s07-turnpy-waits

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D05, D17 | none | S |

**Owns:** in the end-to-end loop test `scheduler/loop-s07-turnpy.test.sh`: how each case waits, the order of and the
waits between its setup steps, the settings its loops start with (`SCHED_TICK`, `SCHED_START_GAP` and the like) and the
time bounds its waits use; in the fixture it sources (`scheduler/testdata/lib/loop-s07.sh`) and in
`scheduler/testdata/lib/loop-prelude.sh`: new helpers, and an existing helper or default setting only where Change 1
names it as a cause (Change 2); `scheduler/testdata/lib/loop-fakes.sh` stays unchanged (a new helper goes in
`loop-s07.sh` or `loop-prelude.sh`); the record of the diagnosis and of the runs, in the node's PR and under
`out/node/D22/`. As D05, D13, D17 and D20 did for theirs, this spec allows changing these frozen test lines' waits,
setup order and settings, never what a check expects (Change 3), and the PR lists each changed frozen line for the
owner's approval.
**Resolves:** #254

## Purpose
After this node S07-AC-7's check "turn.py working again: the waiting unit starts" in `loop-s07-turnpy.test.sh` (line
22 at this spec's base, read after line 21's `qwait 8 qhave A03`) passes on a loaded runner. It failed in CI on timing
alone on spec-only PR #242, which touches no test file, and was the file's only failure. Its wait is a bound in
seconds around a loop that ticks every two seconds (`qloop qa 2`), and `qwait <n>` waits `3 × n` seconds (the
fixture's line 105), so line 21 gives up after 24 s. The file's other waits are bounds in seconds too, and some give up
and let the case go on, so the node checks them all. It finds out from the CI log and recorded loaded runs why each
one fails or can fail, then makes the cases wait for the ticks, turns and starts they check, a bound that stands for
the loop's ticks counted in ticks with a ceiling, without loosening any check.

## Tests
- `scheduler/loop-s07-turnpy.test.sh`, changed only as Change 3 allows: every `PASS:` line of the base is a `PASS:`
  line at the head, word for word.
- Every other test file that sources a fixture helper or default the node changes (the `loop-s07*` files and
  `loop-p03-ramp` for `loop-s07.sh`, and, for a change to `loop-prelude.sh`, every `scheduler/loop*.test.sh`) passes
  with the same `PASS:` lines.
- The recorded runs in the PR (Changes 1 and 4), at the node's base and at its head.

## Changes
1. **Diagnose from the CI log, then under load.** First the CI log of the run named in the issue: job 138901393476 of
   run 45523619813, PR #242's CI, head `29b43ff`, 2026-11-25. It can be fetched with the forge CLI's `ci logs --run
   45523619813` (G08) and is saved under `out/node/D22/` (CI logs expire); a log the session cannot fetch is recorded
   as such, and the PR uses the excerpts this Change quotes in its place. What it shows: `TIME 56.91
   scheduler/loop-s07-turnpy.test.sh` (23.96 s in the green run 45512562908 on the previous head, `393acde`; the
   failing run's `TOTAL` was 560.43 against 334.11, a slow runner); the three checks of lines 17–19 passed; `FAIL:
   S07-AC-7: turn.py working again: the waiting unit starts` with `starts: A02`, so A03 had not started when line
   22 read the starts; Phase L1's three checks passed. The test prints no status log on that failure, so the log does
   not say how many of qa's ticks passed or whether qa asked for a turn.

   Then, on the scheduler's machine, with the load kept to half its CPUs (at least one) so that other sessions keep
   the rest, each run under one `taskset -c <those CPUs>`, each load process bounded so that it cannot outlive its run
   (for example `timeout 900 yes >/dev/null`, killed when the run ends). At the node's base, until the check of
   line 22 or another check of the file fails: up to ten runs of `make test TESTS=scheduler/loop-s07-turnpy.test.sh`
   beside one CPU-bound process per pinned CPU; if none fails, up to ten runs of `make test` of the `loop-s07*` files
   with `TEST_JOBS` at twice the number of pinned CPUs beside one CPU-bound process per pinned CPU. Each run's log goes
   under `out/node/D22/`. For each check of `loop-s07-turnpy.test.sh` that fails, the PR records the failing run's
   `FAIL:` line and what the case waited on that the load broke (which bound, which tick, turn or start it assumed),
   from qa's status log, its heartbeat and `turn.py`'s records in that run (a run may log more, in a scratch copy
   only). The read checks first the causes found before:
   - D05's liveness: `turn.py` counts a loop live only while its heartbeat is less than three of its ticks old, so a
     loop asking alone at `SCHED_TICK=2` gets a turn only while its tick's work takes under about 5 s (the fixture's
     comment, lines 15–22); under load a tick at `SCHED_TICK=1` took 4.7–7.4 s on average and up to 11.4 s (D05's PR
     #118). A loop that ticks but is stale whenever it asks gets no turn however many ticks the wait counts, so the PR
     records, from swapping the real `turn.py` back (line 20) to the give-up or A03's start, how many of qa's ticks
     started, how many asked for a turn and what `turn.py` answered each time;
   - the bound itself: line 21's 24 s against those ticks, and whether A03 started after the check had read the
     starts (a start in `starts.log` or the status log later than the `FAIL:` line);
   - what the failing turn left behind: the waiting records and the start record after the ticks in which the fake
     `turn.py` failed, and whether the first turn after line 20 waits for something they hold (the gap, say);
   - M02's, D13's, D17's and D20's: the give-up waits (the unchecked `qwait 8 qhave A02` of line 14, `qticks 4` of
     line 16, `qwait 8 qa_listless` of line 35 and `qwait 12 qhave B01; wait_until 5 qev_ge 1` of line 37, each of
     which gives up after its bound and lets the case go on, so a slow earlier step can move into the next check's
     bound) and a bound in seconds that stands for a number of ticks.

   The PR's diagnosis table has a row for every `qwait`, `qticks` and `wait_until` of the file (lines 14, 16, 21, 35
   and 37 at this spec's base): what it waits on, whether it is a check or a setup step, whether it fails or gives up
   at its bound, and whether the loaded runs or the reading above show the load can break it. *D22-AC-1.*
2. **Wait for the condition, not the clock.** Each case waits until the state its next check reads holds: a start the
   check counts is waited for through `starts.log`, the status log or `turn.py`'s records; a wait that stands for a
   number of the loop's ticks counts those ticks (through qa's heartbeat, as `qticks` and `wait_ticks` do, or D20's
   `g02_tickwait` in node PR #252 shows) and fails when that many ticks have passed or, as its ceiling, when the
   heartbeat has not changed for a bound that the PR records with its reason; a wait that gives up and goes on becomes
   a wait that fails a check naming its condition when it times out; a "did not happen" check waits for the loop's
   ticks to have visibly passed (D03's rule); a phase's loop may run with a longer `SCHED_TICK` (or another setting)
   where Change 1 names it as the cause, as D05 did for liveness. A wait's timeout may grow only where the check's
   words state no time and Change 1 records why the old one ran out. An existing helper or default in a shared fixture
   changes only where Change 1 names it as a cause, and then every test file that sources it keeps its `PASS:` lines;
   a new helper in `loop-prelude.sh` changes no existing one. A fixed sleep or a wall-clock bound stays only where no
   condition can be observed, with a comment saying why. The file stays under `TEST_FILE_BUDGET` in an unloaded run
   (30 s; 16.06 s at this spec's base on the scheduler's machine) and in CI (`test.yml`'s `TEST_FILE_BUDGET`, 105 s at
   this spec's base; 56.91 s in the failing job); the unloaded run's `TIME` lines are recorded at the base and at the
   head, and the loaded runs of Change 4 record theirs. *D22-AC-2, D22-AC-3.*
3. **No check loosened.** No expected value, pattern, order, count, event text or check name changes; "order" here is
   the order a check expects (of starts, events or lines), not the order of a case's setup steps. The check of line 22
   still requires the starts to be exactly `A02 A03` after the real `turn.py` is back, and the checks of lines 17–19
   still read the starts, the status log and A02's session after the loop's ticks with the failing `turn.py` have
   visibly passed, at least as many as `qticks 4`. *D22-AC-3.*
4. **Show it holds.** At the head, ten consecutive runs under the heaviest load shape at which Change 1 saw a failure
   of the file (the `loop-s07*` files at twice the pinned CPUs when none was seen) show no `FAIL:` line of
   `loop-s07-turnpy.test.sh`, each run's log under `out/node/D22/` and its `TIME` line for `loop-s07-turnpy.test.sh` in
   the PR; `FAIL:` lines of other files in a multi-file run are recorded, not counted (they are not this node's); the
   files that source a fixture helper or default the node changed pass in the quick gate; CI passes on the PR.
   *D22-AC-2.*
5. **Ask for the frozen lines.** The PR lists every frozen test or fixture line the node changes (file, line at the
   base, the line before and after, and the Change 1 cause it answers) and asks the owner to approve them, as U05's
   frozen-line record of the final review names them. *D22-AC-3.*

## Gate
- **D22-AC-1** — The PR records, for the check of line 22 in the CI job Change 1 names (from its log, or Change 1's excerpts where the log cannot be fetched), and for each check of `loop-s07-turnpy.test.sh` that failed in the loaded runs at the node's base (Change 1's two load shapes, up to ten runs each), the failing `FAIL:` line and the cause: what the case waited on or counted and how the load broke it, with qa's ticks, turn requests and `turn.py`'s answers from line 20 to A03's start or the give-up, D05's liveness rule, line 21's 24 s bound, what the failing `turn.py` left behind and the give-up waits checked first; and a diagnosis table with a row for every `qwait`, `qticks` and `wait_until` of the file (lines 14, 16, 21, 35 and 37 at this spec's base). If the loaded runs show no failure, it records the twenty runs, and the node makes Change 2's changes for line 21's wait (counted in qa's ticks with a ceiling) and for the give-up waits and the bounds the table names. *Verify:* the recorded runs, the saved CI log (or the record that it could not be fetched) and the diagnosis table in the PR, checked by the fresh reviewer.
- **D22-AC-2** — At the node's head, ten consecutive runs under Change 4's load show no `FAIL:` line of `loop-s07-turnpy.test.sh`, and the file stays under `TEST_FILE_BUDGET` in an unloaded run (30 s) and in CI (`test.yml`'s `TEST_FILE_BUDGET`, 105 s at this spec's base); every test file that sources a fixture helper or default the node changed passes; CI passes on the PR. *Verify:* the ten recorded runs (the file's `FAIL:` count and `TIME` lines), the unloaded run's and CI's `TIME` lines, the quick gate's output and the CI run URL, in the PR.
- **D22-AC-3** — The node changes the tests only as Changes 2 and 3 allow: every `PASS:` line of `loop-s07-turnpy.test.sh`, and of each file that sources a fixture helper or default the node changed, in a base run in which those files passed is the same `PASS:` line at the head; no expected value, pattern, expected order, count or event text changes; line 22's check still requires the starts `A02 A03` once the real `turn.py` is back; no file outside **Owns** changes; each fixed sleep or wall-clock bound left in the waits the node touched has a comment saying why no condition can be observed; the PR lists each changed frozen line (file, base line, before and after, cause) for the owner's approval. *Verify:* the fresh reviewer's check of `git diff <base>..HEAD` against the PR's list of changed frozen lines, recorded in the PR with the sorted `PASS:` lines of a passing base run and a head run and their diff.

## Risks
- The load a test can survive is not unlimited: a runner far busier than Change 1's load can still stretch a tick
  past a bound counted in ticks, or leave a loop stale whenever it asks. The recorded runs say what load was shown.
- Running the file alone or among the `loop-s07*` files may not reproduce a failure seen in a whole loaded `make
  test`; the CI excerpts Change 1 quotes cover that.
- `loop-s07.sh` is the fixture of every `loop-s07*` file and of `loop-p03-ramp`, so a setting or helper changed in it
  reaches the others; a change for this file is made in this file, or every file that sources it keeps its `PASS:`
  lines (Change 2).
- D20 (node PR #252) adds `g02_tickwait` to `loop-g02.sh`, which this file does not source; this node does not
  depend on D20 and writes its own tick-counted wait, so the two helpers may look alike until a later node merges them.
- A cause in the scheduler itself rather than in a test's wait, setup or count (`loop.sh` or `turn.py` not granting a
  turn for some interval after `turn.py` fails, or the liveness rule refusing a loop that ticks, say) is not this
  node's to fix: it is recorded with its evidence and put to the owner as a question.
- CI on a PR also enforces the total (`test.yml`'s `TEST_BUDGET`, 630 s at this spec's base), which slow runners
  exceed with no test change; the failing run of the issue also had `FAIL:` lines in two other files. A CI run that
  fails only on other files' `SLOW` lines, the total, or another file's timing failure that this node does not touch
  is rerun, both run URLs recorded; if the reruns keep failing only on those, the node records them and puts it to the
  owner as a question.
- A wait for a condition with a long timeout turns a broken loop into a failure at the timeout, so a failing run takes
  longer than a passing one.
