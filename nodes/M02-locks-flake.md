# M02 — locks-flake

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | M01, D06, D12 | none | S |

**Owns:** the checks of `scheduler/loops*.test.sh` that go through `/proc/locks` (M01-AC-3's status check among them)
and their waits; `scheduler/testdata/lib/loops-body.sh`, which the five `loops*` tests that share it
(`loops.test.sh`, `loops-root.test.sh`, `loops-status.test.sh`, `loops-api.test.sh`, `loops-s08.test.sh`) source: its
checks (M01-AC-3's status checks among them), `start_loop`, `start_session` and the other waits; where the read finds
the cause in a probe, `held()` in `scheduler/loops.sh`; the record of the read and of the runs, in the node's PR and
under `out/node/M02/`. As D03 (its change 7) and D05 do for theirs, this spec allows changing the waits in `start_loop`
(`loops-body.sh:73`) and `start_session` (`:80`) and the waits before a check the read lists, never what a check
expects.
**Resolves:** #139, #151

## Purpose
After this node the loops tests no longer fail intermittently on a lock check. M01-AC-3's check of `loops.sh status`
reads a loop's lock through `/proc/locks` and has failed in CI now and then, with every other test passing. The checks
and the waits that probably race are in `scheduler/testdata/lib/loops-body.sh`: `start_loop` gives up after 50 × 0.1 s
and lets the test go on whether or not the loop's lock is taken; `start_session` sleeps a fixed 0.3 s; and M01-AC-3's
status checks run right after both. This node reads every check that depends on `/proc/locks` with the wait before it,
names each race, and makes each such check wait for the condition it tests, so a run fails on them only when the
behaviour is wrong. The probe the checks go through, `held()` with its fdinfo fallback, and its test
`loops-pidns.test.sh` are D06's.

## Tests
- `scheduler/loops*.test.sh` and `scheduler/testdata/lib/loops-body.sh` (changed only as the read shows, with cases
  added, none loosened): each check the read names waits for the condition it tests (the lock taken, the session
  started, the loop's line printed) instead of a fixed time or a wait that gives up and goes on; a wait that times out
  fails its check with a message naming the condition. Replacing such a wait (`start_loop`'s give-up loop,
  `start_session`'s `sleep 0.3`, the wait before a listed check) is allowed by this spec; what a check expects is not
  changed.

## Changes
1. **The read.** Every check in `scheduler/loops*.test.sh` and `scheduler/testdata/lib/loops-body.sh` whose result
   depends on `/proc/locks` (through `running()`, `held()` in `loops.sh`, or `loops.sh start`, `status` and `stop`) is
   listed with the wait before it, and each race is named: the condition the check needs, the wait that can end before
   it holds, and the file and line of both. Known so far: `start_loop`'s 50 × 0.1 s wait (line 73) goes on when it
   runs out; `start_session`'s fixed `sleep 0.3` (line 80) does not wait for the session; M01-AC-3's status checks
   (lines 117–137, and the later M01-AC-3 cases, which run to line 419 with the dead-pid ones) run after both. A probe
   the read finds misreading a held lock (the `/proc/locks` read or D06's fdinfo fallback) is named the same way. The read is recorded in the PR. *M02-AC-1.*
2. **The fix** follows the read: each named race waits for its condition (a wait that fails its check when it times
   out, not one that goes on); a probe that misread a held lock is fixed in `held()`, with a case. No check is loosened
   and none is removed. *M02-AC-2.*
3. **The runs.** The loops test files run 20 times locally, bounded so the host is not loaded:
   `TEST_JOBS=2 make test TESTS="<the loops*.test.sh files>"` one run after another, each run's log under
   `out/node/M02/`, all passing; and the PR's normal CI run passes. `out/` is ignored by Git, so the PR also holds a
   summary of the 20 runs: for each run, pass or fail and its `FAIL` count. *M02-AC-2.*

## Gate
- **M02-AC-1** — The PR records a read of every check in `scheduler/loops*.test.sh` and `scheduler/testdata/lib/loops-body.sh` whose result depends on `/proc/locks`, each with the wait before it, and names each race (the condition, the wait that can end before it holds, file and line), at least `start_loop`'s give-up wait, `start_session`'s fixed sleep and the M01-AC-3 status checks after them; a check found without a race is listed as such. *Verify:* the record in the PR.
- **M02-AC-2** — Each race M02-AC-1 names waits for its condition, a wait that times out failing its check; with `TEST_JOBS=2`, 20 consecutive local runs of the `loops*.test.sh` files pass, their logs under `out/node/M02/` and summarised in the PR, and the PR's CI run passes; no check is loosened or removed. *Verify:* the PR's summary of the 20 runs (for each run, pass or fail and its `FAIL` count) with their logs under `out/node/M02/`, the PR's CI run, and the reviewer's diff check of `scheduler/loops*.test.sh` and `scheduler/testdata/lib/loops-body.sh`.

## Risks
- A race the read misses may still fail now and then; the record says what was read, so a later failure starts from it.
- The forge CLI cannot read a CI job's log and a passing CI run cannot be rerun, so the node relies on the local runs
  and the PR's one CI run, not on repeated CI runs.
- Changing `held()` touches every lock probe of `loops.sh` (start, stop, status); the existing D06 and M01 cases cover
  them.
- The loops tests and `loops-body.sh` are frozen; this node changes the waits named in **Owns** and adds cases, and a
  change to what an existing check expects is a frozen-test change the owner approves first.
