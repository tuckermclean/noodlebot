# S08 — harness

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | P03 | R02 | L |

**Owns:** `scheduler/harness.py` (the harness interface, its CLI, backend selection, the normalised event log and the capability rule), `scheduler/harness.test.sh` (the conformance suite) and its line in the `Makefile`'s `test` target; `scheduler/harnesses/` (the Claude Code backend `claude_code.py`: the `claude` command line, its settings and credential, the stream-json translation, how a prompt names a skill; `README.md`, the operation table across harnesses); the fake harness and its fixtures `scheduler/testdata/harness/`; the harness rules of `scheduler/agnostic.test.sh` (this node creates the file and its line in the `Makefile`'s `test` target when G04 has not merged first; G04 then adds its forge rules); in `scheduler/run-session.sh`, starting and resuming a session through the backend and writing `events.jsonl`; in `scheduler/loop.sh`, the harness setting (`SCHED_HARNESS`), the credential check, the limit-exit, idle-by-limit, resume and background cut-off checks, the session's process match and the skill command of a start; the event reading of `scheduler/usage.py`, `scheduler/api.py`, `scheduler/report.py` and `scheduler/site.py`; the process match in `scheduler/loops.sh`, and the process match and session reading in `scheduler/status.sh`; passing `SCHED_HARNESS` per loop in `scheduler/loops.sh`; the harness part of the README's usage; `scheduler/loop-s08*.test.sh` (new) and their lines in the `Makefile`'s `test` target; their cases in the existing `*.test.sh` files.
**Resolves:** #84

## Purpose
After this node the scheduler's code reaches the agent harness only through one interface, `scheduler/harness.py`, and Claude Code is its first backend. The backend starts and resumes sessions and turns its own output into a normalised event log, `events.jsonl`. The loop, the throttle, the API, the status issue and the site read only that log, and no core code parses stream-json any more. A fake harness passes the same conformance suite and runs the loop end to end with no `claude` at all. A table records how Codex, Pi and OpenCode would do each operation.

## Tests
- `scheduler/harness.test.sh` (new), the conformance suite: one set of cases run against the Claude Code backend (with the fake `claude` of `scheduler/testdata/lib/` and recorded stream-json fixtures under `scheduler/testdata/harness/`) and against the fake harness. Cases: a start and a resume give the same normalised events; each recorded raw log (a normal end, a usage-limit exit, an idle-by-limit log, a resumed log, a background cut-off, a truncated last line, a log over 400 KB) gives the events of change 3; `events.jsonl` rebuilt from a raw log with no events file equals the one written live; a capability the fake harness is configured without reports itself off; the credential is read once per session start and appears in no event, log or argv.
- The existing tests (`loop*.test.sh`, `usage.test.sh`, `api*.test.sh`, `report*.test.sh`, `site.test.sh`) pass with their expectations unchanged against the Claude Code backend over the fake `claude`.
- `scheduler/agnostic.test.sh` (new, or extended if G04 merged first): the harness rules of change 6 pass on the tree and fail, naming file and line, on each planted form.
- `scheduler/loop-s08*.test.sh` (new, the per-topic loop test files since D03): `SCHED_HARNESS=fake` runs a tick that starts a node, sees its limit exit and resumes it, with a `claude` on `PATH` that fails on any call; an unknown harness exits 2 with a message; a harness lacking usage readings, resume or the background-wait setting has each feature off with one status-log line per loop start, and the rest of the tick runs.

## Changes
1. **Inventory.** The node starts from a list, in `scheduler/harnesses/README.md`, of every place core starts, resumes, recognises or reads a session after P03 is merged: each call site and what it reads. The interface covers exactly that list. *S08-AC-1.*
2. **The interface.** `scheduler/harness.py` defines:
   - `start(worktree, state dir, prompt, system prompt, plugin)` and `resume(worktree, state dir, session id, prompt)`, run by `run-session.sh`, with the exit code written to `session.rc` as today;
   - `skill_command(skill, args)`: how a prompt names a skill (Claude Code: `/noodlebot:node B03`, or `/node B03` for a repository that ships its own `node` skill, as `loop.sh` decides today);
   - `matches(cmdline, unit)`: whether a process is that unit's session (the process check of `loop.sh`, `loops.sh`, `api.py`, `report.py`, `site.py` and `status.sh`);
   - `preflight()`: the backend's credential check at loop start (Claude Code: `~/.config/noodlebot/oauth-token`);
   - `events(state dir)`: the session's normalised events (change 3);
   - its capabilities: usage readings, conversation resume, the background-wait setting.

   The CLI (`harness.py <operation> ...`) serves shell scripts. *S08-AC-2.*
