# P01 — api

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | M01 | P02, P03 | L |

**Owns:** `scheduler/api.py`, `scheduler/api.test.sh`, its line in the `Makefile`'s `test` target, the schemas `scheduler/api-schema/v1/`, the fixtures `scheduler/testdata/api/`, the cache of labelled issues in `scheduler/issues.py` (`issues.json`) and its case in `scheduler/issues.test.sh`, the API server's start, stop and status line in `scheduler/loops.sh` and their cases in `scheduler/loops.test.sh`, the API section of the README.
**Resolves:** #46

## Purpose
After this node one question about the scheduler ("is a node stuck?", "which PRs conflict?", "why is the throttle holding?") is one request, not a reading of `status.log`, `usage.json`, `report.json`, session logs and GitHub by hand. `scheduler/api.py` is one HTTP server per machine on the Unix socket `$NOODLEBOT_DATA/api.sock`, readable only by its owner, written with the Python standard library alone. It serves, for every repository in `~/.config/noodlebot/repos`, what the loops know: repositories, nodes and their states, sessions, the throttle, open PRs, triage issues and deploys, and the status logs as a live event stream. Every resource has a versioned JSON schema that `make test` checks against fixture state folders, so a CLI (P02), a TUI or a web page can be built on it without reading state files. The API is read-only. It reads only local files and makes no GitHub call, so it holds no token.

## Tests
- `scheduler/api.test.sh` (new): starts `api.py` with `NOODLEBOT_DATA` and `HOME` set to temporary folders built from `scheduler/testdata/api/`, and makes its requests with `curl --unix-socket` (or a Python client from the standard library). The fixture covers the following:
  - two listed repositories, one with its loop running (a process holding its `loop.lock`) and one stopped, with `~/STOP-<name>` present;
  - a graph with a node in each state of change 3;
  - live and ended sessions of a node, a triage and an update. Their logs hold tool uses, a pending `ScheduleWakeup`, background commands and agents, a usage-limit rejection, and strings shaped like GitHub and Anthropic tokens;
  - `usage.json` holding and open;
  - `open-prs.tsv` with mergeable and conflicting PRs, `issues.json`, and a `deploy/` folder with `previous` and `rejected`.

  It checks the following:
  - every response against its schema;
  - the states;
  - the summaries;
  - the event stream and its cursor;
  - the socket's mode;
  - that no token string appears in any response or in the server's own output;
  - that the server writes nothing under the state folders and calls no `gh` (a fake `gh` on `PATH` records any call).
- `scheduler/issues.test.sh` (extended): `issues.py next` writes `issues.json`.
- `scheduler/loops.test.sh` (extended): `loops.sh start`, `stop` and `status` start, stop and show the API server, with a fake `api.py`.

## Changes
1. **The server.** `scheduler/api.py` serves HTTP/1.1 on `$NOODLEBOT_DATA/api.sock` (default root as in `loop.sh`), created with mode 0600. Only one server runs per runtime root: it takes `$NOODLEBOT_DATA/api.lock` and exits 2 with a message if another server holds it. A socket file left by a server that died is replaced at start. Every request is a `GET` under `/v1/`. An unknown path is a 404 with a JSON error body; any other method is a 405 and changes nothing. It uses only the Python standard library. Like the loops after a deploy, the server checks its checkout's `HEAD` every 60 seconds and re-execs itself when it moved, keeping its lock. Open event streams then close, and their clients reconnect with their cursor. *P01-AC-1, P01-AC-2.*
2. **Repositories.** `GET /v1/repos` lists each repository in `~/.config/noodlebot/repos`, read as `loops.sh` reads it; the server reads no other file under `~/.config/noodlebot/`. For each it gives the following:
   - whether its loop runs (its `loop.lock` is held, read from `/proc/locks` as `loops.sh` does, never by taking the lock);
   - whether `~/STOP` or `~/STOP-<name>` exists;
   - its heartbeat and its age;
   - its status issue (from `report.json`).

   `GET /v1/repos/<owner>/<name>` gives one. *P01-AC-3.*
