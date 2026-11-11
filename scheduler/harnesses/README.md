# Harness backends

The scheduler reaches the agent harness only through `scheduler/harness.py` (S08). A backend is a Python module in this
folder (`claude_code.py`, the first) or the fake harness of `scheduler/testdata/harness/fake.py` (its header is the
contract). `$SCHED_HARNESS` chooses it: unset or `claude-code`, or `fake`; any other name exits 2 with a message.

A backend exports `NAME`, `capabilities()`, `skill_command()`, `matches()`, `preflight()`, `start()`, `resume()`,
`events()` and `log_stat()`; `harness.py` re-exports each as a function and as a CLI subcommand (`harness.py skill-command ...`). The
raw log `session.jsonl` is the harness's own stream (stdout of `run-session.sh`, set up by the loop); only the backend
reads it, and writes the normalised log `events.jsonl` next to it as the session runs. `events()` rebuilds
`events.jsonl` from the raw log (and `session.stderr` for `cutoff`) when it is missing or behind the raw log (the
Claude Code backend records the raw size it has covered in `events.pos`; its recorder holds `events.lock` while the
session runs, so a rebuild never replaces `events.jsonl` under it).

## Inventory

Every place core starts, resumes, recognises or reads a session on the node base (5ca8771, after P03), what it reads
and the interface operation that serves it. Capabilities (`usage`, `resume`, `bg-wait`) are served by `capabilities`.

