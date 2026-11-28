# noodlebot

**noodlebot turns a written plan for a piece of software into working, tested code, while you do something else.**
You decide what gets built and approve every change. AI agents do the building, around the clock.

## Why you'd want it

Building software is mostly a long list of small jobs: add this feature, fix that, make this faster. Each job is quick
to describe but takes hours of someone's careful work. AI coding agents can now do much of that work, but used directly
they need a person beside them, starting each task, watching it, and checking the result. The person becomes the
bottleneck again.

noodlebot removes that babysitting. You write the plan once, as a list of small jobs, each with a description and a
check that proves it is done. From then on, noodlebot runs on its own:

- **It works through the list by itself**, day and night. It starts a job as soon as the jobs it depends on are
  finished, runs several at once, and picks up where it left off after an interruption.
- **Every result waits for your approval.** A finished job arrives as a *pull request*: a proposed change you can read,
  comment on, and accept or turn down. Nothing becomes part of the project until you accept it. When a job needs a
  decision only you can make, it stops and asks you in plain words, and carries on once you answer.
- **The work checks itself.** Each job writes its tests first (small programs that prove the job is done), builds
  until they pass, and is reviewed by a second agent before it reaches you. Every pull request is tested again
  automatically, and you see the result.
- **It keeps you informed.** One short log a day, as a GitHub issue, says what started, what finished, what it cost
  and what is waiting on you, and GitHub notifies you of each step.
- **It stays within your AI plan.** It watches your usage and stops starting new work before you hit your limit, so
  you can still use your AI yourself.

You spend your time on the decisions only you can make, not on typing code or minding agents.

## How it works

The plan lives in the project itself, as a set of short documents. Each document describes one job (a *node*): what
it must do, how to check it, and which other nodes it depends on. noodlebot then repeats one cycle:

1. **Pick.** It finds every node whose dependencies are finished.
2. **Build.** It starts an AI session on each one, in its own private copy of the project.
3. **Hand over.** The session either opens a pull request with the finished, tested work, or asks you a question.
4. **You decide.** You answer the question or review the pull request. To accept it, you *merge* it.
5. **Repeat.** Your merge finishes that node, which may unlock others, and the cycle carries on.

New ideas don't need a full plan. Label an ordinary GitHub issue `noodlebot`, and it drafts the new node for you to
approve. One machine can do this for several projects at once. noodlebot is built this way itself: its own plan is in
`docs/graph.yaml` and `nodes/`.

## What you'll need

- A **GitHub** repository for each project, and a **GitHub App** for noodlebot to act as (here, `n00dl3b0t`).
  The App can propose changes but never accept them.
