# noodlebot

Automation that runs as the n00dl3b0t GitHub App (credentials in `~/.config/noodlebot/`, never in this repo).

- `scheduler/`: the v0 node scheduler for tuckermclean/themonolith. `scheduler/loop.sh` explains how to run it.
- `make test`: the ready-node, release-markers, status-issue and end-to-end loop tests.
- The loop reacts within seconds to local changes (your `ANSWER.md`, a session ending) and checks
  GitHub every 60 s (PR merges). Only one loop runs at a time. Sessions run detached, so stopping or
  restarting the loop never stops a session; a restarted loop takes over the running one.

## Watching it: the status issue

Each repository gets one open issue labelled `noodlebot-status` (`scheduler/report.py`, run by the loop
after each 60 s tick). Its body shows what waits on you, the running session with the orchestrator's latest
narration and the active subagent, and recent events. Each start, end (with the session's closing
summary), release, merge and question is a comment, so GitHub notifies you. It is disposable: close it
and the loop opens a new one. Its failures go to `state/<repo>/report.log` and never stop the loop.
Nothing in it is specific to one repository: `report.py --repo OWNER/NAME --state DIR`.

## Answering a node's question

Reply to the status issue in plain words. Only the repository owner's comments count; if more than one
node is waiting, start with its ID (`B03: ...`). The reply becomes that node's `ANSWER.md`.
Or, locally:

A session that hits a `/node` step 7 stop writes `state/<repo>/node/<ID>/QUESTION.md` and ends; the
node is held. To answer, write `ANSWER.md` next to it, in plain words ("Q1 approve, Q2 as
recommended"). Within seconds the loop moves both into `answered/`, gives the node 2 fresh starts
and starts it again. The session reads every answer in `answered/` and carries on.

If your answer approves a spec change, the session opens a `spec/<ID>-*` PR, writes its number to
`WAITING-PR` and ends. Merge that PR; within a minute the node starts again on the new spec.
`scheduler/status.sh` shows which of these each node is waiting for.
- `repos/`, `worktrees/` and `state/` are runtime directories and are ignored by git.
