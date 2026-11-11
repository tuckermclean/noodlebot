# S07 — start-queue

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | T01, S06 | none | M |

**Owns:** `scheduler/turn.py`, `scheduler/turn.test.sh`, its line in the `Makefile`'s `test` target; in `scheduler/loop.sh`: the waiting records, the list of units waiting to start, the turn taken before each start (a node, follow-up, triage or update start, and S06's resume), the turn in the start's status-log event, the settings `SCHED_RAMP`, `SCHED_START_GAP` and `SCHED_STARVE` and their lines in the header comment; in `scheduler/loop.test.sh`: the `SCHED_RAMP=0` export that keeps the existing runs as they are, and the start-queue run.
**Resolves:** #55

## Purpose
After this node new sessions ease into the plan's usage instead of starting in a burst. Today each loop starts every ready unit in the same tick, and the throttle (T01) only sees the burn after it is spent, so all held units start at once at a reset. Now every loop on the machine shares one start record. It keeps at most one new session per minimum gap, across all repositories, so the throttle sees each session's burn before the next one adds to it. When units compete for that start, small ones (triages, spec-PR updates, follow-ups and resumed units) go before fresh nodes, and fresh nodes go by their spec's Size. Within each, the unit that has waited longest goes first. A unit that has waited past a starvation limit goes first whatever its size. Running sessions are untouched: this orders and spaces new starts only.

## Tests
- `scheduler/turn.test.sh` (new), on fixture state folders under a temporary `$NOODLEBOT_DATA`. Cases:
  - the order of the five kinds of unit: triage, update, follow-up, resumed node, and fresh S, M and L nodes, plus a fresh node whose spec has no Size;
  - ties broken by the time waited;
  - a unit past the starvation limit, and one just short of it;
  - two repositories' waiting lists merged into one order;
  - the gap, given and by default (the largest tick among the live loops);
  - a loop whose list is stale, which is left out;
  - a turn given back after a failed start;
  - a missing or malformed start record or waiting list;
  - two processes asking for a turn at the same moment.
