# M02 — locks-flake

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | M01 | none | S |

**Owns:** the checks of `scheduler/loops*.test.sh` that go through `/proc/locks` (M01-AC-3's status check among them)
and, where the diagnosis finds the cause in a probe, `held()` in `scheduler/loops.sh`; the record of the diagnosis,
in the node's PR.
**Resolves:** #139

## Purpose
After this node the loops tests no longer fail intermittently on a lock check. M01-AC-3's check of `loops.sh status`
reads a loop's lock through `/proc/locks` and has failed in CI now and then, with every other test passing. The cause
is not known yet: this node finds the failing runs, records why each failed, and makes the checks wait for the
condition they test, so a CI run fails on them only when the behaviour is wrong.

## Tests
- `scheduler/loops*.test.sh` (changed only as the diagnosis shows, with cases added, none loosened): each check that
  failed waits for the condition it tests (the lock taken, the loop's line printed) instead of a window of time.

## Changes
1. **Diagnosis.** Find the CI runs on `main` and on PRs where a `scheduler/loops*.test.sh` lock check failed (the
   forge's CI history), and record for each the run URL, the failing line and the cause (a lock not yet taken when the
   probe ran, the fdinfo fallback of D06, the runner's load, or what the logs show). Where no failing run can still be
   found, run the loops test files in CI and locally under load until 20 recorded runs pass or one fails. *M02-AC-1.*
2. **The fix** follows the cause: a check that raced its condition waits for it (with the shared helpers of
   `scheduler/testdata/lib/`); a probe that misread a held lock is fixed in `held()`, with a case. No check is loosened
   and none is removed. *M02-AC-2.*

## Gate
- **M02-AC-1** — The PR records each failing run found (URL, failing line, cause) and the cause the fix addresses; or, if no failing run is found and 20 recorded runs of the loops test files pass, that record, and the item is closed as not reproduced. *Verify:* the record in the PR.
- **M02-AC-2** — The loops test files pass in 10 consecutive recorded CI runs of the node's branch, with no check loosened or removed, and each changed check waits for the condition it tests. *Verify:* the recorded CI runs and the reviewer's diff check of `scheduler/loops*.test.sh`.

## Risks
- A failure that does not repeat in the runs recorded may still come back; the record says what was looked at.
- Changing `held()` touches every lock probe of `loops.sh` (start, stop, status); the existing D06 and M01 cases cover
  them.
- The loops tests are frozen; this node adds waits and cases, and a change to an existing line is an approved
  frozen-test change.
