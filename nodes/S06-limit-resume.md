# S06 — limit-resume

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | T01, S04 | none | M |

**Owns:** the check for idle sessions stopped by the usage limit and the conversation resume in `scheduler/loop.sh`, the resume mode of `scheduler/run-session.sh` (`claude -p --resume <session id>`), the resume prompt `scheduler/limit-resume.md`, their cases in `scheduler/loop.test.sh`.
**Resolves:** #45

## Purpose
After this node a session that the usage limit leaves alive but idle no longer holds its slot until its own wakeup fires. Such a session might be waiting on a `ScheduleWakeup`, a background command or a Monitor when the limit rejects its next call. Each tick the loop looks at every running node, triage and update session. When a session's log ends with the limit rejection, that window reset more than 2 minutes ago and the throttle is open, the loop stops the session's process and resumes the same conversation in a new one (`claude -p --resume <session id>`). The resume prompt says that the limit stopped the session, that the window has reset and that its background agents and commands were killed. The session keeps its context, which an S04 restart loses. When the conversation cannot be resumed, the session ends as a limit exit and is restarted the usual way. Neither path uses a start.

## Tests
- `scheduler/loop.test.sh` (extended), in a loop run of its own with its own fixture and fake `claude`, so no existing line changes. The fake records its arguments. Its sessions do the following:
  - write a `system/init` line with a session id, a `rate_limit_event` with a status other than `allowed` and a `resetsAt`, and then sleep;
  - the same, with the rejection followed by a `result` naming the usage limit;
  - the same, with a `resetsAt` less than 2 minutes in the past;
  - the same, after which they write further lines, so they are working again;
  - the same, with no `system/init` line;
  - the same, where the resumed fake exits at once with a non-zero code and writes no `system/init` line.
- The cases run for a node session, a triage session and an update session, and once with the throttle held. Each case checks:
  - the processes;
  - the arguments and prompt of the next `claude` process;
  - `starts`;
  - the status log;
  - the session log;
  - the worktree.

## Changes
1. **The loop finds sessions the usage limit left idle.** A helper (beside T01's `limit_exit`) reports whether a running session's `session.jsonl` shows the limit on its last line: either a `rate_limit_event` whose status is not `allowed`, or a `result` naming a usage limit (as `limit_exit` reads it). The helper also prints the session's reset time: the `resetsAt` of the log's last `rate_limit_event` whose status is not `allowed`. A log whose last line is anything else is not idle by the limit, because the session is working again. Neither is a log with no such event, because its reset time is unknown. *S06-AC-1.*
2. **The loop resumes a session idle past the reset.** The resume happens when four things hold for a running node, triage or update session: the helper reports it idle, its reset time is more than 2 minutes in the past, the throttle is open (T01), and the session has not been resumed for that reset time before (the reset time is recorded in the session's state folder). The loop then does the following:
   - It stops the session's `claude` process, so `run-session.sh` writes `session.rc`.
   - It ends whatever is left of the session's process group.
   - It starts `run-session.sh` again in the same worktree and state folder, in its resume mode. That mode runs `claude -p "<prompt>" --resume <session id>` with the same plugin, permission and output options and the same `unattended.md`. The session id comes from the log's last `system/init` line, and the prompt from `scheduler/limit-resume.md`. The new output is appended to the same `session.jsonl`.
   - It records the new pid in `session.pid`, so later ticks treat the new process as the same session and handle its end with `ended`, `triage_ended` or `update_ended` as usual.
   - It neither counts a start nor runs S04's leftover step (the worktree is left as it is).
   - It writes one status-log event naming the session and its reset time.

   *S06-AC-2, S06-AC-3.*
3. **The resume prompt.** `scheduler/limit-resume.md` tells the run four things: the usage limit stopped it and the window has reset (at the reset time); the background agents, background commands and Monitors it had started were killed; it should check what they left (files, commits, CI runs) and re-dispatch only what it still needs; and it should then carry on with its task. *S06-AC-2.*
4. **The restart is the fallback.** If the log has no `system/init` line with a session id, the loop does not resume. It stops the session as in change 2, and the session ends as a limit exit: its start is given back, and the next start is the usual one (for a node, S04's resume). A resumed process that exits without writing a `system/init` line to the log is handled the same way. Each case is one status-log event naming the session and saying the resume was not possible. *S06-AC-4.*
5. **A session that is working again, or held by the throttle, is left alone.** A session whose log moved on after the rejection is not stopped, nor is one whose reset time is less than 2 minutes in the past. While the throttle holds, no session is stopped or resumed: the resume waits like any start. *S06-AC-1, S06-AC-5.*

## Gate
- **S06-AC-1** — A running session is left running when its `session.jsonl` contains a `rate_limit_event` whose status is not `allowed` and its last line is such an event or a `result` naming the usage limit, as long as the last such event's `resetsAt` is less than 2 minutes in the past. A session whose log has further lines after that last line is left running at any time. *Verify:* `scheduler/loop.test.sh`.
- **S06-AC-2** — Once that reset time is more than 2 minutes in the past and the throttle is open, the loop acts on a node, triage or update session that is idle in that way, within a tick. It stops the session: its `session.rc` is written and no process of its old process group is left. It then starts `claude` again in the same worktree with `--resume <the session id from the log's system/init line>`. The prompt says that the usage limit stopped the session and has reset, that its background agents and commands were killed, and that it should check what they left, re-dispatch what it still needs, and carry on. The new output is appended to the same `session.jsonl`. The session's `starts` is unchanged, its worktree is unchanged (no leftover patch), and the status log has one event naming the session and the reset time. *Verify:* `scheduler/loop.test.sh` (the fake's recorded arguments and prompt).
- **S06-AC-3** — After the resume, the loop treats the new process as the session. While the process runs, no other session of that node, issue or PR is started. When it ends, its end is reported by the usual path (with a PR, a QUESTION.md, done, a limit exit, and so on). A session is resumed at most once for the same reset time. *Verify:* `scheduler/loop.test.sh`.
- **S06-AC-4** — A session idle in that way whose log has no session id is stopped without a resume. So is one whose resumed `claude` exits without writing a `system/init` line. Either one ends as a limit exit: `starts` is unchanged, there is no FAILED, and the session starts again by the usual path at a later tick. The status log has one event naming the session and saying it could not be resumed. *Verify:* `scheduler/loop.test.sh`.
- **S06-AC-5** — While the throttle holds, a session idle in that way is neither stopped nor resumed, even past its reset time. Once the throttle releases, it is resumed as in S06-AC-2. *Verify:* `scheduler/loop.test.sh`.

## Risks
- `claude -p --resume` in a fresh process has not been tried for a stream-json session with a plugin loaded and an appended system prompt. The fallback covers a resume that fails to start, not a resumed session that misbehaves. Whether `--resume` keeps the session id or gives it a new one is also unverified; the loop reads the id from the log's last `system/init` line either way.
- A session waiting on a long CI run is stopped and resumed. It must find the run again, which the prompt tells it to do, but whether it does is session behaviour that the test with fakes cannot show.
- A session whose log names the limit only in a `result`, with no rejected `rate_limit_event`, has no known reset time and is left idle as before.
- The `rate_limit_event` and `system/init` line formats are what the CLI writes today. They are not verified as a stable interface. If they change, idle sessions are not found and stay idle as before.
- Stopping the session kills whatever its background commands were doing mid-way. Their half-done work stays in the worktree for the resumed session to examine.
