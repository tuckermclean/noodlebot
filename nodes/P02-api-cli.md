# P02 — api-cli

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | P01 | none | M |

**Owns:** `scheduler/nbctl.py`, `scheduler/nbctl.test.sh`, its line in the `Makefile`'s `test` target, the CLI part of the README's API section.
**Resolves:** #46

## Purpose
After this node the scheduler can be watched from the terminal through the API alone. `scheduler/nbctl.py`, a command-line client of P01's socket written with the Python standard library alone, shows every listed repository at once or one repository in the detail `scheduler/status.sh` gives. It can also follow the event stream live and print any resource as JSON for scripts. Unlike `status.sh`, it reads no state file, calls no `gh` and needs no token, so it can replace `status.sh`, and it shows the same over `ssh` with the socket forwarded.

## Tests
- `scheduler/nbctl.test.sh` (new): runs `nbctl.py` against a fake API server, a small standard-library server on a temporary Unix socket that serves canned `/v1/` responses valid against P01's schemas and records each request. `HOME` is a temporary folder with no `~/.config/noodlebot/`, and `PATH` holds a fake `gh` that records any call. The test checks the following:
  - each command's output;
  - its exit codes;
  - the paths it requested;
  - that nothing else was read or run.

## Changes
1. **The socket.** `nbctl.py` connects to `$NOODLEBOT_DATA/api.sock` (default root as in `loop.sh`), or to the path given with `--socket`. When nothing listens there, it prints one line saying the API is not running and that `scheduler/loops.sh start` starts it, and exits 2. A response whose `version` it does not know is an error naming that version, also exit 2. *P02-AC-1.*
2. **`nbctl.py status`** prints one line per listed repository. The line gives whether its loop runs or is stopped (and `~/STOP`/`~/STOP-<name>`), its heartbeat's age, its running sessions, and how many items wait on the owner (questions, FAILED, spec PRs to merge). Above the lines it prints one line for the throttle and one for the deploy. *P02-AC-2.*
3. **`nbctl.py status <owner/name>`** prints one repository in the detail `status.sh` gives:
   - its loop and STOP files, last GitHub check, status issue and the throttle;
   - each running session with its pid, age, log size and last write, its last 4 actions, and (for a node) its commits;
   - what waits on the owner: each FAILED with its reason, each QUESTION with its first line and the URL of the issue where it is answered, each answered question, each spec PR waited for;
   - the open PRs.

   It also shows what `status.sh` does not:
   - each node's state;
   - a session's pending wakeup, background work and limit rejection;
   - each PR's mergeable state.

   *P02-AC-3.*
4. **`nbctl.py events [--repo <owner/name>] [--since <cursor>]`** follows `/v1/events` and prints each event as one line, prefixed with its repository. When the connection drops it reconnects with the last id it got, every 2 seconds at most, and says so once on stderr. *P02-AC-4.*
5. **`nbctl.py get <path>`** prints the JSON of `/v1/<path>` as the API gave it, for scripts. Its exit code is 0 for a 200, 1 for a 404 and 2 otherwise. *P02-AC-5.*
6. **The README**'s API section shows the commands, and `nbctl.py status <owner/name>` as the replacement for `status.sh`, including with `watch`. *P02-AC-3.*

## Gate
- **P02-AC-1** — With no server on the socket, every command prints one line naming `scheduler/loops.sh start` and exits 2. Against a server whose responses have an unknown `version`, a command exits 2 and names the version. `--socket` overrides the default path. *Verify:* `scheduler/nbctl.test.sh`.
- **P02-AC-2** — `nbctl.py status` prints one line per repository of the fake API. Each line has the loop's state, the heartbeat's age, the running sessions and the count of items waiting on the owner, and the throttle and deploy lines come above them. *Verify:* `scheduler/nbctl.test.sh`.
- **P02-AC-3** — `nbctl.py status <owner/name>` prints every item of change 3 for the fake API's repository. It reads no file under `HOME` or the runtime root other than the socket, and the fake `gh` records no call. The README presents it as the replacement for `status.sh`. *Verify:* `scheduler/nbctl.test.sh`; the README by review.
- **P02-AC-4** — `nbctl.py events` prints each event the fake API streams as one line with its repository. When the fake drops the connection, it reconnects with `Last-Event-ID` (or `since`) set to the last id it printed, and prints no event twice. *Verify:* `scheduler/nbctl.test.sh` (the fake's recorded requests).
- **P02-AC-5** — `nbctl.py get <path>` prints the fake API's JSON unchanged. It exits 0 for a 200 response, 1 for a 404 and 2 for anything else. *Verify:* `scheduler/nbctl.test.sh`.

## Risks
- The fake API is built from P01's schemas, not from `api.py` itself. A difference between the schema and what `api.py` serves would pass here. P01's own test, which checks `api.py`'s responses against the same schemas, closes most of that gap.
- `status.sh` stays as it is. Removing it is left to the owner once the CLI has been used for a while.
