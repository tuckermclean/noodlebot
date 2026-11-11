# P03 — api-controls

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | P01 | S08 | M |

**Owns:** the control requests in `scheduler/api.py` and their schemas in `scheduler/api-schema/v1/`, their cases in `scheduler/api-p03.test.sh` (a part of the API test, D03); the request records and the one-shot release (`node/<ID>/RELEASE`) in `scheduler/loop.sh`, their cases in `scheduler/loop-p03.test.sh` and `scheduler/loop-p03-ramp.test.sh` (parts of the loop test, D03); the `took` command in `scheduler/turn.py`, its cases in `scheduler/turn-took.test.sh` (a part of the turn test, D03); the requested retry and rollback (`deploy/retry`, `deploy/rollback-request`) in `scheduler/deploy.sh`, their cases in `scheduler/deploy.test.sh`; the controls part of the README's API section.
**Resolves:** #46

## Purpose
After this node the owner's controls are requests to the API, so a client can offer them without touching state files. Each request writes only a marker the loop already reads, or a new one-shot marker that the loop or `deploy.sh` consumes at its next run. The loop stays the only actor and every request appears in the status log. The controls are: delete a node's or issue's FAILED, create or remove `~/STOP-<name>`, let one node the throttle holds start once, retry a commit `deploy.sh` rejected, and request a rollback. The API never stops, starts or signals a process and never touches a worktree. Answering a question is not a control: `report.py` takes answers only from the owner's comments on GitHub, so the question's resource keeps linking to the issue where it is answered (P01).

