# noodlebot

Automation that runs as the n00dl3b0t GitHub App (credentials in `~/.config/noodlebot/`, never in this repo).

- `scheduler/`: the node scheduler, one loop per repository. `scheduler/loops.sh start|stop|status`
  runs them all over the repositories in `~/.config/noodlebot/repos` (one `owner/name` per line,
  `#` comments allowed): `start` starts the loops not running, `stop` stops them via `~/STOP-<name>`
  (sessions keep going), `status` prints a line per repository. It reads each loop's lock, sessions and
  markers under the runtime root `$NOODLEBOT_DATA` (default `~/.local/share/noodlebot`), and `start`
  passes that root, and every `USAGE_*` and `SCHED_*` variable set in its environment (for example `USAGE_7D_PACE=1 scheduler/loops.sh start`, which turns on the 7-day pace hold), to each loop, since a tmux server keeps its own environment. `start` refuses while
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

## Watching it: the daily log

Each repository gets one log issue a day, "noodlebot log <date>", labelled `noodlebot-status`
(`scheduler/report.py`, run by the loop after each 60 s tick). Its first comment is the morning overview;
its body is the status table (what waits on you, the running sessions with the latest narration, usage, the
deployed commit); each start, end (with its total cost), release, merge and question is one line in its
comments, so GitHub notifies you. At the first run on a new date it posts the day's summary on the old issue,
closes it, opens the new one, links the two and tries to pin the new one. Closing today's issue is fine: the
loop opens another. The open ones are here:
[open `noodlebot-status` issues](https://github.com/tuckermclean/noodlebot/issues?q=is%3Aissue+label%3Anoodlebot-status+is%3Aopen).
Its failures go to `$NOODLEBOT_DATA/state/<repo>/report.log` and never stop the loop.
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

## Status site

The loop can publish a status site for the repositories it watches. The files are sent to a public gist you make once by hand;
the publisher never creates a gist.

1. Create a public gist (any file will do; it is replaced by the first publish) and note its ID, the last part of its URL.
2. Make a token that can only touch gists: a classic token with only the `gist` scope, or a fine-grained token with only
   the Gists account permission (read and write).
3. Put the ID in `~/.config/noodlebot/gist` and the token in `~/.config/noodlebot/gist-token`, both mode 0600.
   An optional `~/.config/noodlebot/repos` lists the repositories to show, one `owner/name` per line (default: the loop's own).

With either file missing the loop says `site off: no gist configured` once at start and publishes nothing. `SCHED_SITE=0`
turns the publishing off. The token goes only to the publish command, never to a session; a failed publish is one status
line (`site: publish failed (<status>)`), the details are in `state/<name>/site.log`, and `site: publishing again` follows
the next success.

Links to the site: put its address on one line in `~/.config/noodlebot/site`, e.g. `https://<owner>.github.io/noodlebot/`.
While that is a valid `https://` address (no spaces, quotes, parentheses or angle brackets), the loop publishes the site and the
repository is public, the bot's status issue and its GitHub comments link each node's ID to the site. Otherwise the texts have
no links; an invalid address is one status line (`status site links off: <reason>`).

The front end in `site/` is a static page that reads the gist from the browser; `.github/workflows/pages.yml` deploys it to
GitHub Pages when `site/**` changes on `main` (or by hand, with `workflow_dispatch`). To enable it:

1. In the repository's Settings, Pages, set the source to GitHub Actions.
2. In Settings, Secrets and variables, Actions, Variables, add the repository variable `NOODLEBOT_GIST_ID` with the gist's ID.
   The workflow writes it to `site/config.json` and fails with a message while it is unset.

The page also takes `?gist=<id>`, which wins over `config.json`.

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

A control writes only a marker the loop or `deploy.sh` already reads, and, for the loop controls, a request record in
`state/<name>/requests/`; the loop logs each record as one status-log event and removes it. A deploy request (retry,
rollback) writes no record: the marker in `deploy/` is the request. The API starts no loop and signals no process. A
valid request is answered 202 (schema `control`: what was written and when it is carried out), an unknown repository,
node, issue or commit 404, a request with nothing to do 409; neither changes any file. Anyone who can use the socket can
use the controls.

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

The loop carries out the first three at its next iteration or tick; `deploy.sh` carries out the retry and the rollback at
its next run, which a loop makes, and logs a line for each.

From another machine, forward the socket over SSH and use it there:

    ssh -L /tmp/nb.sock:/home/<user>/.local/share/noodlebot/api.sock host
    curl --unix-socket /tmp/nb.sock http://localhost/v1/repos

If `/tmp/nb.sock` is left over from an earlier forward, set `StreamLocalBindUnlink yes` (in `ssh_config`, or `-o`).

### The command line: `scheduler/nbctl.py`

`scheduler/nbctl.py` is a client of the socket (Python standard library only). It reads no state file, calls no `gh` and
needs no token, so it works over the forwarded socket too. It uses `$NOODLEBOT_DATA/api.sock`, or the path given with
`--socket` (before the command). When nothing listens there, it says so in one line and exits 2: start the API with
`scheduler/loops.sh start`.

    scheduler/nbctl.py status                  # the throttle and the deploy, then one line per repository
    scheduler/nbctl.py status <owner/name>     # one repository in detail
    scheduler/nbctl.py events [--repo <owner/name>] [--since <cursor>]   # follow the events, one line each
    scheduler/nbctl.py get repos/<owner>/<name>/prs   # the JSON of /v1/<path>; exit 0 for 200, 1 for 404, 2 otherwise

`nbctl.py status <owner/name>` replaces `scheduler/status.sh`: it shows the loop and STOP files, the last GitHub check, the
status issue and the throttle, each running session (pid, age, log size, last write, last 4 actions, a node's commits,
pending wakeup, background work, limit rejection), what waits on you (FAILED with its reason, QUESTION with its first line and
the issue to answer on, answered, spec PRs), each node's state and the open PRs with their mergeable state. Keep it open next
to htop with `watch -n 10 scheduler/nbctl.py status <owner/name>`. `status.sh` stays for now.

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