3. **The normalised event log.** The backend writes `events.jsonl` next to the raw log `session.jsonl` as the session runs, one JSON object per line with `t` (time) and `type`: `start` (session id), `usage` (window, status, utilization, reset time), `tool` (tool name and the short input the API shows today), `text` (the narration the API and report show today), `result` (cost, turns, closing text, whether it names a usage limit) and `cutoff` (background tasks stopped at the end). When `events.jsonl` is missing or behind its raw log (a session started before this node, a restart), `events()` rebuilds it from the raw log first. Only the backend reads `session.jsonl`. *S08-AC-3.*
4. **The converted readers.** `loop.sh` (limit exit, idle by limit, the session id to resume, the resumed session's start, the background cut-off), `usage.py` (the readings of every session changed in the last 7 days), `api.py` (session events and idle state), `report.py` (cost and turns, closing summaries) and `site.py` read only `events()`. Their results on the existing fixtures are unchanged. *S08-AC-4.*
5. **Choosing the harness, and capabilities.** `SCHED_HARNESS` (default `claude-code`) chooses the backend per loop; `loops.sh start` passes it to each loop. An unknown name exits 2 with a message. A capability the backend lacks turns its feature off, with one status-log line per loop start (`harness <name> lacks <capability>: <feature> off`): no usage readings means the throttle holds nothing; no resume means a limit-idle session is ended and restarted as a new start, as S06 did before resume; no background-wait setting means the cut-off check is skipped. *S08-AC-5, S08-AC-6.*
6. **The core check's harness rules.** `scheduler/agnostic.test.sh` also fails, naming file and line, on these in the tracked `.sh` and `.py` files under `scheduler/` and `plugin/`, outside comments, tests, `scheduler/testdata/` and `scheduler/harnesses/claude_code.py`: a `claude` command, a `CLAUDE_CODE_` name, `stream-json`, `--plugin-dir`, `--append-system-prompt`, and the stream-json field names `rate_limit_event`, `rate_limit_info`, `total_cost_usd` and `num_turns`. The role guard (`plugin/hooks/`) is R02's and is exempt here. *S08-AC-7.*
7. **The fake harness.** `scheduler/testdata/harness/` holds a backend that "runs" a session by replaying a scripted event list (start, tool uses, a usage limit, a result) into `events.jsonl` with a chosen exit code, with its capabilities set per test. *S08-AC-2, S08-AC-6.*
8. **Other harnesses, on paper.** `scheduler/harnesses/README.md` has a table with one row per operation of change 2 and per event type of change 3, and columns Claude Code, Codex, Pi and OpenCode, giving each harness's way (a command line, an output field, or "none: capability off") with a link to its documentation. The starting point:

   | Operation | Claude Code | Codex, Pi, OpenCode |
   |---|---|---|
   | start, unattended | `claude -p --output-format stream-json` | each harness's non-interactive mode with machine-readable output, if it has one |
   | resume a conversation | `claude -p --resume <id>` | its session-resume command, or none: capability off |
   | system prompt, plugin | `--append-system-prompt`, `--plugin-dir` | its instructions file and skill folders |
   | usage readings | `rate_limit_event` | none unless the harness reports plan limits: capability off |
   | cost and turns | the `result` event | its usage summary, if any |

   *S08-AC-8.*

## Gate
- **S08-AC-1** — `scheduler/harnesses/README.md` lists every place core starts, resumes, recognises or reads a session on this node's merge base (after P03), each with what it reads, and every listed operation is exported by the interface. *Verify:* `scheduler/harness.test.sh` (each operation the README lists is exported), and the list in the PR.
- **S08-AC-2** — A start and a resume through the Claude Code backend over the fake `claude`, and through the fake harness, write `session.rc` and give the same normalised events for the same script. The credential is read once per start and appears in no event, log or argv. *Verify:* `scheduler/harness.test.sh`.
- **S08-AC-3** — Each recorded raw log (a normal end, a usage-limit exit, an idle-by-limit log, a resumed log, a background cut-off, a truncated last line, a log over 400 KB) gives the events of change 3, and `events.jsonl` rebuilt from a raw log with no events file equals the one written while the session ran. *Verify:* `scheduler/harness.test.sh`.
- **S08-AC-4** — Every existing case of the loop's, `usage.py`'s, the API's, `report.py`'s and the site's tests passes with its expectations unchanged against the Claude Code backend. *Verify:* `make test`.
- **S08-AC-5** — `SCHED_HARNESS` unset or `claude-code` runs the Claude Code backend, `fake` the fake harness, and an unknown name exits 2 with a message. `loops.sh start` passes it to each loop. A tick with the fake harness and a `claude` on `PATH` that fails on any call starts a node, sees its usage-limit exit and resumes it. *Verify:* `scheduler/loop-s08*.test.sh`, `scheduler/loops.test.sh`.
- **S08-AC-6** — With the harness lacking usage readings the throttle holds nothing; lacking resume, a limit-idle session is restarted as a new start; lacking the background-wait setting, the cut-off check is skipped. Each is said once per loop start in the status log, and the tick carries on. *Verify:* `scheduler/loop-s08*.test.sh`.
- **S08-AC-7** — The core check passes on the tree and fails, naming file and line, on each planted form of change 6 in a `.sh` and a `.py` file outside the Claude Code backend; a mention in a comment passes. *Verify:* `scheduler/agnostic.test.sh`.
- **S08-AC-8** — `scheduler/harnesses/README.md` has one row per operation and event type, with Claude Code's, Codex's, Pi's and OpenCode's way or "none: capability off", each linked to that harness's documentation. *Verify:* `scheduler/harness.test.sh` (every operation and event type has a row with four filled cells), and the table in the PR.

## Risks
- The throttle, the limit resume and the API all depended on the exact stream-json shapes; they now depend on the translation. The recorded fixtures and the unchanged existing tests hold it, but a stream-json change Claude Code makes later breaks only the backend, which is the point and also the only place it shows.
- Sessions running when this lands have no `events.jsonl`; the rebuild from the raw log covers them, at the cost of reading their whole log once.
- The role guard is still a Claude Code hook and the skills still name Claude Code's tools until R02: a loop on another harness runs the scheduler, not yet the skills.
- Codex, Pi and OpenCode are described from their documentation only; their usage readings in particular may not exist, which would leave a loop on them without a throttle.
- P03 changes the loop's start path (the one-shot release). This node converts its code after it merges; nodes merged after this one that read sessions must use the interface, or the core check fails them.
