# T03 — weekly-pace

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | T01, M01, D01 | none | S |

**Owns:** the 7-day pace setting `USAGE_7D_PACE` in `scheduler/usage.py` (the hold it turns on, its docstring line, the `seven_day_pace` entry of `usage.json`'s `limits`) and its cases in `scheduler/usage.test.sh`; the settings `scheduler/loops.sh start` passes to each loop, their line in its header comment and the README's run instructions, and their case in `scheduler/loops.test.sh`; the `USAGE_*` variables cleared for `scheduler/deploy.sh`'s `make test` and their case in `scheduler/deploy.test.sh`; the environment check of the self-deploy run in `scheduler/loop.test.sh`.
**Resolves:** #57

## Purpose
After this node the throttle's 7-day pace hold is optional and off by default. Today `usage.py` holds new sessions whenever the 7-day window is more than `USAGE_7D_MARGIN` ahead of an even pace for the week, which holds early and hard right after a weekly reset while the 5-hour throttle already does the pacing. Now the pace hold runs only with `USAGE_7D_PACE=1`; a 7-day window the plan has cut off (status not `allowed`) still holds, and the 7-day reading and its pace are still shown so the owner can decide to turn the hold on. The settings reach the loops: `loops.sh start` passes its `USAGE_*` and `SCHED_*` variables into each loop's tmux session, a deploy's re-exec keeps them, and a deploy's `make test` runs without them.

## Tests
- `scheduler/usage.test.sh` (extended, adding lines only):
  - one line near the top, `unset USAGE_7D_PACE USAGE_7D_MARGIN USAGE_5H_LIMIT`, so the file's results do not depend on the caller's environment (a session's or a loop's);
  - around the existing case "7-day ahead of pace: hold", one added line before it, `USAGE_7D_PACE=1; export USAGE_7D_PACE`, and one after its check, `unset USAGE_7D_PACE`. That case then keeps its meaning under the setting that now turns the pace hold on, and no existing line changes;
  - with the setting unset, and with `USAGE_7D_PACE=0`, the same window (75% used at 57% of the week) is `open:`, and the summary and `usage.json` still carry its reading and pace;
  - with `USAGE_7D_PACE=1`, a window within the margin is `open:`, and `USAGE_7D_MARGIN=0.25` turns that 75%-at-57% window `open:`;
  - a rejected 7-day window holds with the setting unset, `0` and `1`;
  - `usage.json`'s `limits.seven_day_pace` is `false` without the setting and `true` with it.
- `scheduler/loops.test.sh` (extended): a `start` with `USAGE_7D_PACE=1`, `USAGE_7D_MARGIN=0.2` and `SCHED_TICK=7` in its environment, and a value with a space in one `SCHED_*` variable, through a fake `tmux` whose started command sees an environment without them (as a tmux server started earlier would). The fake `loop.sh` records its environment.
- `scheduler/deploy.test.sh` (extended): a commit whose `make test` fails when a `USAGE_*` variable is set, deployed by a `deploy.sh` run with `USAGE_7D_PACE=1` and `USAGE_5H_LIMIT=0.5` in its environment.
- `scheduler/loop.test.sh` (extended): in the self-deploy run (D01), after the re-exec, the loop's `/proc/<pid>/environ` still holds the `SCHED_*` settings the run started it with.

## Changes
1. **The pace hold is opt-in.** `usage.py` holds for the 7-day pace only when `USAGE_7D_PACE` is `1`; unset, `0` or any other value, it never holds for the pace. When on, it holds as before, when the window is more than `USAGE_7D_MARGIN` (default 0.10) ahead of an even pace. A window whose status is not `allowed` holds whatever the setting, as every window does. The `open:`/`hold:` summary keeps "7-day N% at M% of the week", `usage.json` keeps the window and `weekElapsed`, and its `limits` gains `seven_day_pace` (`true` or `false`), so the status issue, `status.sh` and the API show the reading as before. The docstring names the setting. *T03-AC-1, T03-AC-2, T03-AC-3.*
2. **`loops.sh start` passes the settings.** For each variable in its own environment whose name starts with `USAGE_` or `SCHED_`, `start` adds `NAME=value` to the `env` command of each loop's tmux session, next to `NOODLEBOT_DATA`, with the value passed as one argument whatever it holds. A variable that is not set is not passed. The header comment and the README's run instructions say so, with `USAGE_7D_PACE=1 scheduler/loops.sh start` as the example. *T03-AC-4.*
3. **A deploy's re-exec keeps them.** The loop's re-exec after a deploy runs the new `loop.sh` with the loop's own environment, so the settings it was started with stay. *T03-AC-5.*
4. **A deploy's `make test` runs without them.** `deploy.sh` clears the loop's `USAGE_*` variables for `make test`, as it already does `SCHED_*` and `NOODLEBOT_DATA`. *T03-AC-6.*
5. **`usage.test.sh` does not read the caller's settings** (the added `unset` line), so a session started by a loop with `USAGE_7D_PACE=1` gets the same results from it. *T03-AC-7.*

## Gate
- **T03-AC-1** — With `USAGE_7D_PACE` unset or `0`, `usage.py` never holds for the 7-day pace: a 7-day window 75% used at 57% of the week, with an open 5-hour window, prints `open:` with "7-day 75% at 57% of the week" in its summary, and `usage.json` keeps that window, its `weekElapsed` and `limits.seven_day_pace` `false`. *Verify:* `scheduler/usage.test.sh`.
- **T03-AC-2** — With `USAGE_7D_PACE=1`, the 7-day window holds when it is more than `USAGE_7D_MARGIN` (default 0.10) ahead of an even pace and is open within it: the existing case "7-day ahead of pace: hold" passes unchanged under the added export, a window within the margin is `open:`, `USAGE_7D_MARGIN=0.25` opens the 75%-at-57% window, and `limits.seven_day_pace` is `true`. *Verify:* `scheduler/usage.test.sh`.
- **T03-AC-3** — A 7-day window whose status is not `allowed` holds with `USAGE_7D_PACE` unset, `0` and `1`, and every other existing case of `scheduler/usage.test.sh` passes with no line changed. *Verify:* `scheduler/usage.test.sh`.
- **T03-AC-4** — Every `USAGE_*` and `SCHED_*` variable set in `loops.sh start`'s environment reaches each loop it starts with its value unchanged (a value with a space included), even when the tmux server's environment lacks it; a variable not set in `start`'s environment is not added. *Verify:* `scheduler/loops.test.sh`.
- **T03-AC-5** — After a deploy's re-exec, the loop's environment still holds the `SCHED_*` settings it was started with. *Verify:* `scheduler/loop.test.sh` (the self-deploy run).
- **T03-AC-6** — `deploy.sh`'s `make test` sees none of the loop's `USAGE_*` variables: a commit whose `make test` fails when one is set is deployed by a `deploy.sh` run that has `USAGE_7D_PACE=1` and `USAGE_5H_LIMIT=0.5` in its environment. *Verify:* `scheduler/deploy.test.sh`.
- **T03-AC-7** — `scheduler/usage.test.sh` gives the same results whatever `USAGE_*` variables its caller has: `USAGE_7D_PACE=1 USAGE_7D_MARGIN=0.5 USAGE_5H_LIMIT=0.5 sh scheduler/usage.test.sh` passes like the plain run. *Verify:* a recorded run of both, in the PR.

## Risks
- With the pace hold off, only the 5-hour throttle paces the week. A heavy week can reach the plan's 7-day limit, which then holds every new session until the weekly reset (the hard limit, AC-3).
- `loops.sh start` adds what its own environment has; it does not remove what the tmux server adds. A server started earlier with a setting in its global environment still gives it to a loop started without it; an explicit `USAGE_7D_PACE=0 scheduler/loops.sh start` overrides it.
- Running loops keep the settings they were started with, across deploys too: changing one needs `loops.sh stop` and `start`.
- Sessions inherit the loops' settings. `usage.test.sh` and a deploy's `make test` are made independent of them here; another test that reads a `USAGE_*` or `SCHED_*` variable from its environment without setting it could behave differently inside a session.
