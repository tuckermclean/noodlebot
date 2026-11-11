# S01 — stop-closed

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | S03 | M |

**Owns:** the closed-PR query and the stop of a node's session whose PR is merged or closed in `scheduler/loop.sh`, the FAILED line of `scheduler/report.py`'s "Waiting on you" section, their cases in `scheduler/loop.test.sh` and `scheduler/report.test.sh`.
**Resolves:** #10

## Purpose
After this node a node's session does not outlive its PR. When the owner merges a node's PR while its session is still running (waiting for a reviewer, say), the loop stops that session's whole process group within a tick, says so once in the status log, and the merged-worktree cleanup archives its evidence and removes the worktree as it does for any merged node. When the owner closes a node's PR without merging it, the loop stops the session the same way and holds the node with a FAILED marker naming that PR, which keeps its worktree and branch, until the owner deletes the marker.

## Tests
- `scheduler/loop.test.sh` (extended): the fake `gh` also answers `--state closed` (each PR's number, head branch, closed time, and whether it was merged); fake `claude` sessions for further nodes run until stopped and start a child process of their own, so the test can see that the whole group is gone. Cases: a PR merged while its session runs; one closed without merging; a session the loop took over after a restart; a PR closed before the session started; a failing closed-PR query.
- `scheduler/report.test.sh` (extended): a FAILED marker's reason on the status issue.

## Changes
1. **The loop sees closed PRs.** Each GitHub tick also lists the repository's closed PRs with their head branch, closed time and merge state. A failure of that call stops the tick as a failure of the other PR lists does (pipefail: never read as "no PRs"). *S01-AC-5.*
2. **The loop stops a session whose PR is done.** Among the running node sessions (from `node/<ID>/session.pid`, so also those taken over after a restart), one whose node is merged, or whose node has no open PR and a PR on its `node/<ID>-*` branch closed without merging after the session started, is stopped: SIGTERM to its process group, SIGKILL after a short grace if anything remains. The tick waits until the group is gone, writes one status-log event (the node, the PR and the stop), and then reaps it through the usual end-of-session path; the event is not repeated on later ticks. *S01-AC-1, S01-AC-2, S01-AC-3.*
3. **A closed PR holds its node.** For a PR closed without merging, the loop writes the node's FAILED marker, whose first line names the closed PR and says that deleting the file starts the node again, and sets its starts to 0, so it is not started again until the owner deletes FAILED, and then gets 2 fresh starts. Its worktree and branch stay. *S01-AC-2.*
4. **The merged case ends as any merged node.** After the stop, `cleanup_merged` archives `out/node/<ID>` under `state/archive/<ID>-out` and removes the worktree in the same tick or the next. *S01-AC-1.*
5. **The status issue shows why a node is held.** The "Waiting on you" item for a FAILED marker gives the marker's first line as its reason (instead of a fixed text) and the path to delete. *S01-AC-4.*

## Gate
- **S01-AC-1** — A node whose PR is merged while its session runs has that session stopped within one tick: the session and every process in its process group are gone, one status-log event names the node and the merged PR (not repeated on later ticks), and its evidence is archived to `state/archive/<ID>-out` and its worktree removed. The same holds for a session the loop took over after a restart. *Verify:* `scheduler/loop.test.sh`.
- **S01-AC-2** — A node whose PR is closed without merging while its session runs has that session's process group stopped within one tick, with one status-log event; its FAILED marker names the closed PR, its worktree and branch remain, and it is not started on later ticks. After FAILED is deleted it starts again at the next tick, as start 1 of 2. *Verify:* `scheduler/loop.test.sh`.
- **S01-AC-3** — A session is not stopped for a PR on its node's branch that was closed before the session started, nor while its node also has an open PR; nodes without a running session are handled as before. *Verify:* `scheduler/loop.test.sh`.
- **S01-AC-4** — The status issue's item for a FAILED node gives the reason from the first line of its FAILED file and the path to delete to release it. *Verify:* `scheduler/report.test.sh`.
- **S01-AC-5** — When listing closed PRs fails, the tick stops no session and starts none, and logs the failure. *Verify:* `scheduler/loop.test.sh`.

## Risks
- A stopped session loses work in progress. For a merged node nothing of it is needed; for a closed one, uncommitted changes stay in the kept worktree.
- Processes a session started outside its process group (a podman container, for instance) are not stopped with it (unverified for real sessions).
- A PR closed while no session runs is not held: the node starts again at the next tick, as before this node. Issue #10 asks only about running sessions.
- Reopening a closed PR does not release the hold; the owner deletes FAILED as well.
- `gh pr list --state closed` also lists merged PRs (they are told apart by their merge state), and like the other lists it reads at most 500 PRs, so a repository with more could miss a recently closed one.