- `scheduler/loop.test.sh` (extended):
  - One added line near the top, `export SCHED_RAMP=0`, keeps every existing run's behaviour (all ready units in one tick), so no existing line or assertion changes.
  - A start-queue run of its own sets `SCHED_RAMP=1`. It has its own fixture: two fake repositories under one `$NOODLEBOT_DATA`, each with its own loop. It uses the fake `claude` and a fake `usage.py` (copied into the run's `scheduler/`) whose answer the test sets.
  - Its five ready units across the two repositories are a labelled issue (a triage), an S node, an M node and two L nodes, with their Sizes in their specs' header rows. Its cases:
    - the throttle open, then the order and spacing of the starts;
    - an M node whose waiting record is older than the starvation limit;
    - the throttle holding from the second turn;
    - both loops reaching a turn at the same moment;
    - a unit whose start fails;
    - `SCHED_MAX`;
    - a second labelled issue while a triage runs;
    - an S06 resume competing with a fresh node.

## Changes
1. **Waiting records.** A unit waits to start when the loop would start it this tick if starts were unlimited. That is the repository's next triage or spec-PR update, under the existing one-slot rule. It is also each ready node without a running session, as a fresh node, a follow-up or a resume, and each session S06 would resume now. `SCHED_MAX` still applies: while the repository is at its cap, its nodes do not wait to start. For each waiting unit the loop keeps a record `waiting` in the unit's state folder (`node/<ID>/`, `issue/<N>/`, `pr/<N>/`) holding the time it first found the unit waiting. The record is removed when the unit starts, and when the unit stops waiting without starting (a question, a FAILED, a removed label). So a unit's wait counts from when it became ready, when its answer was released, or when its last session ended. The records survive a loop restart. *S07-AC-1.*
2. **`turn.py` orders the machine's waiting units.** Each tick the loop gives `turn.py` its waiting units. For each unit it passes the key, the kind (triage, update, follow-up, resumed or fresh), a fresh node's Size and the waiting time. A fresh node's Size is read from the header row of its spec on `origin/main`; a missing or unreadable Size counts as L. A resumed node is one whose worktree has commits ahead of `origin/main` or a brief in `out/node/<ID>/`, as S04 detects it, or an S06 resume. `turn.py` stores this list, and the loop's `SCHED_TICK`, as `state/<name>/waiting.json`. It then merges every live loop's list into one order:
   - first, the units that have waited longer than `SCHED_STARVE` seconds (default 21600, 6 hours), the longest waiting first;
   - then the small units (triage, update, follow-up, resumed);
   - then fresh S nodes, then fresh M nodes, then fresh L nodes;
   - within each group, the longest waiting first;
   - ties go by repository name, then by the loop's own order (graph order).

   A loop is live when its `heartbeat` is less than three of its ticks old. A stale loop's list is left out, so a stopped loop never holds the others. *S07-AC-2, S07-AC-5.*
3. **One start per gap, machine-wide.** The start record `$NOODLEBOT_DATA/state/starts.json` holds the time, repository and unit of the machine's last start. It is read and written only under an exclusive `flock` on `$NOODLEBOT_DATA/state/starts.lock`. Under that lock, `turn.py` gives the loop a turn only when three things hold:
   - the throttle is open (the loop asks only then);
   - at least the gap has passed since the last start, where the gap is `SCHED_START_GAP` seconds and defaults to the largest `SCHED_TICK` among the live loops;
   - the first unit of the merged order is one of this loop's units.

   It then records the start and names the unit. The loop starts that unit (`start_node`, `start_triage`, `start_update`, or S06's resume) and nothing else that tick. When two loops ask at the same moment, one of them gets the turn. *S07-AC-1, S07-AC-3.*
4. **A failed start gives its turn back.** When the unit's start fails (any "not started" outcome of the start functions), the loop tells `turn.py`. `turn.py` restores the previous start record and leaves that unit out of the order until the loop's next tick. The loop then asks again in the same tick, so a unit that cannot start never blocks the units behind it. *S07-AC-4.*
5. **S06's resume takes its turn.** A session S06 would resume waits as a resumed unit and is stopped and resumed only on its turn. As before, it uses no start of the node's `starts`. Until its turn the idle session is left as it is. *S07-AC-6.*
6. **The start says why.** The status-log event of every start made on a turn names four things: the unit's kind (or its Size, for a fresh node); how long it waited; that it went first by the starvation limit, when it did; and every unit, in any repository, that had waited longer and is still waiting (the units it went ahead of; up to three, then "+N more"). An example: `started S07 (start-queue) …; turn: S, waited 2h10m, ahead of themonolith/G01`. *S07-AC-5.*
7. **Settings and failure.** `SCHED_RAMP=0` turns the queue off: every ready unit starts in the same tick, as before, and the loop neither runs nor needs `turn.py`. When `turn.py` fails, the failure is logged and no session starts that tick; running sessions go on. The throttle, the 2-starts rule, the one triage or update per repository and `SCHED_MAX` are unchanged. *S07-AC-7.*

## Gate
- **S07-AC-1** — Take two loops under one `$NOODLEBOT_DATA` with `SCHED_RAMP=1` and the throttle open. With five ready units across their two repositories, exactly one session starts per turn, across both loops. Consecutive starts are at least the gap apart (`SCHED_START_GAP`, or by default the largest `SCHED_TICK` of the two loops). Every unit is started once, by the loop of its repository. When the throttle holds from the second turn, only the first unit starts, and the next starts at the first turn after the throttle opens again. *Verify:* `scheduler/loop.test.sh` (the status logs' start times) and `scheduler/turn.test.sh`.
- **S07-AC-2** — The units start in this order. A unit that has waited longer than `SCHED_STARVE` comes before every unit that has not. Then come triages, spec-PR updates, follow-ups and resumed nodes. Then come fresh nodes by their spec's Size: S, then M, then L, where a missing Size counts as L. Within each group, the unit that has waited longest comes first. So a triage and an S node start before an L node, and an older M node starts before a newer S node only once the M node's wait passes `SCHED_STARVE`. *Verify:* `scheduler/turn.test.sh` and `scheduler/loop.test.sh`.
- **S07-AC-3** — When both loops reach a turn at the same moment, one unit starts between them, not two. The start record and the waiting lists stay well-formed. *Verify:* `scheduler/turn.test.sh` (concurrent processes) and `scheduler/loop.test.sh`.
- **S07-AC-4** — A unit whose start fails does not hold the queue. The next unit in the order starts in the same tick, and the failed unit waits again from the next tick. Units of a loop whose heartbeat is older than three of its ticks are left out of the order, so a stopped loop never blocks a live one. *Verify:* `scheduler/turn.test.sh` and `scheduler/loop.test.sh`.
- **S07-AC-5** — Each unit's wait counts from when its loop first found it waiting: ready, answered or released, or ended. The wait survives a loop restart and restarts after the unit stops waiting without starting. Each start made on a turn has one status-log event. It names the unit's kind or Size and its wait, says when the starvation limit put it first, and names the units that had waited longer and were still waiting. *Verify:* `scheduler/loop.test.sh`.
- **S07-AC-6** — A session S06 would resume takes a turn like a resumed node. While another unit holds the turn, or the gap has not passed, the idle session is neither stopped nor resumed. On its turn it is resumed as S06 says, with the node's `starts` unchanged. *Verify:* `scheduler/loop.test.sh`.
- **S07-AC-7** — Running sessions are never stopped or delayed by the queue. `SCHED_MAX` still caps a repository's sessions, and one triage or update at a time per repository still holds. With `SCHED_RAMP=0`, every ready unit starts in the same tick as before; every existing `scheduler/loop.test.sh` run passes with only the added `SCHED_RAMP=0` export. When `turn.py` fails, no session starts that tick, and the status log says so. *Verify:* `scheduler/loop.test.sh`.

## Risks
- The default starvation limit (6 hours, just over one 5-hour window) and the default gap (one tick of the slowest loop) are first guesses. Neither has been measured against how fast the throttle notices a new session's burn. A new session's first `rate_limit_event` may come later than one tick, in which case one tick of spacing still adds sessions faster than the throttle can react.
- A loop wakes early on local events (a marker, an exit), so turns are spaced by time, not by ticks. The next unit may wait up to one of its own ticks past the gap.
- Sizes come from the specs' header rows and are only as honest as the specs. The "small" kinds (triage, update, follow-up, resume) are assumed short, which a long follow-up can defeat.
- Every loop must see the same `$NOODLEBOT_DATA` (SPEC §2). Loops on different roots each keep their own queue and can still start together.
