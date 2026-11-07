# noodlebot

Automation that runs as the n00dl3b0t GitHub App (credentials in `~/.config/noodlebot/`, never in this repo).

- `scheduler/`: the v0 node scheduler for tuckermclean/themonolith. `scheduler/loop.sh` explains how to run it.
- `make test`: the ready-node, release-markers and end-to-end loop tests.
- The loop reacts within seconds to local changes (your `ANSWER.md`, a session ending) and checks
  GitHub every 60 s (PR merges). Only one loop runs at a time. Sessions run detached, so stopping or
  restarting the loop never stops a session; a restarted loop takes over the running one.

## Answering a node's question

A session that hits a `/node` step 7 stop writes `state/<repo>/node/<ID>/QUESTION.md` and ends; the
node is held. To answer, write `ANSWER.md` next to it, in plain words ("Q1 approve, Q2 as
recommended"). Within seconds the loop moves both into `answered/`, gives the node 2 fresh starts
and starts it again. The session reads every answer in `answered/` and carries on.

If your answer approves a spec change, the session opens a `spec/<ID>-*` PR, writes its number to
`WAITING-PR` and ends. Merge that PR; within a minute the node starts again on the new spec.
`scheduler/status.sh` shows which of these each node is waiting for.
- `repos/`, `worktrees/` and `state/` are runtime directories and are ignored by git.
