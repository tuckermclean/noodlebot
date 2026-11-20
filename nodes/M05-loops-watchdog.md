# M05 — loops-watchdog

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | M04, U02 | none | M |

**Owns:** in `scheduler/loops.sh`: the `watch` command, the record of the settings `start` passes (`$NOODLEBOT_DATA/state/loops.env`) and of a stop (`$NOODLEBOT_DATA/state/loops.stopped`), the watch timer `start` sets up and `stop` ends, the watch line of `status`, and their lines in the header comment; in `scheduler/report.py`: the watch's events among the status-log events posted on the day's log issue, and the stale-loop comment on it; `scheduler/loops-m05.test.sh` (new) and its line in the `Makefile`'s `TESTS`; the README's lines on the watch.
**Resolves:** #218

## Purpose
After this node a loop or API server that died is started again within minutes, and a loop that hangs is reported, without the owner noticing first. `loops.sh watch`, run every few minutes by a systemd user timer that `loops.sh start` sets up (with M04's units file) or by the owner's cron, starts each listed repository's loop and the API server that is not running, with the settings the last `start` passed, unless the owner stopped them. A loop whose lock is held but whose heartbeat is older than a limit is never killed; it is reported on that repository's log issue. Every restart is an event on the day's log issue.

## Tests
- `scheduler/loops-m05.test.sh` (new) runs `loops.sh` with the fake `tmux`, a fake `loop.sh` that takes its lock and writes a heartbeat (as `scheduler/testdata/lib/loops-body.sh`'s does), a fake `systemd-run`/`systemctl` that log their arguments, the fake forge, a scratch `HOME` and runtime root, scratch paths under a folder named `M05`, and shows:
  - `start` with `SCHED_MAX=2 USAGE_7D_PACE=1` writes `state/loops.env` (mode 0600) holding exactly those passed settings; a later `watch` with an empty environment, after one loop's fake has exited, starts that loop with the same settings (the fake records its environment), leaves the running loop alone, and starts the API when its lock is free;
  - each loop `watch` restarts gets one line in its `status.log` naming the restart by the watch and how old its heartbeat was (or that it had none); `report.py` posts it among the day's events on the log issue;
  - no restart while `~/STOP` or `~/STOP-<name>` exists (for that repository), or after `loops.sh stop` until the next `loops.sh start` (`state/loops.stopped`);
  - a loop whose lock is held and whose heartbeat is older than `LOOPS_STALE` (default 1800 s) is not signalled; `watch` writes one line to `state/watch.log` and `report.py` posts one comment on that repository's open log issue naming the loop and its heartbeat's age, once per stale episode (none again until the heartbeat has been fresh once);
  - with the units on, `start` sets up the timer (`systemd-run --user --unit noodlebot-watch --on-unit-active=<LOOPS_WATCH_EVERY, default 5min>` running `loops.sh watch`) unless it is already active, `stop` stops it, and `status` prints one line saying whether the watch timer runs; with the units off, no `systemd-run` call and `status` says no watch timer runs;
  - two `watch` runs at once start each loop once.
- Every existing `scheduler/loops*.test.sh` and `scheduler/report*.test.sh` passes unchanged.

## Changes
1. **The recorded settings.** `start` writes the settings it passes to each loop (T03's `USAGE_*`, `SCHED_*` and `PICKUP*` list) to `state/loops.env` (0600, one per line, written atomically) and removes `state/loops.stopped`; `stop` writes `state/loops.stopped`. *M05-AC-1, M05-AC-3.*
2. **`loops.sh watch`.** Under a lock of its own, it starts every listed loop whose lock is not held and the API whose lock is not held, as `start` does and with the recorded settings, unless `~/STOP`, `~/STOP-<name>` or `state/loops.stopped` exists; it writes the restart line to the repository's `status.log`. A loop whose lock is held and whose heartbeat is older than `LOOPS_STALE` is noted in `state/watch.log`, never signalled. *M05-AC-1, M05-AC-2, M05-AC-3.*
3. **The reports.** `report.py` posts the watch's restart lines among the status-log events on the day's log issue, and once per stale episode one comment on the log issue for a stale loop the watch noted (a failed post is logged and tried again on the next run). *M05-AC-1, M05-AC-2.*
4. **The timer.** With M04's units on, `start` sets up the transient timer `noodlebot-watch` running `loops.sh watch` every `LOOPS_WATCH_EVERY`; `stop` stops it; `status` says whether it runs. Without units, the README shows the cron line that runs `loops.sh watch`. *M05-AC-4.*

## Gate
- **M05-AC-1** — `loops.sh watch` starts each listed repository's loop and the API server whose lock is not held, with exactly the settings the last `loops.sh start` passed (from `state/loops.env`, mode 0600, holding only those settings), leaves running ones alone, starts each once when two watches run at once, and each restart is one line in that repository's `status.log` naming the watch and the heartbeat's age, which `report.py` posts among the day's events on the log issue. *Verify:* `scheduler/loops-m05.test.sh`.
- **M05-AC-2** — A loop whose lock is held and whose heartbeat is older than `LOOPS_STALE` (default 1800 s) is never signalled by `watch`; it is one line in `state/watch.log` and one comment on that repository's open log issue naming the loop and the heartbeat's age, posted once per stale episode. *Verify:* `scheduler/loops-m05.test.sh`.
- **M05-AC-3** — `watch` starts nothing for a repository while `~/STOP` or `~/STOP-<name>` exists, and nothing at all after `loops.sh stop` until the next `loops.sh start`. *Verify:* `scheduler/loops-m05.test.sh`.
- **M05-AC-4** — With `~/.config/noodlebot/units` present, `loops.sh start` sets up the `noodlebot-watch` timer running `loops.sh watch` every `LOOPS_WATCH_EVERY` (default 5 minutes) unless it is already active, `loops.sh stop` stops it and `loops.sh status` says whether it runs; without the file `start` makes no `systemd-run` call for it; every existing `scheduler/loops*.test.sh` passes unchanged. *Verify:* `scheduler/loops-m05.test.sh` and the existing tests in `make test`.

## Risks
- The timer is transient: a reboot or a restart of the user manager drops it until the next `loops.sh start`; with lingering off (M04's line) it does not run while the owner is logged out, nor do the loops.
- `loops.env` holds the settings, never a credential; `start`'s pass list has no credential variable (T03).
- A loop restarted by the watch takes over its running sessions as any restarted loop does (principle 2); a loop that keeps dying is restarted every few minutes, each restart an event the owner sees.
- The stale report needs the forge's token from the token script outside a loop; when that fails it stays in `watch.log` and on stderr (the timer's journal).