- An **AI plan** for the agents (it runs Claude Code sessions today).
- A **Linux machine** that stays on, or a container host ([Setting it up](#setting-it-up)).
- **The plan:** a `docs/graph.yaml` and a `nodes/` folder in the project. For a project without one, the
  `/noodlebot:adopt` skill drafts it from the code and your answers.

The rest of this page is for running it. How noodlebot is built is in [`SPEC.md`](SPEC.md) (design) and
[`AGENTS.md`](AGENTS.md) (working on its code).

## Your part, day to day

| Something to do | Where you see it | What you do |
|---|---|---|
| A node has a **question** | a comment on the node's issue, and a line in the daily log | Reply on that issue in plain words ([Answering a question](#answering-a-question)). |
| A **node PR** is ready (finished work) | a pull request on a `node/<ID>-<name>` branch | Review it. Comment to have the bot change it; merge it when it's right. |
| A **spec PR** is ready (a change to the plan) | a pull request on a `spec/...` branch, from a question or a labelled issue | Merge it, and the node is built (again) to the new plan. |
| You want **something new built** | | Label an issue `noodlebot` ([Handing an issue to the bot](#handing-an-issue-to-the-bot)). |
| A node is **FAILED** (it gave up) | the daily log, `nbctl.py status` | Read why, fix the cause, delete the marker ([Troubleshooting](#troubleshooting)). |

noodlebot does everything else by itself: it starts sessions, resumes them after a usage limit or a restart, updates
pull requests that clash with newer work, and installs its own updates.

## Watching it: the daily log

Each repository gets one log issue a day, "noodlebot log <date>", labelled `noodlebot-status`:
[open `noodlebot-status` issues](https://github.com/tuckermclean/noodlebot/issues?q=is%3Aissue+label%3Anoodlebot-status+is%3Aopen).

- Its **body** is the status table: what waits on you, the running sessions with their latest narration, usage and the
  deployed commit.
- Its **comments** are the day: the morning overview first, then one line per start, end (with its cost), release,
  merge and question, so GitHub notifies you.
- At the first run on a new date the loop posts the day's summary on the old issue, closes it, opens the new one, links
  the two and tries to pin the new one. Closing today's issue yourself is fine: the loop opens another.

`scheduler/report.py` writes it after each 60 s tick. Its failures go to `state/<name>/report.log` and never stop the
loop.

From a terminal:

    scheduler/nbctl.py status                # throttle, deploy, one line per repository
    scheduler/nbctl.py status <owner/name>   # one repository: sessions, what waits on you, nodes, open PRs
    watch -n 10 scheduler/nbctl.py status <owner/name>
    scheduler/nbctl.py events                # follow the events as they happen

## Answering a question

A session that needs a decision stops, and the loop posts the question as a comment on the unit's **home issue**. For
a node that is the first issue on its spec's **Resolves:** line, or a "Build <ID> <name>" issue labelled `noodlebot-unit`
that the loop opens for it; for a triage it is the labelled issue itself. A new question reopens a closed home issue.

- **Reply on that issue in plain words** ("Q1 approve, Q2 as recommended"). Only the repository owner's comments count.
  Your comment gets a +1 and becomes the unit's answer within about a minute (the next GitHub check). The node then
  starts again with 2 fresh starts, at its turn in the start queue and unless the throttle holds, and reads every
  answer so far. A local `ANSWER.md` (below) is taken within seconds.
- If several questions are open on the same issue, start with the ID (`B03: ...`). You can also reply on the daily log
  issue, starting with the ID (or `#<N>:` for a triage).
- **Locally**, write `ANSWER.md` next to the question:
  `$NOODLEBOT_DATA/state/<name>/node/<ID>/QUESTION.md` → `.../ANSWER.md`. Write it to a temporary name and `mv` it into
  place, so the loop never reads half a file.

If your answer approves a spec change, the session opens a `spec/<ID>-*` PR and the node waits for it. Merge the PR and
the node starts again on the new spec at its next turn (the log says so when it has to wait).

## Reviewing and merging PRs

- **The owner sets the rules and merges the plan.** Bots never push to `main`, change branch protection or repository
  settings, or merge a spec or adoption PR. Only the reviewer App may approve or request changes on a PR, and only for
  the exact head it reviewed. A node PR is merged by the forge's own auto-merge, under the branch protection the owner
  sets, once the auto-gate holds at its head (the reviewer App's approval at that head is one of its points); the loop
  only turns auto-merge on. Spec and adoption PRs, and approvals of frozen-test changes, stay the owner's alone. Every
  result reaches the owner as a PR, a comment or a question.
- **Until the auto-gate is built** (issue #175), you merge node PRs too (squash), as you merge spec and adoption PRs.
- **Comment or review on a bot PR** to have it changed: the loop collects your comments and reviews and starts a feedback
  session for that PR, which pushes the change and replies.
- A node PR that conflicts with `main` gets an update session by itself.
- On a node PR, each pushed head gets its CI result and a fresh review's verdict as comments on the node's home issue.
- A merged node closes its home issue once every node resolving it is merged and nothing on it is still open.

## Handing an issue to the bot

Add the `noodlebot` label to an issue. Only labels the repository owner adds count. The loop triages it when no other
triage runs (`/noodlebot:triage <N>`): the result is a **spec PR** that fits the issue into the graph, or a **comment** that
answers it, and the label becomes `noodlebot-triaged`. Merge the spec PR and the new or amended node is built like any
other.

## Controlling it

| To | Run |
|---|---|
| Start every loop (and the API) | `scheduler/loops.sh start` |
| See them | `scheduler/loops.sh status` |
| Restart dead loops on a timer | `scheduler/loops.sh watch-unit` prints a systemd service and timer for `loops.sh watch` and the commands that install them; you run those once per machine |
| Stop every loop | `scheduler/loops.sh stop`, or `touch ~/STOP` (sessions keep running) |
| Stop one repository's loop | `touch ~/STOP-<name>` |
| Let a FAILED node or issue start again | `rm` its `FAILED`, or the API's `DELETE .../failed` ([API](#api)) |
| Start one node the throttle holds | `POST .../nodes/<ID>/release` ([API](#api)) |
| Retry a rejected deploy, or roll back | `POST /v1/deploy/retry`, `POST /v1/deploy/rollback` ([API](#api)) |

- **`loops.sh watch`** (run by that timer) restarts a dead loop and the API with the settings of the last `loops.sh start`,
  never after `loops.sh stop` or while a STOP file exists. A loop that is running but whose heartbeat is older than
  `LOOPS_STALE` seconds (default 1800) is not signalled: `watch` notes it in `state/watch.log` and comments once on the log
  issue. `LOOPS_WATCH_EVERY` (default `5min`) is how often the printed timer runs `watch`.
- With `~/.config/noodlebot/units` and `systemctl --user` answering, `start` also sets up a transient user timer
  `noodlebot-watch` that runs `loops.sh watch` every `LOOPS_WATCH_EVERY`, with the `NOODLEBOT_DATA` and `PATH` of that
  `start`, unless it is already active. `stop` stops it. `status` then has one more line naming the active watch timers
  (system, user or none). The system timer from `watch-unit` also survives the end of the user manager.
- After the deploy that brings this, run `loops.sh stop` and `loops.sh start` once so `state/loops.env` is recorded: a loop started by an older `start` left no settings, and `watch` restarts it without them.
- **Stopping a loop never stops a session.** Sessions run detached; a restarted loop takes over the running ones.
- `start` starts the loops that are not running and removes a stale `~/STOP-<name>`; it refuses while `~/STOP` exists.
- Loops run in tmux sessions `sched-<name>` (the API in `sched-api`). Use `loops.sh`, not tmux, to start and stop them.
- With `~/.config/noodlebot/units`, `start` and `status` also check lingering (`loginctl show-user`, read only) and says so when it is off:
  a logout then stops the loops and the API; `loginctl enable-linger <user>` (run by you, never by `loops.sh`) keeps them.
  Without the file, `start` prints one line saying the loops run in the calling shell's session.
- A forge that lacks a feature the loop uses (the site, pinning, resolving threads, visibility) gets one status line
  per loop start, `forge <name> lacks <capability>: <feature> off`, and that feature is skipped.
- Only one loop runs per repository (a lock in its state folder). Each repository has its own lock, state, clone,
  worktrees and log issue.

## Setting it up

You need: Linux, bash, git, gawk, python3 with PyYAML, `gh`, tmux, Node, the Claude Code CLI, and podman if the
repositories' builds use containers. Or run [the container](#running-it-in-a-container), which has all of it.

1. Clone noodlebot to `~/gitrepos/noodlebot`. This checkout is the **live checkout** the loops run from and deploy into:
   don't work in it.
2. Fill the config folder `~/.config/noodlebot/` (never part of any repository):

   | File | What it is | Needed |
   |---|---|---|
   | `repos` | The repositories to build, one `[<forge>:]<path>` per line (`owner/name` means `github:owner/name`), `#` comments allowed. | yes |
   | `token` | An executable that prints a GitHub App installation token for the repository it's given (`token owner/name`). | yes |
   | `oauth-token` | The Claude Code credential the sessions use. | yes |
   | `gitconfig` | Git identity for the container's sessions' commits. | container only |
   | `units` | Present (its contents do not matter): `loops.sh start` runs the tmux server in a systemd user unit, `noodlebot-loops`, so the loops outlive the login session. Without a user manager or without the file the loops run in the calling shell's session. | no |
   | `deploy-ci` | Deploy on CI instead of local tests ([How it deploys itself](#how-it-deploys-itself)). | no |
   | `gist`, `gist-token`, `site` | The status site ([Status site](#status-site)). | no |

3. `scheduler/loops.sh start`, then `scheduler/loops.sh status`.

At its first start in a repository the loop creates the labels `noodlebot`, `noodlebot-triaged`, `noodlebot-status` and
`noodlebot-unit`.

### Tuning

Set these in the environment of `scheduler/loops.sh start`; it passes them to each loop (`USAGE_*`, `SCHED_*`, `PICKUP*`
and `NOODLEBOT_DATA`), for example `USAGE_7D_PACE=0 scheduler/loops.sh start`. Only loops that `start` launches get
them: a running loop keeps its settings, so `scheduler/loops.sh stop` first, then start with the new ones.

| Variable | Default | What it does |
|---|---|---|
| `NOODLEBOT_DATA` | `~/.local/share/noodlebot` | The runtime root ([Where things are](#where-things-are)). Every loop and tool must see the same one. |
| `USAGE_5H_LIMIT` | `0.90` | **The throttle:** no new session starts while the 5-hour usage window is projected to pass this by its reset. Running sessions are never stopped. |
| `USAGE_7D_PACE`, `USAGE_7D_MARGIN` | `1` (on), `0.10` | The throttle also holds while the 7-day window is more than the margin ahead of pace; `USAGE_7D_PACE=0` turns that weekly pace hold off. |
| `SCHED_MAX` | `0` (no cap) | The most sessions a loop runs at once. |
| `SCHED_RAMP`, `SCHED_START_GAP` | `1`, the tick | The start queue: new sessions start one per gap across all loops (triages, updates and resumes first). `SCHED_RAMP=0` starts every ready unit at once. |
| `SCHED_STARVE` | `21600` | A unit waiting longer than this (seconds) goes first. |
| `SCHED_TICK`, `SCHED_POLL` | `60`, `2` | Seconds between GitHub checks, and between local checks. |
| `SCHED_HARNESS` | `claude-code` | The agent harness the sessions run in. |
| `SCHED_THROTTLE`, `SCHED_REPORT`, `SCHED_SITE` | `1` | `0` turns off the throttle, the daily log, the status site. |
| `PICKUP`, `PICKUP_RUNS`, `PICKUP_CEILING` | `1`, `12`, `90%` | The small-model step that places owner comments the log can't: on or off, runs per 5-hour window, no run above this usage. |

## How it deploys itself

Each loop tick runs `scheduler/deploy.sh`, which brings new commits on noodlebot's `main` into the live checkout:

- A change to docs, specs or workflows only (`README.md`, `SPEC.md`, `AGENTS.md`, `CLAUDE.md`, `docs/`, `nodes/`, `.github/`) is
  fast-forwarded at once, with no check and no restart.
- A runtime change is checked first, then fast-forwarded, and every loop restarts itself on the new code, keeping its
  running sessions. A commit that fails its check is **rejected**: one status line, and the old code keeps running.
- **The check** is local `make test`, unless `~/.config/noodlebot/deploy-ci` holds a line
  `<owner/name> <workflow file> <branch>` (for example `owner/repo test.yml main`; a malformed line deploys nothing).
  That line names the CI to trust instead: the
  deploy waits for that workflow's push run on the commit, deploys after it passes (and a short local syntax check),
  and rejects the commit when it fails. The App behind `token` must be able to read that repository's Actions.
- Each runtime deploy records the commit it replaced as the rollback point.

`nbctl.py status` shows the deployed commit, the rollback point, the rejected commits and the last failure;
`GET /v1/deploy` also has the last deploy. To retry a rejected commit (for example after re-running its CI) or to roll back, use the deploy controls of
the [API](#api); `deploy.sh` carries them out at its next run. Its log is `state/<name>/deploy.log`.

## Troubleshooting

| You see | It means | Do |
|---|---|---|
| `FAILED` in a unit's folder (`node/<ID>/`, `issue/<N>/`, `pr/<N>/`) | It gave up: for example its session exited twice without a PR or question, or its PR was closed without merging. The file says why and what to do. | Do what the file says (look at the folder's `session.stderr` for a session that failed), then delete `FAILED` (2 fresh starts). |
| `HOLDING: ...` in `nbctl.py status`, `throttle engaged` in the status log | The throttle: the 5-hour window is projected past the limit, a usage window is rejected, or the week is ahead of pace (unless `USAGE_7D_PACE=0`). New sessions wait; running ones go on. | Wait for the window to reset, or release one node. |
| A session that hit the usage limit | It's resumed by itself after the reset. | Nothing. |
| `not deployed: ... fails CI` / `make test` | A new noodlebot commit failed its check; the old code still runs. | Fix `main`, or re-run its CI and retry the deploy. |
| `loop not running` in `loops.sh status` | It stopped (a STOP file, or it crashed). | Remove `~/STOP` if it exists, then `scheduler/loops.sh start` (it removes a stale `~/STOP-<name>` itself). |
| `nbctl.py`: "the API is not running" | The API isn't running. | `scheduler/loops.sh start`. |
| Nothing new in the daily log | The log step failed (it never stops the loop). | `state/<name>/report.log`. |

Every loop writes `state/<name>/status.log`, one line per event; it's the first place to look.

## Status site

The loop can publish a status site for the repositories it watches. The files are sent to a public gist you make once by
hand; the publisher never creates a gist.

1. Create a public gist (any file will do; the first publish replaces it) and note its ID, the last part of its URL.
2. Make a token that can only touch gists: a classic token with only the `gist` scope, or a fine-grained token with only
   the Gists account permission (read and write).
3. Put the ID in `~/.config/noodlebot/gist` and the token in `~/.config/noodlebot/gist-token`, both mode 0600.

With either file missing the loop says `status site off: no gist configured` once and publishes nothing; `SCHED_SITE=0`
turns publishing off. The gist token goes only to the publish command, never to a session. A failed publish is one status
line (`status site: publish failed (<status>)`), with details in `state/<name>/site.log`; `status site: publishing again`
follows the next success.

**Links to the site.** The log issue and the bot's comments link each node's ID to the site when the repository is public,
the loop publishes the site, and `~/.config/noodlebot/site` holds its address on one line, e.g.
`https://<owner>.github.io/noodlebot/`: a valid `https://` address (no spaces, quotes, parentheses or angle brackets).
Otherwise the texts have no links; an invalid address is one status line (`status site links off: <reason>`).

**The front end** in `site/` is a static page that reads the gist from the browser. `.github/workflows/pages.yml`
deploys it to GitHub Pages when `site/**` changes on `main` (or by hand, with `workflow_dispatch`). To enable it:

1. In the repository's Settings, Pages, set the source to GitHub Actions.
2. In Settings, Secrets and variables, Actions, Variables, add the repository variable `NOODLEBOT_GIST_ID` with the
   gist's ID. The workflow writes it to `site/config.json` and fails with a message while it is unset.

The page also takes `?gist=<id>`, which wins over `config.json`.

## API

An HTTP API over the runtime files, for dashboards and scripts: `scheduler/api.py`, on the Unix socket
`$NOODLEBOT_DATA/api.sock` (mode 0600, so only you can use it). `loops.sh start` and `stop` start and stop it with the
loops. Every answer is JSON with `"version": 1`, except the event stream.

    curl --unix-socket ~/.local/share/noodlebot/api.sock http://localhost/v1/repos

**Reads** (GET):

- `/v1/repos`, `/v1/repos/<owner>/<name>`, and under it `/nodes`, `/nodes/<ID>`, `/sessions`, `/prs`, `/issues`.
- `/v1/throttle`, `/v1/deploy`: the usage throttle; the deployed commit, rollback point, last deploy and rejections.
- `/v1/schema/<resource>`: the JSON schema of a resource.
- `/v1/events`: a `text/event-stream` (not JSON) of status-log events. `?repo=<owner>/<name>` limits it to one repository;
  `?since=<cursor>` (or `Last-Event-ID`) resumes after an event.

**Controls.** Each writes only a marker the loop or `deploy.sh` already reads (and, for the loop's controls, a request
record in `state/<name>/requests/`), and is carried out at the loop's next tick or `deploy.sh`'s next run. The API starts
no loop and signals no process. They answer 202 when accepted, 404 for an unknown repository, node, issue or commit,
409 when there's nothing to do. The loop logs each loop control as a status-log event.

| Control | Request (under `/v1/repos/<owner>/<name>` unless it starts with `/v1/deploy`) |
|---|---|
| Delete a node's or an issue's `FAILED` | `DELETE /nodes/<ID>/failed`, `DELETE /issues/<N>/failed` |
| Stop a repository's loop; allow it again | `PUT /stop`, `DELETE /stop` (`~/STOP-<name>`; allowing doesn't start it: `loops.sh start` does) |
| Start one node the throttle holds, once | `POST /nodes/<ID>/release` |
| Retry a rejected commit | `POST /v1/deploy/retry` with `{"sha": "<commit>"}` |
| Roll back to the rollback point | `POST /v1/deploy/rollback` |

In full (with `S=~/.local/share/noodlebot/api.sock` and `R=http://localhost/v1/repos/<owner>/<name>`):

    curl --unix-socket $S -X DELETE $R/nodes/<ID>/failed
    curl --unix-socket $S -X DELETE $R/issues/<N>/failed
    curl --unix-socket $S -X PUT $R/stop
    curl --unix-socket $S -X DELETE $R/stop
    curl --unix-socket $S -X POST $R/nodes/<ID>/release
    curl --unix-socket $S -X POST -d '{"sha": "<commit>"}' http://localhost/v1/deploy/retry
    curl --unix-socket $S -X POST http://localhost/v1/deploy/rollback

**`scheduler/nbctl.py`** is the API's command-line client (Python standard library only, no token, no `gh`).
`--socket <path>` (before the command) uses another socket; with nothing listening it says so and exits 2.

    scheduler/nbctl.py status [<owner/name>]
    scheduler/nbctl.py events [--repo <owner/name>] [--since <cursor>]
    scheduler/nbctl.py get repos/<owner>/<name>/prs   # the JSON of /v1/<path>; exit 0 for 200, 1 for 404, 2 otherwise

**From another machine**, forward the socket over SSH (set `StreamLocalBindUnlink yes` if `/tmp/nb.sock` is left over):

    ssh -L /tmp/nb.sock:/home/<user>/.local/share/noodlebot/api.sock host
    scheduler/nbctl.py --socket /tmp/nb.sock status

## Running it in a container

The image holds the toolchain (bash, git, gawk, python3 with PyYAML, `gh`, tmux, Node, the Claude Code CLI with its
self-updater off, rootless podman) and a copy of noodlebot in `/opt/noodlebot`. At start it puts the live checkout on the
home volume, starts the loops, and stops them cleanly on SIGTERM.

**Get the image.** `.github/workflows/image.yml` builds `container/Containerfile` and, on a push to `main`, pushes
`ghcr.io/<owner>/<name>` (the repository's name in lowercase) tagged with the commit and `latest`; the package's
visibility is yours to set. Or build it from a fresh full clone with its tags (the build context becomes
`/opt/noodlebot`, and an untracked local file would end up in it):

    podman build -f container/Containerfile --build-arg REPO_URL=https://github.com/<owner>/<name>.git .

**The config folder** is `~/.config/noodlebot` as in [Setting it up](#setting-it-up), plus, optionally, `gitconfig`, which
the container's `~/.gitconfig` includes so sessions commit with your identity. It's mounted read-only and never part of
the image. The container's user is `noodlebot`, uid 1000: the folder and the token script must be readable (and the
script executable) by that uid.

**On one host:** `container/compose.yaml` has one service with a named volume `noodlebot-home` at `/home/noodlebot`, the
config folder (`$NOODLEBOT_CONFIG`, default `~/.config/noodlebot`) read-only at `/home/noodlebot/.config/noodlebot`,
`restart: unless-stopped`, a stop grace period of 330 s (longer than `loops.sh stop`'s 300 s wait) and no published port.
Name your image in it (or in an override file), then:

    docker compose -f container/compose.yaml up -d     # or: podman compose -f container/compose.yaml up -d

**On a cluster:** `container/k8s/` holds a `kustomization.yaml` and a StatefulSet. Create the Secret from the config
folder, then apply:

    kubectl create secret generic noodlebot-config --from-file=$HOME/.config/noodlebot
    kubectl apply -k container/k8s

The Secret is mounted read-only with mode `0550` (the files belong to the pod's `fsGroup`, which `noodlebot` is in, so it
can run the token script). The kustomization's `images:` entry names another image. There is no Service: the API is the
Unix socket on the volume (`kubectl exec ... nbctl`). The `home-config` init container (uid 1000, not privileged, the same
image) creates `~/.config` on a new, empty PVC.

**One replica per runtime root.** The StatefulSet has `replicas: 1`: the volume holds the runtime root and the live
checkout, and two schedulers on the same `repos` (two replicas, or the container and the machine's own loops) start every
session twice. Never scale it up.

**Updates.** Code deploys go through `deploy.sh` inside the container, as on a machine. A new image (toolchain or Claude
Code CLI) takes a restart, which stops running sessions; they resume afterwards. A repository whose builds need more
tools gets a derived image: `FROM ghcr.io/<owner>/<name>` plus the tools, keeping its `ENTRYPOINT`.

### Nested rootless podman

Sessions run `podman` as `noodlebot`, with no container-runtime socket mounted and without `--privileged`. That takes
these settings in the compose file and the manifests:

| Setting | Why |
|---|---|
| `/dev/fuse` (compose `devices`) | The storage driver is fuse-overlayfs. Kubernetes has no device field: the cluster needs a FUSE device plugin that offers `/dev/fuse` to the pod, or set `STORAGE_DRIVER=vfs` (slow, no device). |
| `label=disable` (compose `security_opt`) | SELinux doesn't confine the container, so nested podman can mount. |
| `seccomp=unconfined` (compose), `seccompProfile: Unconfined` (pod `securityContext`) | The default profile blocks the `mount` and `unshare` calls a user namespace needs. |
| `apparmor=unconfined` (compose), `appArmorProfile: Unconfined` (container `securityContext`) | The same, on AppArmor hosts. |
| `allowPrivilegeEscalation: true` | `newuidmap` and `newgidmap` have file capabilities (`cap_setuid`, `cap_setgid`; not setuid), which is a privilege gain too. They map the user's 65536 subordinate ids (the same range as `quay.io/podman/stable`, so it also works when the outer container is rootless). Not tested in a pod with `hostUsers: false`. |
| `systempaths=unconfined` (compose), `procMount: Unmasked` (container `securityContext`) | Docker and Kubernetes mask parts of `/proc`, which stops nested podman from mounting a `/proc` of its own. `procMount: Unmasked` needs `hostUsers: false` (the pod's own user namespace). |

The trade-offs:

- `systempaths=unconfined` removes the masked and read-only paths (such as `/proc/kcore`, `/sys/firmware`, `/proc/sys`,
  `/proc/sysrq-trigger`, `/proc/irq`, `/proc/bus`, `/proc/fs`). Under rootful Docker without userns-remap, root in the
  container is root on the host, so anything that gains root in it could write host kernel settings. Rootless Docker or
  Podman, or userns-remap, limits that for compose; in the pod, `hostUsers: false` makes the container's root
  unprivileged on the node. Nested containers get their own `/proc`, masked by nested podman.
- `procMount: Unmasked` needs the cluster to support user namespaces for pods: the feature gates
  `UserNamespacesSupport` and `ProcMountType` (both on by default from Kubernetes 1.33; with `ProcMountType` off the API
  server silently drops the field), and a runtime and node kernel that support it.
- **Pod Security:** the `Unconfined` seccomp and AppArmor profiles and `procMount: Unmasked` are rejected below the
  `privileged` level. Put the namespace at `pod-security.kubernetes.io/enforce: privileged` (the pod itself is still not
  `privileged: true` and mounts no socket).
- The image's `/etc/containers/containers.conf` has no cgroup manager, the file events logger and the container's network
  namespace (so no `/dev/net/tun`), and doesn't bind the outer `/proc` into nested containers (that would expose it to
  every nested container, whose root is uid 1000).

**Host requirements:** Linux 5.14 or newer (the loop probes read the `ino:` line of `/proc/<pid>/fdinfo`; older kernels would miss a running loop), unprivileged
user namespaces allowed (on Ubuntu 24.04, `sysctl kernel.apparmor_restrict_unprivileged_userns=0`), `/dev/fuse`, and a
volume filesystem that supports the overlay storage driver (not NFS). The image workflow's run of
`container/compose.yaml` is the recorded check.

## Where things are

| Path | What |
|---|---|
| `scheduler/loop.sh`, `loops.sh` | The loop (one per repository) and the script that starts and stops them all. |
| `scheduler/deploy.sh` | Self-deploy of the live checkout. |
| `scheduler/report.py`, `nbctl.py`, `api.py` | The daily log, the terminal client, the API. `status.sh` is the older terminal view, replaced by `nbctl.py status`. |
| `scheduler/unattended*.md`, `pickup.md`, `limit-resume.md` | The prompts the sessions get. |
| `scheduler/forge.py`, `forges/` | The forge interface and its GitHub backend (the fake forge for tests is in `scheduler/testdata/forge/`) ([`forges/README.md`](scheduler/forges/README.md)). |
| `scheduler/harness.py`, `harnesses/` | The agent-harness interface and its Claude Code backend ([`harnesses/README.md`](scheduler/harnesses/README.md)). |
| `plugin/` | The skills every session loads (`/noodlebot:node <ID>`, `/noodlebot:triage <issue>`, `/noodlebot:adopt`) and their agents. With Claude Code: `claude --plugin-dir ~/gitrepos/noodlebot/plugin`. |
| `container/` | The image, `compose.yaml`, `k8s/`. |
| `site/` | The status site's front end. |
| `docs/graph.yaml`, `nodes/` | noodlebot's own planned work, under the same regime as the repositories it builds. |
| `make test` | Every test, offline, with fake `gh` and `claude`; CI runs it on every PR. |

**Runtime**, outside any checkout, under `$NOODLEBOT_DATA` (default `~/.local/share/noodlebot`):

| Path | What |
|---|---|
| `repos/<name>` | The scheduler's own clone of each repository. |
| `worktrees/<name>/<ID>`, `pr-<N>` | One worktree per node session or PR update. |
| `state/<name>/` | `status.log`, `deploy.log`, `report.log`, `site.log`; per unit `node/<ID>/`, `issue/<N>/`, `pr/<N>/` with the session's logs and the markers `QUESTION.md`, `ANSWER.md`, `FAILED`, `WAITING-PR`, and `answered/` for the questions already answered. |
| `deploy/` | Self-deploy's records: the rollback point (`previous`), rejected commits, tries, and the retry and rollback requests. The deployed commit is the live checkout's `HEAD`. |
| `api.sock` | The API. |

An older installation kept `repos/`, `worktrees/` and `state/` inside the checkout. Move them once: `touch ~/STOP`, wait
until no session runs, `scheduler/move-runtime.sh ~/gitrepos/noodlebot`, then `scheduler/loops.sh start`. Until then,
`start` refuses while a loop from before the move still holds `<checkout>/state/<name>/loop.lock`.