| Call site | What it does | What it reads | Operation |
|---|---|---|---|
| `loop.sh` `launch` (~l.524) | starts a session with `run-session.sh` under setsid | the prompt and `unattended.md` it renders; writes `session.jsonl`, `session.stderr`, `session.rc` | `start` |
| `loop.sh` `resume_idle` (~l.455-472) | resumes a limit-idle conversation in the same worktree, appending to the same log | the session id of the last init line, the prompt in `resume-prompt.md`, the raw log size (`resume.size`) | `resume` |
| `loop.sh` skill choice (~l.835) | names the node skill in the start prompt (`/noodlebot:node` or the repository's own `/node`) | whether `origin/main` ships `.claude/skills/node` | `skill_command` |
| `loop.sh` oauth check (~l.96) | refuses to start the loop without the session credential | the credential file `~/.config/noodlebot/oauth-token` (exists, readable) | `preflight` |
| `loop.sh` `alive` (~l.201-205) | is this pid that unit's session (guards pid reuse) | `/proc/<pid>/cmdline` | `matches` |
| `loop.sh` `limit_exit` (~l.209-222) | the session ended by the plan's usage limit (no start used up) | last 400 KB of the log: the last usage reading's status, the last result's text and subtype | `events` |
| `loop.sh` `idle_by_limit`, `idle_tail` (~l.225-262) | the log ends with the usage limit and has a reset time; the session id to resume | last 400 KB of the log: the last line (unknown when unparseable), usage status and reset time; the last init session id anywhere in the log | `events` |
| `loop.sh` `bg_cut_off` (~l.264-269) | the CLI stopped background tasks still running after the last turn (no start used up) | the last 100 KB of `session.stderr` | `events` |
| `loop.sh` `ended`, resume check (~l.307-312) | the resumed session wrote an init line after `resume.size` | the raw log after the offset: a session start | `events` |
| `loop.sh` background-wait cut-off check and throttle (~l.264, ~l.1004-1007) | features that exist only if the harness has them: usage readings, resume, the background-wait setting | which capabilities are on | `capabilities` |
| `loops.sh` (~l.221) | a loop's live sessions listed for `loops.sh` status and stop | `/proc/<pid>/cmdline` of each `session.pid` | `matches` |
| `status.sh` (~l.40) | which node sessions of a loop are live | `/proc/<pid>/cmdline` | `matches` |
| `status.sh` (~l.43-65) | the last four actions of a live session | tool uses (name, description or command or file or skill, subagent marker) and result (subtype, turns) of the log | `events` |
| `api.py` `session_of` (~l.543-548) | the log's size and last-modified time shown in the session record | size and mtime of the raw log `session.jsonl` | `log_stat` |
| `status.sh` (~l.43-45) | a live session's log size (`du -h`) and last write (`date -r`) | size and mtime of the raw log | `log_stat` |
| `usage.py` `readings` (~l.33) | skips sessions whose log was not written in the last 7 days | mtime of the raw log (not of `events.jsonl`, whose mtime changes on a rebuild) | `log_stat` |
| `loop.sh` `stop_idle` (~l.415-421) | stops an idle session: `pgrep -P` and TERM to the children of `run-session.sh` (the agent CLI; the recorder ignores TERM) | the process tree of the scheduler's own `run-session.sh` | none: `run-session.sh`'s process is the scheduler's own, not the harness's |
| `loop.sh` `resume_idle` (~l.448-449) | the argv and cwd of the idle `run-session.sh`, to start it again | `/proc/<pid>/cmdline` and `cwd` of the scheduler's own `run-session.sh` | none: `run-session.sh`'s process is the scheduler's own, not the harness's |
| `run-session.sh` | one unattended session: forge tokens unset, start or resume, `session.rc` written atomically | the start prompt and `unattended.md`, or the session id and `resume-prompt.md` | `start`, `resume` |
| `usage.py` `readings` (~l.28-50) | the plan's usage windows of every session changed in the last 7 days | each usage reading: windows, status, utilization, reset | `events` |
| `api.py` `session_alive` (~l.245-255) | whether a node or issue unit has a live session | `/proc/<pid>/cmdline` | `matches` |
| `api.py` `at_limit` (~l.258-298) | a live session idle at the usage limit (the idle-limit state) | the last line of the log, usage status and reset time | `events` |
| `api.py` `scan_log` (~l.444-513) | the session's last events, pending wakeup, background tasks, last rejection | tool uses (time, text, name, subagent, wakeup delay, background), tool results (background id), task completions, results (subtype), usage rejections (reset) | `events` |
| `api.py` `session_of` (~l.537-560) | the session record the API shows | the log through `scan_log`, the pid file through `session_alive` | `events` |
| `report.py` process match (~l.286-289) | the running sessions listed on the status issue | `/proc/<pid>/cmdline` | `matches` |
| `report.py` `narration` (~l.293-319) | the orchestrator's latest text and the subagent it waits on | text of the orchestrator, running `Agent` or `Task` tool uses against their results, result subtypes | `events` |
| `report.py` `last_result` (~l.322-333) | the closing message of a session | the last result's text | `events` |
| `report.py` `cost_turns`, `cost_text` (~l.348-380; callers ~l.511, 513, 792, 1260) | cost and turns of a task's sessions | cost and turns of the well-formed results of the whole log | `events` |
| `site.py` `alive` (~l.153-166) | whether a unit's session is live, for the status site | `/proc/<pid>/cmdline` | `matches` |

## Event schema

`events.jsonl`: one JSON object per line, always with `t` (the raw line's `timestamp` string verbatim, else null; never
the wall clock, so that a rebuild equals the live file) and `type`. A line with several blocks gives several events, in
order. Readers must not rely on more fields than listed.

| Type | Fields | One per |
|---|---|---|
| `start` | `session` | init line of the harness: the session id (a resumed session has one more per resume) |
| `usage` | `status`, `has_status`, `info_bad`, `reset`, `window`, `utilization`, `windows` | usage reading; `status` is null both when absent and when null, `has_status` tells them apart (absent counts as allowed); `info_bad` is true when `rate_limit_info` is present but no object (the readers treat the line as unreadable); `windows` maps each window name to `{status, has_status, utilization, reset}` |
| `tool` | `id`, `name`, `text`, `text_full`, `label`, `subagent`, `background`, `delay`, `desc` | tool use; `text` the first line of its short input (cut to 200), `text_full` the same line uncut (api.py redacts, then cuts), `label` for the status script (cut to 100), `background` for a background `Bash` or `Agent`, `delay` of a `ScheduleWakeup` (a bool counts as 0 or 1), `desc` of an `Agent` or `Task` |
| `tool_result` | `id`, `subagent`, `bg_id` | tool result; `bg_id` the background task id it names |
| `text` | `text`, `subagent` | text block, whitespace collapsed, cut to 400 |
| `result` | `subtype`, `text`, `cost`, `turns`, `limit` | end of a turn: closing text, cost and turns when well formed (`turns`: a non-negative int that fits a float; `cost`: a finite number that fits a float; else null), whether it names a usage limit |
| `task_done` | `ids` | background task completion |
| `cutoff` | none | session end with background tasks stopped by the CLI (last, once) |
| `other` | none | well-formed line that gave no other event (so the last event is the last line) |
| `garbled` | none | non-blank line that is no JSON object, or that cannot be read or translated (nested too deeply to parse, say); the last line is unknown |

## Across harnesses

One row per operation of `harness.py` and per event type. Claude Code is implemented; Codex, Pi and OpenCode are
described from their documentation only, not tried. "none: capability off" means the harness has no such thing and the
loop turns the feature off (`harness <name> lacks <capability>: <feature> off`).

| Row | Claude Code | Codex | Pi | OpenCode |
|---|---|---|---|---|
| `op:start` | `claude -p <prompt> --output-format stream-json --verbose --plugin-dir <dir> --append-system-prompt <text>` ([headless](https://code.claude.com/docs/en/headless)) | `codex exec --json <prompt>`, JSONL on stdout ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `pi -p <prompt>` (final text only) or `pi --mode json <prompt>` (JSON lines) ([cli](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)) | `opencode run "<prompt>"`; machine-readable output: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `op:resume` | `claude -p <prompt> --resume <id>` ([cli-reference](https://code.claude.com/docs/en/cli-reference)) | `codex exec resume <session id> <prompt>`, or `--last` ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `--session <path or id>` (non-interactive) or `-c`/`--continue` (latest for the directory) ([cli](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)) | resume for `run`: not documented: capability off ([cli](https://opencode.ai/docs/cli/)) |
| `op:skill_command` | `/noodlebot:node B03`, or `/node B03` for a shipped skill ([skills](https://code.claude.com/docs/en/skills)) | `$skill-name` in the prompt; skills are folders in `.agents/skills` ([build-skills](https://learn.chatgpt.com/codex/build-skills)) | `/skill:name args` in the prompt; folders with a SKILL.md ([skills](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/skills.md)) | `@skill-id` names a skill; the model loads it with its `skill` tool ([skills](https://opencode.ai/docs/skills/)) |
| `op:matches` | `run-session.sh ... <unit>` or `claude -p /node <unit>` in `/proc/<pid>/cmdline` ([cli-reference](https://code.claude.com/docs/en/cli-reference)) | `run-session.sh ... <unit>` (the scheduler's own wrapper; the harness's command line is not matched) ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `run-session.sh ... <unit>` (the scheduler's own wrapper) ([cli](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)) | `run-session.sh ... <unit>` (the scheduler's own wrapper) ([cli](https://opencode.ai/docs/cli/)) |
| `op:preflight` | `~/.config/noodlebot/oauth-token` readable, passed as `CLAUDE_CODE_OAUTH_TOKEN` ([cli-reference](https://code.claude.com/docs/en/cli-reference)) | its login or an API key in the environment (not checked here) ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | a provider API key in the environment or its login (not checked here) ([cli](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md)) | `opencode auth login` (interactive), or a provider API key in the environment ([providers](https://opencode.ai/docs/cli/providers/)) |
| `op:log_stat` | the raw log `session.jsonl` itself: its path, size and mtime ([headless](https://code.claude.com/docs/en/headless)) | the log of the JSON lines of `--json`, a file of the scheduler's ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | the log of the JSON lines of `--mode json`, a file of the scheduler's ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | the log of the command's output, a file of the scheduler's ([cli](https://opencode.ai/docs/cli/)) |
| `op:events` | stream-json lines translated by `claude_code.py` into `events.jsonl` ([headless](https://code.claude.com/docs/en/headless)) | the JSON lines of `--json` translated the same way ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | the JSON lines of `--mode json` translated the same way ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | machine-readable event output: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `op:capabilities` | `usage`, `resume`, `bg-wait` all on ([cli-reference](https://code.claude.com/docs/en/cli-reference)) | `resume` only; `usage` and `bg-wait`: none: capability off ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `resume` only; `usage` and `bg-wait`: none: capability off ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | none yet (`resume`: not documented, `usage` and `bg-wait`: none): capability off ([cli](https://opencode.ai/docs/cli/)) |
| `event:start` | `system` init line, `session_id` ([headless](https://code.claude.com/docs/en/headless)) | `thread.started` event; its id field: not documented ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | the first record, `{"type":"session","id":...}` ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | session id in the output: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `event:usage` | `rate_limit_event`, `rate_limit_info` ([headless](https://code.claude.com/docs/en/headless)) | none: capability off (plan-limit readings: not documented) ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | none: capability off (plan-limit readings: not documented) ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | none: capability off ([cli](https://opencode.ai/docs/cli/)) |
| `event:tool` | `tool_use` block of an `assistant` line ([headless](https://code.claude.com/docs/en/headless)) | `item.*` events of a command execution, file change, MCP tool call or web search ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `tool_execution_start` / `_update` / `_end` events ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | tool events: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `event:tool_result` | `tool_result` block of a `user` line ([headless](https://code.claude.com/docs/en/headless)) | the completed `item.*` event of that command or tool ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | the `tool_execution_end` event ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | tool results: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `event:text` | `text` block of an `assistant` line ([headless](https://code.claude.com/docs/en/headless)) | an agent message `item.*` event ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `message_update` events ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | message events: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `event:result` | the `result` line: `result`, `total_cost_usd`, `num_turns`, `subtype` ([headless](https://code.claude.com/docs/en/headless)) | `turn.completed` with token usage (input, cached, output, reasoning); no cost or turn count: left null; `turn.failed` and `error` for failures ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | `agent_end`; cost from the cumulative `usage` (`cost.total`) of `message_update`; turns: the `turn_end` events counted ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | result and cost: not documented: left null ([cli](https://opencode.ai/docs/cli/)) |
| `event:task_done` | `system` line with subtype `task_notification` ([headless](https://code.claude.com/docs/en/headless)) | none: capability off ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | none: capability off ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | none: capability off ([cli](https://opencode.ai/docs/cli/)) |
| `event:cutoff` | the CLI's stderr line "background tasks still running ... after the last turn ... stopping them" ([cli-reference](https://code.claude.com/docs/en/cli-reference)) | none: capability off ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | none: capability off ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | none: capability off ([cli](https://opencode.ai/docs/cli/)) |
| `event:other` | any well-formed stream-json line that gave no other event ([headless](https://code.claude.com/docs/en/headless)) | any well-formed JSON line of `--json` that gave no other event ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | any well-formed JSON line that gave no other event ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | lines of machine-readable output: not documented ([cli](https://opencode.ai/docs/cli/)) |
| `event:garbled` | a non-blank line that is no JSON object, a cut last line included ([headless](https://code.claude.com/docs/en/headless)) | the same rule on `--json` output ([non-interactive](https://learn.chatgpt.com/docs/non-interactive-mode)) | the same rule on `--mode json` output ([json](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/json.md)) | the same rule, if there is such output (not documented) ([cli](https://opencode.ai/docs/cli/)) |
