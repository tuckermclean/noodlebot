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
each starting with a `**Stage:**` line (a start or resume, a question, an answer received, the PR opened,
the CI result per pushed head commit, the fresh-review verdicts, merged or closed without merging, FAILED;
a triage's done). The home issue of a triage is the issue itself; of a node, the first issue on the
**Resolves:** line of its spec, and a node with none gets a new "Build <ID> <name>" issue labelled
`noodlebot-unit`. The PRs only say `Refs #N`; the loop closes an issue once every node
resolving it is merged and no unit whose home it is has a question open (or answered but not yet released) or a
follow-up in progress, and reopens it when a unit whose home it is asks a new question. A question shows on the status issue
as a short pointer to its comment on the home issue.

## API

An HTTP API over the runtime files, for dashboards and scripts (reads, and the controls below): `scheduler/api.py`, on the Unix socket
`$NOODLEBOT_DATA/api.sock` (default `~/.local/share/noodlebot/api.sock`, mode 0600, so only you can use it).
`scheduler/loops.sh start` and `stop` start and stop it with the loops (tmux session `sched-api`); `status` shows it.
Every request is a GET or one of the controls below (any other write is a 405); every answer is JSON with `"version": 1`.

- `/v1/repos`, `/v1/repos/<owner>/<name>`: the listed repositories and one in full.
- `/v1/repos/<owner>/<name>/nodes`, `.../nodes/<ID>`, `.../sessions`, `.../prs`, `.../issues`.
- `/v1/throttle`, `/v1/deploy`: the usage throttle and the last deploy.
- `/v1/schema/<resource>`: the JSON schema of a resource.
- `/v1/events`: a `text/event-stream` (not JSON) of events, each a line appended to a repository's `status.log`. `?repo=<owner>/<name>` limits it to one repository;
  `?since=<cursor>` (or the `Last-Event-ID` header, which a browser's EventSource sends on reconnecting)
  resumes after the event with that id, with a cursor per repository.

    curl --unix-socket ~/.local/share/noodlebot/api.sock http://localhost/v1/repos

### Controls

A control writes only a marker the loop or `deploy.sh` already reads, and a request record in
`state/<name>/requests/`; the loop logs each record as one status-log event and removes it. The API starts no loop and
signals no process. A valid request is answered 202 (schema `control`: what was written and when it is carried out), an
unknown repository, node, issue or commit 404, a request with nothing to do 409; neither changes any file. Anyone who can
use the socket can use the controls.

- Delete a node's or an issue's `FAILED` (the loop starts a ready node at its next tick):

      curl --unix-socket ~/.local/share/noodlebot/api.sock -X DELETE http://localhost/v1/repos/<owner>/<name>/nodes/<ID>/failed
      curl --unix-socket ~/.local/share/noodlebot/api.sock -X DELETE http://localhost/v1/repos/<owner>/<name>/issues/<N>/failed

- Stop a repository's loop (creates `~/STOP-<name>`; a running loop exits) and allow it again (removes it):

      curl --unix-socket ~/.local/share/noodlebot/api.sock -X PUT http://localhost/v1/repos/<owner>/<name>/stop
      curl --unix-socket ~/.local/share/noodlebot/api.sock -X DELETE http://localhost/v1/repos/<owner>/<name>/stop

  Removing the STOP file does not start the loop: `scheduler/loops.sh start` does.
- Let one node the throttle holds start once (writes `RELEASE`; the loop consumes it at its next tick and logs what it did):

      curl --unix-socket ~/.local/share/noodlebot/api.sock -X POST http://localhost/v1/repos/<owner>/<name>/nodes/<ID>/release

- Retry a commit `deploy.sh` rejected (writes `deploy/retry`; a 409 if it is not rejected):

      curl --unix-socket ~/.local/share/noodlebot/api.sock -X POST -d '{"sha": "<commit>"}' http://localhost/v1/deploy/retry

- Request a rollback to `deploy/previous` (writes `deploy/rollback-request`; a 409 if there is no rollback point):

      curl --unix-socket ~/.local/share/noodlebot/api.sock -X POST http://localhost/v1/deploy/rollback

The loop carries out the first four at its next iteration or tick; `deploy.sh` carries out the retry and the rollback at
its next run, which a loop makes, and logs a line for each.

From another machine, forward the socket over SSH and use it there:

    ssh -L /tmp/nb.sock:/home/<user>/.local/share/noodlebot/api.sock host
    curl --unix-socket /tmp/nb.sock http://localhost/v1/repos

If `/tmp/nb.sock` is left over from an earlier forward, set `StreamLocalBindUnlink yes` (in `ssh_config`, or `-o`).

## Answering a node's question

Reply on the unit's issue (the home issue where the loop posted the question), in plain words. Only the repository
owner's comments count. No prefix is needed: your comment answers the one question open there, gets a +1
and becomes that unit's `ANSWER.md` (a triage's too). Only if several questions are open on that issue, start with the ID
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
