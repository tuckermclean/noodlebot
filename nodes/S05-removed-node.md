# S05 — removed-node

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S01 | none | M |

**Owns:** the removed-node step in `scheduler/loop.sh` (finding a removed node, closing its PR and the issues its spec resolved, stopping its session, removing its worktree and state), the removed-node events in `scheduler/report.py`'s event list, their cases in `scheduler/loop.test.sh` and `scheduler/report.test.sh`.
**Resolves:** #37

## Purpose
After this node the loop tells a node removed from the graph apart from one whose PR was closed. When a merged spec PR takes a node out of `docs/graph.yaml` and deletes its spec, and the loop still has something of that node (an open PR on `node/<ID>-*`, a `state/<name>/node/<ID>` folder or a worktree), it winds the node down: it closes the node's open PR without merging, keeping its branch, with a comment naming the spec PR that removed it; it marks the still-open issues its spec resolved as not planned, with a comment naming the same PR; it stops a running session without holding the node; and it removes the node's worktree and state. A removed node is never started and never held by a FAILED.

## Tests
- `scheduler/loop.test.sh` (extended): the fake `gh` also takes `gh pr close`, `gh pr comment`, `gh issue view` (state) and `gh issue close --reason "not planned"` and records them; the test repository's `main` gets a spec commit, subject ending `(#N)`, that deletes a node's spec and its graph line. Cases: a removed node with an open PR, a state folder and a worktree; one with a running session (a fake `claude` with a child process); one whose PR the owner closed earlier, with only its state left; issues on its Resolves line that are open, already closed, or also resolved by a node still on `main`; an issue reopened after the loop closed it; a failing `gh pr close`; a node missing from the graph whose spec deletion is not in `main`'s history; a node still in the graph whose PR was closed (held as S01 says).
- `scheduler/report.test.sh` (extended): the removed-node events in the status issue's event comment.

## Changes
1. **The loop finds removed nodes.** Each tick, after the PR lists, every node ID the loop has something of (an open PR on `node/<ID>-*`, `state/<name>/node/<ID>`, or the worktree `<ID>` under the repository's worktrees) that is not in `origin/main`'s `docs/graph.yaml` is looked up in `origin/main`'s history: a commit there that deleted `nodes/<ID>-*.md` makes it removed, and the `(#N)` at the end of that commit's subject names the spec PR that removed it (a subject without one: the commit's short hash stands in for it). Without such a commit (or when the graph or the history cannot be read) the node is left as it is. *S05-AC-1, S05-AC-4.*
2. **Its PR is closed.** Each open PR on the removed node's `node/<ID>-*` branch gets one comment naming the node and the spec PR that removed it, and is then closed without merging; its branch is not deleted. One status-log event names the node, the closed PR and the spec PR. *S05-AC-1.*
3. **Its issues are marked not planned.** The issues on the `**Resolves:**` line of the deleted spec (as it was in the deleting commit's parent) that are open and not on the Resolves line of any spec still on `main` each get one comment naming the node and the spec PR that removed it (the reason is in that PR's description), and are closed as not planned. Each issue is handled once: one the owner reopens afterwards stays open. *S05-AC-2.*
4. **It is wound down, not held.** A running session of the removed node is stopped (its process group, as S01 stops one) before its PR is closed, and no FAILED is written for it, in that tick or later. Once its PRs and issues are done, the loop archives `out/node/<ID>` from its worktree under `state/archive/<ID>-out` (as for a merged node), removes the worktree and the node's state folder, and writes one status-log event. Nothing starts it again: it is not in the graph. *S05-AC-3.*
5. **Failures are retried, not fatal.** A failed `gh` call of this step is logged; the rest of the tick carries on, and the step is tried again at the next tick, without repeating a comment or close that already succeeded. *S05-AC-4.*
6. **The status issue shows it.** The removed-node events are among those `report.py` posts to the status issue. *S05-AC-5.*

## Gate
- **S05-AC-1** — Once `origin/main` no longer has a node in `docs/graph.yaml` and its history has the commit (subject ending `(#N)`) that deleted the node's spec, the loop closes the node's open PR on `node/<ID>-*` without merging, its branch kept, after one comment naming the node and PR #N (or the commit, for a subject without `(#N)`); one status-log event names the node, its PR and #N; later ticks neither comment nor close again. *Verify:* `scheduler/loop.test.sh`.
- **S05-AC-2** — Each issue on the deleted spec's Resolves line that is open, and on no Resolves line of a spec still on `main`, gets one comment naming the node and PR #N and is closed as not planned; an issue already closed, or still resolved by a node on `main`, is left alone, and an issue reopened after the loop closed it is not closed again. *Verify:* `scheduler/loop.test.sh`.
- **S05-AC-3** — A removed node is never started and never held: a session running for it is stopped (it and every process in its process group are gone) within one tick, and no FAILED is written for it; its `out/node/<ID>` is kept under `state/archive/<ID>-out`, and its worktree and state folder are removed, with one status-log event; the same cleanup happens for a removed node whose PR the owner closed earlier and that has only state or a worktree left. *Verify:* `scheduler/loop.test.sh`.
- **S05-AC-4** — No PR or issue is closed and nothing is removed for a node missing from the graph whose spec deletion is not in `origin/main`'s history, nor when the graph or the history cannot be read; a node still in the graph whose PR was closed is held as before (S01). A failing `gh` call in this step is logged, does not stop the tick, and the step completes at a later tick without a second comment on a PR or issue it already commented on. *Verify:* `scheduler/loop.test.sh`.
- **S05-AC-5** — The status issue's event comment includes the removed-node events (PR closed, issues marked not planned, worktree and state removed). *Verify:* `scheduler/report.test.sh`.

## Risks
- The comment on an issue only names the spec PR; the reason, and when to reopen, is whatever that PR's description says. A spec PR that removes a node should say both.
- A node removed before the loop ever had anything of it (no PR, no state, no worktree) is not looked at, so the issues on its Resolves line stay open for the owner: scanning all of `main`'s history for deleted specs would also act on nodes removed long before this node.
- The removed node's ID is free again in `docs/graph.yaml`, so triage's `nodes.py` may give it to a new node. Once a node with that ID is in the graph, the loop treats it as that node; its old PR is closed by then, but a branch `node/<ID>-<old name>` remains on GitHub.
- The first deploy acts on issue #11's node T02 (PR #27, its worktree and state), removed by the spec PR that adds this node.
- `scheduler/loop.sh`'s stop paths are also changed by S03 and G01 (open PRs); whichever merges later resolves the conflict.
