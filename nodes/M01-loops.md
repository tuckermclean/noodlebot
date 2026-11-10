# M01 — loops

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | none | P01, T03 | S |

**Owns:** `scheduler/loops.sh`, `scheduler/loops.test.sh`, the README's run instructions.

## Purpose
After this node one command manages the scheduler for every repository on the machine: `loops.sh start`, `stop` and `status` act on each repository in the machine's list (`~/.config/noodlebot/repos`, one `owner/name` per line), so adding a repository is one line.

## Tests
- `scheduler/loops.test.sh` (new): fake `tmux` and loop scripts on a temporary `PATH`, a list of two repositories.

## Changes
1. **`loops.sh start`** starts a loop in tmux session `sched-<name>` for each listed repository whose loop is not running (its `loop.lock` is free). *AC-1.*
2. **`loops.sh stop`** creates `~/STOP-<name>` for each, waits for its loop to exit, then removes the file; sessions keep running. *AC-2.*
3. **`loops.sh status`** prints one line per repository: loop running or not, sessions running, what waits on the owner. *AC-3.*

## Gate
- **M01-AC-1** — `loops.sh start` starts a loop for every listed repository that has none, and leaves running loops alone. *Verify:* `scheduler/loops.test.sh`.
- **M01-AC-2** — `loops.sh stop` stops every listed repository's loop and no session. *Verify:* `scheduler/loops.test.sh`.
- **M01-AC-3** — `loops.sh status` prints one line per listed repository with its loop state, running sessions and what waits on the owner. *Verify:* `scheduler/loops.test.sh`.

## Risks
- The list lives outside the repository, on the machine; a missing list means "no repositories" and says so.