3. **Nodes.** `GET /v1/repos/<owner>/<name>/nodes` gives each node of the repository's last fetched graph (`state/<name>/graph.yaml`) with its ID, name, deps, track and state. Its state is the first of these that holds:
   - `merged`;
   - `pr-open`, with the PR's number and mergeable state from `open-prs.tsv`;
   - `running`, a live session;
   - `idle-limit`, a live session whose log ends with a usage-limit rejection, read as S06 reads it;
   - `failed`, with the first line of `FAILED`;
   - `question`, with the first line of `QUESTION.md` and the URL of the issue where it is answered (the unit's home issue if `node/<ID>/issue` exists, else the status issue);
   - `answered`;
   - `waiting-pr`, with the spec PR's number;
   - `held`, a node `ready.py` would start while the throttle holds;
   - `ready`;
   - `waiting`, with the deps not yet merged.

   It also gives the node's starts used. `ready.py` is run over the files the loop cached at its last tick, as the loop runs it. `GET .../nodes/<ID>` gives one. *P01-AC-4.*
4. **Sessions.** `GET /v1/repos/<owner>/<name>/sessions` gives every node, triage and update session that has a `session.pid`, with the following:
   - its kind and its node, issue or PR;
   - its pid, whether it is alive (by the session's `/proc/<pid>/cmdline`, as `loop.sh` decides it) and its start time;
   - its log's size and last write;
   - its last events, at most 10: tool uses with the tool's name and the first line of its description, command or path cut to 200 characters, a subagent's marked, and each `result` with its subtype;
   - the time of a pending `ScheduleWakeup` (its tool use's time plus `delaySeconds`) when no later event shows the session went on;
   - its background commands and agents that the log shows started and not yet finished;
   - its last usage-limit rejection and its reset time;
   - `session.rc` once it ended.

   A session's log is never served whole. *P01-AC-5, P01-AC-9.*
5. **The throttle, PRs, issues and deploys.**
   - `GET /v1/throttle` gives `usage.json`: each window's utilization and reset, the 5-hour projection, and whether it holds and why.
   - `GET /v1/repos/<owner>/<name>/prs` gives `open-prs.tsv`: number, branch, head, whether the bot opened it, and its mergeable state.
   - `GET /v1/repos/<owner>/<name>/issues` gives the triage issues. These are the labelled issues `issues.py next` saw (change 6) and every `state/<name>/issue/<N>/` with its state (running, question, failed, done).
   - `GET /v1/deploy` gives the live checkout's head, `deploy/previous` (the rollback point), the rejected commits, and the last deploy and last failed test run as the status logs record them.

   Each resource carries the time of the file it was read from. *P01-AC-6.*
6. **The cache of labelled issues.** `issues.py next` also writes the open issues it read, with number, title and whether the owner labelled them, to `$NOODLEBOT_DATA/state/<name>/issues.json` (written to a temporary file and renamed). A failure to write it is logged on stderr and does not change what `next` prints. *P01-AC-6.*
7. **The event stream.** `GET /v1/events` answers `text/event-stream`. It sends each line appended to any listed repository's `status.log` as one event, with the repository and the line, and an `id` that is a cursor. With `?since=<cursor>` or a `Last-Event-ID` header it first sends every line after that cursor. Without either, it starts at the end. A client that reconnects with the last id it got receives every later line once, none lost and none repeated. A `?repo=<owner>/<name>` filter limits the stream to one repository. A comment line every 15 seconds keeps idle connections open. *P01-AC-7.*
8. **Schemas.** Each resource has a JSON schema in `scheduler/api-schema/v1/<resource>.json`, served at `GET /v1/schema/<resource>`. Every response has `"version": 1`. `api.test.sh` validates every response of the fixture against its schema, with a small validator in the test that covers the keywords the schemas use (`type`, `properties`, `required`, `items`, `enum`, `additionalProperties`). A change that breaks a schema's existing fields needs `/v2/`. *P01-AC-8.*
9. **No tokens.** The server reads no credential and runs no token script. Every text it serves from a session log or a status log first has strings of the form of a GitHub token (`ghs_`, `ghp_`, `gho_`, `ghu_`, `github_pat_`) or an Anthropic key (`sk-ant-`) replaced by `[redacted]`. It logs only its own start, stop and errors, never a request's response. *P01-AC-9.*
10. **With the loops.** `loops.sh start` also starts the server in tmux session `sched-api` when none runs (its `api.lock` is free, read from `/proc/locks`), passing it the runtime root. `loops.sh stop` stops it after the loops have exited. `loops.sh status` prints one line for it: running or not, and its socket. *P01-AC-10.*
11. **The README** has an API section: the socket, the resources, the event stream, an example with `curl --unix-socket`, and remote use over SSH (`ssh -L` to the socket). *P01-AC-10.*

## Gate
- **P01-AC-1** — `api.py` serves HTTP on `$NOODLEBOT_DATA/api.sock`, which has mode 0600. A second `api.py` on the same root exits 2 and leaves the first one serving. A socket file left by a killed server does not stop a new one from starting. When the checkout's `HEAD` moves, the server serves from the new commit within 2 minutes. `api.py` imports only the Python standard library. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-2** — The API changes nothing. A `POST`, `PUT`, `PATCH` or `DELETE` is answered 405, an unknown path 404, and in either case the body is JSON. After the whole test, no file under the fixture's runtime root or `HOME` has changed except the socket and the lock. The fake `gh` recorded no call. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-3** — `/v1/repos` lists each repository of the fixture's `~/.config/noodlebot/repos` once. For each it gives the following: whether its loop runs (true for the one whose `loop.lock` a process holds, false for the other); whether `~/STOP` and `~/STOP-<name>` exist; its heartbeat's age; and its status issue's number. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-4** — `/v1/repos/<owner>/<name>/nodes` gives each fixture node the state the fixture sets up for it. The states are `merged`, `pr-open` (with the PR's number and mergeable state), `running`, `idle-limit`, `failed` (with its reason), `question` (with the issue URL where it is answered), `answered`, `waiting-pr`, `held`, `ready` and `waiting`. It also gives each node's starts used. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-5** — `/v1/repos/<owner>/<name>/sessions` gives each fixture session the following: its kind, its subject, pid, alive and start time; its last at most 10 events, as change 4 describes them; and its pending `ScheduleWakeup` time, its unfinished background commands and agents, and its limit rejection with its reset time, each where the fixture's log has one and absent where it has none. No response contains more than those events of a log. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-6** — `/v1/throttle`, `/v1/deploy`, `.../prs` and `.../issues` give the fixture's `usage.json` (both windows, the projection, hold and reason), its deploy state (head, rollback point, rejected commits), its open PRs with their mergeable states, and its triage issues with their states. `issues.py next` writes `issues.json` with the labelled issues it read, and prints the same as before. *Verify:* `scheduler/api.test.sh`, `scheduler/issues.test.sh`.
- **P01-AC-7** — `/v1/events` streams each line appended to a fixture `status.log` while the client is connected, within 5 seconds, as one event with the repository, the line and an `id`. A client reconnecting with that `id` (in `?since=` or `Last-Event-ID`) receives the lines appended while it was away, each once and in order. `?repo=` limits the stream to that repository. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-8** — Every resource has a schema in `scheduler/api-schema/v1/`, served at `/v1/schema/<resource>`. Every response of the test, for every fixture repository, node and session, is valid against its schema and has `"version": 1`. *Verify:* `scheduler/api.test.sh`.
- **P01-AC-9** — The fixture's token-shaped strings, planted in session logs and status logs, appear in no response and in none of the server's output. The server never reads a file under `~/.config/noodlebot/` other than `repos`. *Verify:* `scheduler/api.test.sh` (the fixture's `~/.config/noodlebot/token` is a script that records being run, and is never run).
- **P01-AC-10** — `loops.sh start` starts the API server when none runs and leaves a running one alone. `loops.sh stop` stops it after the loops exit. `loops.sh status` prints a line saying whether it runs and its socket. The README's API section names the socket, the resources and the SSH forward. *Verify:* `scheduler/loops.test.sh`; the README by review.

## Risks
- The API is as fresh as the loop's last tick for anything that comes from GitHub (PRs, merged nodes, labelled issues). Each resource carries its file's time, so clients can show that age.
- A node's state is derived from the same files the loop reads, by the same rules, but in a separate program. If the loop's rules change and the API's do not, they disagree. Running `ready.py` itself, instead of copying its rules, keeps the largest part shared.
- States from nodes not yet merged come from their files only when they exist: S06's idle sessions (read from the log, as S06 reads it) and U01's home issue (`node/<ID>/issue`). The background-task and wakeup readings depend on the CLI's stream-json format, which is not a stable interface; a change shows as missing fields, not as an error.
- Redaction catches token shapes known today. A credential of another shape that a session printed into its log would be served, cut to 200 characters. The logs themselves already hold it, readable by the same owner.
- The re-exec after a deploy drops open event streams for a moment. A client that does not reconnect with its cursor misses nothing in the logs, but it shows nothing new until it reconnects.
