# noodlebot

Automation that runs as the n00dl3b0t GitHub App (credentials in `~/.config/noodlebot/`, never in this repo).

- `scheduler/`: the node scheduler, one loop per repository:
  `tmux new -d -s sched-<name> ~/gitrepos/noodlebot/scheduler/loop.sh <owner/name>` (default
  tuckermclean/themonolith, in tmux session `sched`). Each repository has its own lock, state
  (`$NOODLEBOT_DATA/state/<name>/`), clone, worktrees and status issue; `touch ~/STOP` stops every loop,
  `touch ~/STOP-<name>` one. `scheduler/status.sh [owner/name]` shows one repository.
- `plugin/`: the bot's Claude Code skills, generic over repositories in the graph regime
  (`docs/graph.yaml` + `nodes/<ID>-<name>.md`); load with `claude --plugin-dir ~/gitrepos/noodlebot/plugin`.
  `/noodlebot:node <ID>` builds a node test-first (the repository's part comes from its AGENTS.md,
  "Building a node"); `/noodlebot:triage <issue> [--dry-run]` fits an issue into the graph as a spec PR.
- `make test`: the ready-node, release-markers, status-issue, issue-label and end-to-end loop tests.
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

## Handing an issue to the bot

Add the `noodlebot` label to an issue. Only labels the repository owner adds count (the loop checks
who added it, `scheduler/issues.py`). When no session is running, the loop triages it first
(`/noodlebot:triage <N>`, state in `state/<repo>/issue/<N>/`): the result is a spec PR that fits the
issue into the graph, or a comment that answers it. Then the label becomes `noodlebot-triaged`.
Merge the spec PR and the new or amended node is built like any other. A triage question shows on
the status issue; answer it with `#<N>: ...`.

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
- `repos/`, `worktrees/` and `state/` are runtime directories under the runtime root `$NOODLEBOT_DATA`
  (default `~/.local/share/noodlebot`), outside any checkout. Every loop, `status.sh` and
  `move-runtime.sh` must see the same `NOODLEBOT_DATA`.
- One-time move of an older installation (runtime folders inside the checkout): `touch ~/STOP`, wait
  until no session runs, run `scheduler/move-runtime.sh ~/gitrepos/noodlebot`, start the loops again.
