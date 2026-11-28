# S17 — review-loop

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S16, S07, S12 | U08 | M |

**Owns:** in `scheduler/loop.sh`: the review step (reading `~/.config/noodlebot/reviewer-token` and
`~/.config/noodlebot/reviewer-login`, the pause file `$NOODLEBOT_DATA/state/review.stop`, the setting
`SCHED_REVIEW_SETTLE` and its default, running `reviewer.py candidates`, `prepare` and
`post` in the background one pass at a time, starting the review session through `run-session.sh` with the read-only
start, the unit `review/<N>`, its end, the attempt count and the no-verdict note, the log `state/<name>/review.log`), the
`review/*/session.pid` folder in the running-sessions scan that a restarted loop takes sessions over with, and their
lines in the header comment; in `scheduler/run-session.sh`, the read-only start (passing it to the harness, and
exporting no `NOODLEBOT_FORGE*` variable to such a session); in `scheduler/turn.py`, the unit kind `review` and its place in the start order, with
its line in the docstring; the end-to-end tests `scheduler/loop-s17.test.sh`, `scheduler/loop-s17-wait.test.sh` and
`scheduler/loop-s17-fail.test.sh` (new, each under the 30 s file budget), their lines in the `Makefile`'s `TESTS`, a
fixture `scheduler/testdata/lib/loop-s17.sh` if they share one, and the one line each that copies `reviewer.py` into the
scratch `scheduler/` folder of an existing loop fixture where a frozen test needs it (added after the existing copy
lines, never changing one); `scheduler/turn-s17.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #259

## Purpose
After this node every loop reviews its repository's open PRs by itself whenever the reviewer App's token script and
login file exist. Each tick runs at most one review pass, and a pass reviews at most one PR. Its session takes a start from the
start queue and waits on the throttle like any other unit, and it runs in its own session scope (S12). The loop, not
the session, posts the review. A head whose review session fails twice gets one no-verdict note. A pause file stops the
reviewer alone. Without the token script or the login file the loop logs that nothing is reviewed and is otherwise
exactly as it is today, so every existing loop test holds. A restarted loop takes a running review session over as it
does any unit's.

## Tests
- `scheduler/loop-s17.test.sh` (new), end to end with the fake forge, the fake `gh` and the fake `claude`, the reviewer
  token script a fake that prints a marker token:
  - A PR at a new head, settled (`SCHED_REVIEW_SETTLE` small) and with CI finished, is reviewed once: one review
    session starts (unit `review/<N>`, its `session.unit` recorded as S12 does), its review passes `draft`, and one
    review at that head is posted with the reviewer's marker token. A later pass at the same head starts nothing and
    posts nothing.
  - The review session's environment, as the fake `claude` records it, holds neither the reviewer's marker token nor
    n00dl3b0t's (the fake home's `token` prints a marker of its own), and no `NOODLEBOT_FORGE*` variable.
  - The session's start took a turn from `turn.py` (kind `review`, in the start's status-log event), and a throttle
    hold (T01) keeps it waiting as it keeps any unit.
  - The head moving between the session's end and the post posts nothing, and the next pass reviews the new head.
  - Evidence: `state/<name>/review/<N>/<sha>/` holds the context, the session log, `review.json` and `record.json`.
- `scheduler/loop-s17-wait.test.sh` (new): a draft PR, a head still within the settle time, CI still running at the
  head and a live session on the PR's unit (a node session on `node/<ID>-*`, a feedback session in `pr/<N>`) each
  start no review session and post nothing while they last, and a review follows once the wait ends. Two eligible PRs
  in one pass give one review session, and the second PR waits for a later pass. A pass still running when the next
  tick comes is not started twice. `$NOODLEBOT_DATA/state/review.stop` stops the reviewer while node and triage units
  still start, and removing it lets the reviewer go on. With `SCHED_REVIEW_SETTLE` unset the settle time is 600 s,
  passed as `--settle 600`: a head whose `review/<N>/seen` was seeded 590 s ago still waits `settling`, and one seeded
  610 s ago is reviewed.
- `scheduler/loop-s17-fail.test.sh` (new): a review session that ends with no valid `review.json` is retried on the
  next pass. After 2 failed attempts at one head, exactly one no-verdict note is posted (S16's `post --no-verdict`),
  and no third session starts at that head. A new head starts the count again. With no reviewer token script (or one
  that fails), no review session starts, nothing is posted, `review.log` says `no reviewer App token; nothing reviewed`
  once per loop start, `status.log` gets no line from the review step, and node, triage, update and feedback units run
  as before. With the token script but no `~/.config/noodlebot/reviewer-login` (or an empty one) the same holds, and
  `review.log` says `no reviewer App login; nothing reviewed` once per loop start.
  - A loop stopped and started again while a review session runs takes the session over (its `session.pid` under
    `review/<N>/` found by the running-sessions scan): no second session starts at that head, and once the session
    ends its review is posted exactly once.
- `scheduler/turn-s17.test.sh` (new): `turn.py list` accepts the kind `review`, and `ask` orders a review unit after
  triage, update, followup and resumed units and before fresh nodes, with the starvation limit applied as to any unit.
- The existing loop tests, unchanged (their fake homes hold no reviewer token script).

## Changes
1. **The review step.** When `~/.config/noodlebot/reviewer-token` and a non-empty `~/.config/noodlebot/reviewer-login`
   exist and `review.stop` does not, each tick starts one background pass unless one still runs (a lock under
   `state/<name>/review/`). The pass runs `reviewer.py candidates` with `--settle` from `SCHED_REVIEW_SETTLE` (default
   600), takes the first eligible PR in PR order, runs `prepare` and lists the unit `review/<N>`
   with the waiting units. *S17-AC-1, S17-AC-2.*
2. **The session.** When the unit gets its turn and the throttle is open, `run-session.sh` starts the review session
   with the read-only start in the session scope, with `NOODLEBOT_FORGE*` and every token variable removed from its
   environment (`run-session.sh` exports `NOODLEBOT_FORGE` to every other session, and to this one it does not). Its end runs `reviewer.py post N <sha>` with `NOODLEBOT_FORGE_PROFILE=reviewer` and the reviewer's
   token script, in a process of its own. The session never gets the variable. *S17-AC-1, S17-AC-3.*
3. **Attempts.** A session that ends without a valid `review.json` adds one to `review/<N>/<sha>/attempts`. At 2 the
   loop runs `post --no-verdict` and starts no further session at that head. *S17-AC-4.*
4. **No token, no login, pause.** No token script (or a failing one): one `review.log` line per loop start, and the
   step does nothing else. No login file (or an empty one): the same with `no reviewer App login; nothing reviewed`.
   `review.stop` stops the step at its start. All three leave every other step unchanged. *S17-AC-5.*
5. **The start order.** `turn.py` gets the kind `review`. *S17-AC-2.*
6. **Restart.** The running-sessions scan also reads `review/*/session.pid`, so a restarted loop takes a live review
   session over and runs its end (the post, or the attempt count) when it ends, like any unit's. *S17-AC-6.*

## Gate
- **S17-AC-1** — End to end with fakes, a PR at a new, settled, CI-finished head gets one review session in the unit `review/<N>` (in its session scope) and one review posted at that head with the reviewer's token, a second pass at the same head starts and posts nothing, a head that moves between the session and the post gets nothing posted, `review/<N>/<sha>/` holds the context, the session log, `review.json` and `record.json`, and the review session's recorded environment holds neither the reviewer's marker token nor n00dl3b0t's and no `NOODLEBOT_FORGE*` variable. *Verify:* `sh scheduler/loop-s17.test.sh`.
- **S17-AC-2** — A review session takes a turn from the start queue (kind `review`, after triage, update, followup and resumed units and before fresh nodes) and waits on a throttle hold like any unit; a pass reviews at most one PR and a pass still running is not started again. *Verify:* `sh scheduler/loop-s17.test.sh`, `sh scheduler/loop-s17-wait.test.sh` and `sh scheduler/turn-s17.test.sh`.
- **S17-AC-3** — A draft PR, a head within the settle time, CI still running at the head and a live session on the PR's unit each start no review session and post nothing, and the review follows once the wait ends; with `SCHED_REVIEW_SETTLE` unset the settle time is 600 s (a head seen 590 s ago waits, one seen 610 s ago is reviewed). *Verify:* `sh scheduler/loop-s17-wait.test.sh`.
- **S17-AC-4** — A review session that gives no valid review is retried on the next pass, and after 2 failed attempts at one head exactly one no-verdict note is posted and no further session starts at that head, a new head starting the count again. *Verify:* `sh scheduler/loop-s17-fail.test.sh`.
- **S17-AC-5** — With no reviewer token script or a failing one, nothing is reviewed or posted, `review.log` says `no reviewer App token; nothing reviewed` once per loop start and the loop's other units run as before; with the token script but no or an empty `reviewer-login` the same holds with `no reviewer App login; nothing reviewed`; `$NOODLEBOT_DATA/state/review.stop` stops the reviewer alone. *Verify:* `sh scheduler/loop-s17-fail.test.sh` and `sh scheduler/loop-s17-wait.test.sh`.
- **S17-AC-6** — A loop stopped and started again while a review session runs takes that session over: no second review session starts at that head, and once the session ends its review is posted exactly once. *Verify:* `sh scheduler/loop-s17-fail.test.sh`.

## Risks
- Every loop on the machine reviews its own repository, so with several repositories several review sessions can be
  waiting at once. The start queue lets them in one at a time, and S13's machine budget, once merged, counts them as
  running sessions.
- The loop tests copy a fixed list of scheduler files into scratch folders. The step must do nothing without the
  token script, and `reviewer.py` is added to a fixture's copy list only where a frozen test needs it, with one added
  line.
- A review session runs tests of the PR (RED and GREEN where cheap) on the scheduler's machine, which adds load that
  timing-sensitive loop tests of other sessions have suffered from (D05, D17). S12's memory ceiling and D18's bounded
  runs apply to it as to any session.
- A loop restart while a review session runs takes the session over as it does other units (principle 2, change 6).
  A loop that stops between a session's end and its post leaves the head with no review, so a later pass reviews it
  again: one more session, never a second review at that head.
