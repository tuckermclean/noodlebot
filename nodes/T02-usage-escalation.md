# T02 — usage-escalation

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | T01 | none | M |

**Owns:** the escalation verdict (`--escalate`) in `scheduler/usage.py`, the escalation step (pausing running sessions and resuming them) in `scheduler/loop.sh`, their cases in `scheduler/usage.test.sh` and `scheduler/loop.test.sh`.
**Resolves:** #11

## Purpose
After this node the scheduler has a second step for when holding new sessions (T01's throttle) is not enough. While the throttle holds and the 5-hour window, at the last 30 minutes' burn rate, is still projected to reach 100% well before its reset, the loop pauses running sessions: it stops them one per tick, the newest first across every repository on the machine, until the projection no longer escalates. A paused session's committed work stays on its branch in its kept worktree and its start is given back; the task starts again once the throttle opens. Each pause and each resume is one status-log event, so it reaches the status issue.

## Tests
- `scheduler/usage.test.sh` (extended): the `--escalate` verdict for a 5-hour window projected to reach 100% more than the margin before its reset, less than the margin before it, after the burn slows, after a reset, with no readings, with `USAGE_ESCALATE_MARGIN` set, and for a 7-day window ahead of pace alone (no escalation).
- `scheduler/loop.test.sh` (extended): fake `claude` sessions that run until stopped and start a child of their own, and that commit in their worktree first; a second repository's state directory under the same state root with a live session of its own. Cases: escalation stops this repository's newest session (whole process group) and gives its start back; one session per tick; a newer session in the other repository is left to that repository's loop and blocks this loop's stop for the tick; a paused node and a paused triage start again once the throttle opens, with no start used; the committed work is still on the branch; `SCHED_ESCALATE=0`; no escalation while the throttle is off or open.

## Changes
1. **`usage.py --state-root DIR --escalate`** prints `escalate: <reason>` when the 5-hour window, at the last 30 minutes' burn rate (as T01 projects it), reaches 100% at least `USAGE_ESCALATE_MARGIN` minutes (default 30) before its reset, and `no escalation: <summary>` otherwise. The 7-day window never escalates. Its output without `--escalate` stays as it is. *T02-AC-1.*
2. **The loop picks the session to pause.** While the throttle holds and `usage.py --escalate` says escalate, the loop orders every live session under the shared state root (each repository's `node/*/session.pid` and `issue/*/session.pid` whose process is alive, nodes and triages alike) by the pid file's modification time, newest first. If the first is one of its own, it pauses it; if it belongs to another repository, it pauses nothing this tick (that repository's loop does). At most one session per loop per tick; the next tick checks again. *T02-AC-2, T02-AC-3.*
3. **Pausing stops the session.** SIGTERM to its process group, SIGKILL after a short grace if anything remains; the tick waits until the group is gone. The loop records the pause in the task's state, so the end-of-session path gives the start back (as for a limit exit) instead of counting it, and writes one status-log event naming the task and the reason. The worktree, its branch and its commits stay. *T02-AC-2, T02-AC-4.*
4. **Resuming.** A paused task is not started while the throttle holds. Once it opens, the task starts as usual, without a start used, and the start is one status-log event that names it as a resume of the paused task; the pause record is then cleared. *T02-AC-4.*
5. **A switch.** `SCHED_ESCALATE=0` turns escalation off; with the throttle off (`SCHED_THROTTLE=0`) there is no escalation either. *T02-AC-5.*

## Gate
- **T02-AC-1** — `usage.py --escalate` says escalate exactly when the 5-hour window is projected at the last 30 minutes' burn rate to reach 100% at least `USAGE_ESCALATE_MARGIN` (default 30 minutes) before its reset; it does not for a projection within the margin, after the burn slows, after a reset, with no readings, or for a 7-day window ahead of pace alone; without `--escalate` its output is unchanged. *Verify:* `scheduler/usage.test.sh`.
- **T02-AC-2** — While the throttle holds and escalation is called for, and the newest live session under the shared state root is one of the loop's own (node or triage), the loop stops it and every process in its process group, and only one session per tick; one status-log event names the task and the reason; the next tick, if escalation is still called for, stops the next newest, and once it is not, stops none. *Verify:* `scheduler/loop.test.sh`.
- **T02-AC-3** — When the newest live session under the shared state root belongs to another repository, the loop stops none of its own sessions that tick. *Verify:* `scheduler/loop.test.sh`.
- **T02-AC-4** — A paused task uses up no start; its worktree, branch and commits remain; it does not start while the throttle holds, and starts at the first tick after the throttle opens, with the same start count it had before it was paused, and one status-log event names it as resumed. *Verify:* `scheduler/loop.test.sh`.
- **T02-AC-5** — With `SCHED_ESCALATE=0`, or with the throttle off or open, no running session is stopped for usage. *Verify:* `scheduler/loop.test.sh`.

## Risks
- A paused session loses its uncommitted edits and its conversation: the next session starts afresh (`run-session.sh` resumes nothing), though uncommitted changes stay in the kept worktree for it to see.
- Processes a session started outside its process group (a podman container, for instance) are not stopped with it (unverified for real sessions).
- The order relies on the pid files' modification times and on every loop sharing one state root; a pid file touched after its session started would reorder it. A loop that is not running leaves its sessions running, and while one of them is the newest, no other loop pauses anything.
- Burn rate comes only from running sessions' readings; once enough are paused, the projection slows and escalation stops, but the last reading may lag a tick behind.
- S01 also stops a session's process group; whichever of the two is built second reuses the other's stop rather than adding a second one.