## Tests
- `scheduler/api-p03.test.sh` (a part of the API test since D03 split `api.test.sh`): each request against the P01 fixture, with a valid target and with invalid ones (an unknown repository, node, issue or commit, no FAILED, no rollback point). It checks the following:
  - the status code and body;
  - every file under the runtime root and `HOME` before and after;
  - that no process was signalled (the fixture's sessions are still alive).
- `scheduler/loop-p03.test.sh` (a part of the loop test since D03 split `loop.test.sh`), in a loop run of its own with its own fixture: request records for each control and a `RELEASE` for a node that the throttle holds, for one with the throttle open and for one that is not ready. It checks the status log, `starts`, the processes and that each record and marker is consumed once. A second run of its own, `scheduler/loop-p03-ramp.test.sh`, sets `SCHED_RAMP=1` (S07's start queue) and has a `RELEASE` for a node the throttle holds, then opens the throttle with another unit waiting. It checks that the released node starts at that tick without a turn, that `state/starts.json` records its start, and that the next start on a turn comes at least the gap after it. It also has a `RELEASE` with the throttle open, which starts nothing out of turn.
- `scheduler/turn-took.test.sh` (a part of the turn test): `took` records a start of its unit under the lock, whatever the gap and the order; an `ask` right after it gets no turn until the gap has passed; a `giveback` after a `took` restores the previous start record.
- `scheduler/deploy.test.sh` (extended): a `deploy/retry` naming a rejected commit whose `make test` now passes, one naming a commit that is not rejected, and a `deploy/rollback-request` with and without `deploy/previous`. It checks the following:
  - the live checkout's head;
  - `deploy/rejected`;
  - the printed status lines;
  - that each marker is consumed.

## Changes
1. **The requests.** P01's server accepts these, and still answers 405 to any other write. Each request writes a request record, `state/<name>/requests/<UTC time>-<n>.json` (the control, its target and the time, written to a temporary file and renamed). A deploy request goes to `deploy/` instead, as the deploy request itself. A valid request is answered 202 with the marker or record it wrote and a line saying when the loop carries it out. An unknown target is a 404 and a request with nothing to do a 409, and neither writes anything. *P03-AC-1, P03-AC-2.*
   - `DELETE /v1/repos/<owner>/<name>/nodes/<ID>/failed` and `.../issues/<N>/failed` remove that `FAILED` (a 409 if there is none) and write the record.
   - `PUT /v1/repos/<owner>/<name>/stop` creates `~/STOP-<name>`, and `DELETE` removes it (a 409 if it is already so), and each writes the record. The API starts no loop: the 202 after a removal says that `scheduler/loops.sh start` starts it.
   - `POST /v1/repos/<owner>/<name>/nodes/<ID>/release` writes `state/<name>/node/<ID>/RELEASE` and the record.
   - `POST /v1/deploy/retry` with `{"sha": "<commit>"}` writes `$NOODLEBOT_DATA/deploy/retry` holding the commit (a 409 if it is not in `deploy/rejected`).
   - `POST /v1/deploy/rollback` writes `$NOODLEBOT_DATA/deploy/rollback-request` (a 409 if there is no `deploy/previous`).
2. **The loop records each request.** At the start of every iteration of its main loop, before it looks for `~/STOP`, the loop reads its `state/<name>/requests/`, in order. For each record it writes one status-log event naming the control and its target, then removes the record. A request made while the loop was stopped is therefore logged when it starts again. What the request changed then takes effect the usual way: a node without `FAILED` starts at the next tick if ready, and a loop finding `~/STOP-<name>` exits. *P03-AC-3.*
3. **The one-shot release.** At its next tick the loop consumes every `node/<ID>/RELEASE`:
   - If the throttle holds and `ready.py` would start that node, which has no session, the loop starts it despite the hold. The start counts as usual, `SCHED_MAX` still applies, and the status log says the node was released past the throttle.
   - Otherwise it starts nothing it would not have started anyway, and the status log says why the release did nothing: the throttle was open, or the node's state.
   - With the start queue on (`SCHED_RAMP=1`, S07), a released node skips the queue. It starts at that tick as above, without waiting for a turn or the gap. Before starting it, the loop records the start in the machine's start record with `turn.py took <key>`, which writes `state/starts.json` under the same lock as a turn, whatever the gap and the order. So the next turn on the machine, in any loop, comes at least the gap after the release. A failed start gives the record back as `turn.py giveback` does (S07 change 4). A failing `turn.py took` is logged and starts nothing, as S07 change 7 says for `turn.py`. The node's `waiting` record is removed as for any start.
   - With the queue on and the throttle open, the release does nothing out of turn: the node waits for its turn, and the status log says so.

   Either way `RELEASE` is removed, so a release lets at most one session start. *P03-AC-4.*
4. **The requested retry and rollback.** `deploy.sh`, at the start of a normal run and under its lock, consumes these markers before anything else:
   - `deploy/rollback-request`: it rolls back as `--rollback` does and prints one status line saying the rollback was requested, or that there was no rollback point.
   - `deploy/retry`: it removes the named commit from `deploy/rejected` and its counts from `deploy/tries` and `deploy/passed`, and prints one status line saying the retry was requested. If that commit is still `origin/main`'s head, the same run tests it again as usual. A commit no longer rejected is one line saying there was nothing to retry.

   The markers are machine-wide: the first loop to run `deploy.sh` carries them out and logs the line, which is how deploy lines are logged today. *P03-AC-5.*
5. **The README**'s API section lists the controls, with an example of each over `curl --unix-socket`. *P03-AC-1.*

## Gate
- **P03-AC-1** — Each valid request of change 1 is answered 202 and changes exactly these files: its marker (the `FAILED` removed, `~/STOP-<name>` created or removed, `RELEASE`, `deploy/retry` or `deploy/rollback-request` written) and its request record. No process is signalled. The README lists every control. *Verify:* `scheduler/api-p03.test.sh`; the README by review.
- **P03-AC-2** — An unknown repository, node, issue or commit is answered 404. Each of these is answered 409: a `FAILED` that does not exist, a STOP file already in the requested state, a retry of a commit that is not rejected, and a rollback with no rollback point. Neither changes any file. Any other write is answered 405. *Verify:* `scheduler/api-p03.test.sh`.
- **P03-AC-3** — Each request record is logged by the loop as one status-log event naming the control and its target, and then removed. This happens within one iteration of a running loop, and at the start of a loop that was stopped. A node whose `FAILED` a request removed starts at the next tick if it is ready. *Verify:* `scheduler/loop-p03.test.sh`.
- **P03-AC-4** — A `RELEASE` for a node that `ready.py` would start while the throttle holds starts that node at the next tick, once, counted as a start, with one status-log event saying it was released past the throttle. A second tick starts nothing more. A `RELEASE` with the throttle open, or for a node that is not ready, starts nothing the loop would not have started anyway, and is logged with its reason. Every `RELEASE` is removed at that tick. With `SCHED_RAMP=1` (S07's start queue), the released node starts at that tick without waiting for a turn or the gap, and its start is recorded in `state/starts.json`, so the next start on a turn, in any loop, comes at least the gap after it; a `RELEASE` with the throttle open starts nothing out of turn. *Verify:* `scheduler/loop-p03.test.sh` (with `SCHED_RAMP=0`), `scheduler/loop-p03-ramp.test.sh` (with `SCHED_RAMP=1`) and `scheduler/turn-took.test.sh` (`took`).
- **P03-AC-5** — With `deploy/retry` naming a rejected `origin/main` head whose `make test` now passes, the next `deploy.sh` run deploys it and prints a line saying the retry was requested. With `deploy/rollback-request` and a rollback point, the next run leaves the live checkout at `deploy/previous`, as `--rollback` does, and prints a line saying the rollback was requested. A retry of a commit that is not rejected, or a rollback request without a rollback point, is one line saying there was nothing to do. In every case the marker is gone after the run. *Verify:* `scheduler/deploy.test.sh`.

## Risks
- Removing `~/STOP-<name>` through the API does not restart the loop; the owner still runs `loops.sh start`. Starting loops from the API would make it an actor, which the request model rules out.
- A release past the throttle can push the plan's usage over its limit. That is the owner's call each time, and the status log records it.
- A retried commit that is flaky may fail again and be rejected again. Each retry is one more `make test` run, and the status log shows each.
- The API runs as the owner, so anyone who can reach the socket can use the controls. The socket's mode (P01) is the only guard, as the issue intends; network exposure would be a node of its own.
