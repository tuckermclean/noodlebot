# noodlebot

Automation that runs as the n00dl3b0t GitHub App (credentials in `~/.config/noodlebot/`, never in this repo).

- `scheduler/`: the node scheduler, one loop per repository. `scheduler/loops.sh start|stop|status`
  runs them all over the repositories in `~/.config/noodlebot/repos` (one `owner/name` per line,
  `#` comments allowed): `start` starts the loops not running, `stop` stops them via `~/STOP-<name>`
  (sessions keep going), `status` prints a line per repository. It reads each loop's lock, sessions and
  markers under the runtime root `$NOODLEBOT_DATA` (default `~/.local/share/noodlebot`), and `start`
  passes that root to each loop, since a tmux server keeps its own environment. `start` refuses while
  `~/STOP` exists and removes a stale `~/STOP-<name>`; it also refuses while a loop from before the
  runtime move still holds `<checkout>/state/<name>/loop.lock`: stop it and run the move first
  (`scheduler/move-runtime.sh`, below). The mechanism underneath, per repository:
  `tmux new -d -s sched-<name> env NOODLEBOT_DATA=<root> ~/gitrepos/noodlebot/scheduler/loop.sh <owner/name>`.
  Each repository has its own lock, state (`$NOODLEBOT_DATA/state/<name>/`), clone, worktrees and
  status issue; `touch ~/STOP` stops every loop, `touch ~/STOP-<name>` one. `scheduler/status.sh [owner/name]` shows one repository.
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
and the loop opens a new one. Its failures go to `$NOODLEBOT_DATA/state/<repo>/report.log` and never stop the loop.
Nothing in it is specific to one repository: `report.py --repo OWNER/NAME --state DIR`.

## Handing an issue to the bot

Add the `noodlebot` label to an issue. Only labels the repository owner adds count (the loop checks
who added it, `scheduler/issues.py`). When no session is running, the loop triages it first
(`/noodlebot:triage <N>`, state in `$NOODLEBOT_DATA/state/<repo>/issue/<N>/`): the result is a spec PR that fits the
issue into the graph, or a comment that answers it. Then the label becomes `noodlebot-triaged`.
Merge the spec PR and the new or amended node is built like any other.

Each issue the bot works on is its unit's home: the loop posts that unit's milestones there as comments,
each starting with a `**Stage:**` line (a start or resume, a question, an answer received, the PR and its
CI, FAILED, triage done). The home issue of a triage is the issue itself; of a node, the first issue on the
**Resolves:** line of its spec, and a node with none gets a new "Build <ID> <name>" issue labelled
`noodlebot-unit`. The PRs only say `Refs #N`; once the nodes that resolve an issue are merged, the loop
closes it, and reopens it if you add the `noodlebot` label again. A question shows on the status issue
as a short pointer to its comment on the home issue.

## Answering a node's question

Reply on the unit's issue (the home issue where the loop posted the question), in plain words. Only the repository
owner's comments count. No prefix is needed: your comment answers the one question open there, gets a +1
and becomes that node's `ANSWER.md`. Only if several questions are open on that issue, start with the ID
(`B03: ...`). You can also still reply on the status issue (start with the ID, or `#<N>:` for a triage
when more than one is waiting). A question is answered once, from whichever issue you replied on.
Or, locally:

A session that hits a `/node` step 7 stop writes `$NOODLEBOT_DATA/state/<repo>/node/<ID>/QUESTION.md` and ends; the
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
