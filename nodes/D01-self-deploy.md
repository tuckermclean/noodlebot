# D01 — self-deploy

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | V01 | M |

**Owns:** `scheduler/deploy.sh`, `scheduler/deploy.test.sh`, the deploy step and re-exec in `scheduler/loop.sh`, their cases in `scheduler/loop.test.sh`.

## Purpose
After this node, merging a change to noodlebot deploys it: the scheduler tests the new commit of its own repository and, only if `make test` passes, moves its live checkout to it and restarts its loops between ticks without stopping a session. A failing commit is never deployed, and the owner can roll back to the previous commit with one command.

## Tests
- `scheduler/deploy.test.sh` (new): a fake remote of the scheduler's own repository with a passing and a failing commit; the live checkout as a clone; `make test` stubbed per commit.
- `scheduler/loop.test.sh` (extended): a loop re-execs itself after a deploy and still owns its running session.

## Changes
1. **`deploy.sh <live checkout>`.** Fetches; if `origin/main` equals `HEAD`, does nothing. Otherwise it checks out `origin/main` in a scratch worktree and runs `make test` there. On a pass it records `HEAD` as the previous commit (`$NOODLEBOT_DATA/deploy/previous`, under the runtime root, not in the checkout), fast-forwards the live checkout and prints `deployed <old>..<new>`. On a failure it prints `not deployed: <sha> fails make test` and records the sha, so it does not retry that commit. It holds `$NOODLEBOT_DATA/deploy/lock`, so two loops never deploy at once. *AC-1, AC-2, AC-4.*
2. **The loop deploys and re-execs.** Once per GitHub tick a loop runs `deploy.sh` for the checkout it runs from; after its tick, a loop whose checkout's `HEAD` differs from the commit it started on replaces itself (`exec`) with the new `loop.sh`, which takes over its running sessions as a restart does. A deploy and a failure are each one status-log event. *AC-1, AC-2.*
3. **Rollback.** `deploy.sh --rollback <live checkout>` resets the live checkout to the recorded previous commit; the loops re-exec at their next tick. *AC-3.*

## Gate
- **D01-AC-1** — A new commit on the scheduler's own `main` that passes `make test` is deployed: the live checkout moves to it, and each loop re-execs within one tick and still owns the sessions it had. *Verify:* `scheduler/deploy.test.sh` and `scheduler/loop.test.sh`.
- **D01-AC-2** — A commit that fails `make test` is not deployed: the live checkout and the loops keep running the old commit, the failure is one status-log event, and the same commit is not tried again. *Verify:* `scheduler/deploy.test.sh` (deploy.sh) and `scheduler/loop.test.sh` (the loops and the status-log event).
- **D01-AC-3** — `deploy.sh --rollback` returns the live checkout to the recorded previous commit. *Verify:* `scheduler/deploy.test.sh`.
- **D01-AC-4** — Two concurrent `deploy.sh` runs deploy at most once (the second waits or skips). *Verify:* `scheduler/deploy.test.sh`.

## Risks
- `make test` takes about a minute and runs on every move of `main`; it shares the machine with node sessions.
- A deploy changes the plugin for sessions that start after it; running sessions keep the skills they loaded.
- A change that passes `make test` but breaks a real loop is deployed; the rollback is the remedy, so the owner needs to notice (the status issue shows each deploy).
