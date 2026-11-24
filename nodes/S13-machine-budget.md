# S13 — machine-budget

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S07 | none | S |

**Owns:** in `scheduler/turn.py`: the machine budget (`SCHED_MACHINE_MAX`) of `ask` and `took`, the count of running sessions under the runtime root, and its lines in the docstring; in `scheduler/loop.sh`: the status-log line for a start the machine budget holds (a turn and a released node), and its line in the header comment; `scheduler/turn-budget.test.sh` (new), `scheduler/loop-s13.test.sh` (new), `scheduler/loop-s13-again.test.sh` (new), their lines in the `Makefile`'s `TESTS`.
**Resolves:** #218

## Purpose
After this node the owner can cap the sessions running at once on the whole machine, not only per repository. With `SCHED_MACHINE_MAX=N`, `turn.py` gives no start turn while N sessions already run across every loop under the runtime root, so four loops on a small machine no longer run four or more sessions together. The unit first in line keeps its place and starts once a session ends, whatever loop it belongs to. Unset or 0, nothing changes.

## Tests
- `scheduler/turn-budget.test.sh` (new), with a scratch runtime root holding several repositories' state folders, live and dead `session.pid` files (a live one names a scratch process whose command line has `run-session.sh`), shows:
  - with `SCHED_MACHINE_MAX=2` and two live sessions in two repositories, `ask` prints nothing and records no start, and exits 0; with one of them gone, the next `ask` grants the turn to the first unit of the merged order;
  - a `session.pid` of a dead process, or of a process that is not a session, is not counted;
  - `took` with the budget full refuses (a distinct exit code and a message) and records nothing;
  - concurrent `ask` from two loops with `SCHED_MACHINE_MAX=1` and no session running grant one turn, and a second `ask` right after the grant, before the granted session's `session.pid` exists, grants none (a granted start counts as running until its session's pid file appears or the gap has passed);
  - with `SCHED_MACHINE_MAX=N` and N live sessions, one of them in the state folder of a `resumed` unit first in the order (a session idle at the usage limit), `ask` grants that unit its turn; with N live sessions and a different, new unit first in the order, `ask` grants nothing;
  - unset or `0`: `ask` and `took` behave as before.
- `scheduler/loop-s13.test.sh` (new), two loops under one runtime root with `SCHED_RAMP=1`, `SCHED_MACHINE_MAX=1` and slow fake sessions, scratch paths under a folder named `S13`: never more than one session runs across both loops (sampled from the `session.pid` files while they run); when the session ends, the first unit of the order starts, whichever loop holds it; the loop whose start was held writes one status-log line per hold naming the machine budget ("N of N sessions running on the machine"); a released node is held the same way and starts once a session ends.
- Every existing `scheduler/turn*.test.sh` and `scheduler/loop-s07*.test.sh` passes unchanged.

## Changes
1. **The count.** `turn.py` counts the running sessions under `DATA/state/*/`: each `node/*`, `issue/*`, `pr/*` and `adopt/*` folder whose `session.pid` names a live process whose command line has `run-session.sh` (the check the loop uses), plus starts granted within the gap whose session has not written its pid yet. Pickup runs are not sessions and are not counted. *S13-AC-1.*
2. **The cap.** With `SCHED_MACHINE_MAX` above 0, `ask` grants no turn while the count reaches it (the order and the waits are unchanged, so the first unit keeps its place), and `took` refuses, so a released node waits as it does for `SCHED_MAX`. The count is taken under the same lock as the start record. One start is not held: a `resumed` unit (a session idle at the usage limit, which its turn stops and starts again) whose own state folder holds a live session does not count that session against its own turn, since its turn replaces that session and the number running stays at N. Only the unit's own session is excused, and only for its own resume; every other start is held as above, a new unit's among them while N sessions sit idle at the limit. *S13-AC-1, S13-AC-2.*
3. **The line.** `loop.sh` writes one status-log line when the machine budget first holds a start of its, and not again until a start of its goes through. *S13-AC-2.*
4. `loops.sh start` already passes `SCHED_MACHINE_MAX` (a `SCHED_*` setting) to every loop. With `SCHED_RAMP=0` the start queue is off and so is the budget; `loop.sh` says so once at its start when both are set.

## Gate
- **S13-AC-1** — With `SCHED_MACHINE_MAX=N` (N > 0), `turn.py ask` grants no turn while N sessions run under the runtime root (live `session.pid` processes of `run-session.sh` across every repository, and turns granted whose session has not started yet), and grants the first unit of the order its turn once one ends; a `resumed` unit whose own state folder holds one of the N live sessions is not held, since its turn replaces that session, while any other unit still is; concurrent asks never take the count above N; dead pid files and non-session processes are not counted; unset or 0 changes nothing. *Verify:* `scheduler/turn-budget.test.sh`.
- **S13-AC-2** — Two loops under one runtime root with `SCHED_MACHINE_MAX=1` never run two sessions at once; the held unit starts once the running session ends, whichever loop it belongs to; a released node waits the same way; each hold is one status-log line naming the machine budget. *Verify:* `scheduler/loop-s13.test.sh` and `scheduler/loop-s13-again.test.sh`.
- **S13-AC-3** — Every existing `scheduler/turn*.test.sh` and `scheduler/loop-s07*.test.sh` passes unchanged. *Verify:* those tests in `make test`.

## Risks
- Each loop reads `SCHED_MACHINE_MAX` from its own environment; loops started with different values each apply their own. `loops.sh start` passes one value to all.
- A session left running by a stopped loop still counts, as it should: it still uses the machine.
- The default is no machine cap; the owner sets it (for this machine, 2 with S12's ceilings of half the RAM each).
