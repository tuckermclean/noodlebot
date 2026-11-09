# S02 — bg-wait

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | T01 | none | S |

**Owns:** the background-wait setting in `scheduler/run-session.sh`, the recognition of a background cut-off in the end-of-session paths (`ended`, `triage_ended`) of `scheduler/loop.sh`, their cases in `scheduler/loop.test.sh`.
**Resolves:** #29

## Purpose
After this node a session waiting on its own background work (a subagent, a CI watch) is not stopped by Claude Code ten minutes after its last turn: `run-session.sh` starts every session with `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` set, by default to 0 (wait as long as the work runs). If a session is still stopped that way, the loop recognises it from the CLI's message in `session.stderr` and treats it like a usage-limit exit: the start is given back, the end is one status-log event that says so, and a triage stopped that way is not taken for a finished one. Noticing a session that waits forever on a dead task stays with issue #13.

## Tests
- `scheduler/loop.test.sh` (extended): the fake `claude` records the value of `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` in its environment; further fake sessions write the CLI's cut-off message ("Background tasks still running … after the last turn …; stopping them.") to stderr and exit, with rc 0 and with a non-zero rc. Cases: the default value; a value set in the loop's environment passed through; a node session cut off on its second start (no FAILED, start given back, it starts again); a triage session cut off with rc 0 and no QUESTION.md (its label is not swapped, start given back); a session whose stderr has no such message ending as before.

## Changes
1. **`run-session.sh` sets the background-wait ceiling.** It exports `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` for the `claude` it starts: the value from its own environment when one is set, 0 otherwise. *S02-AC-1.*
2. **The loop recognises a background cut-off.** A helper (beside `limit_exit`) reports whether a session's `session.stderr` contains the CLI's message that it stopped background tasks still running after the last turn, whatever the session's exit code. *S02-AC-2, S02-AC-3.*
3. **A node session cut off gives its start back.** In `ended`, after the FAILED, QUESTION.md, WAITING-PR and PR checks and before the starts are counted, such a session's start is given back (`not_counted`, as for a limit exit) and the loop writes one status-log event naming the session, its exit code and that its background work was cut off, start not counted. *S02-AC-2.*
4. **A triage session cut off is not done.** In `triage_ended`, after the QUESTION.md check and before an exit code of 0 is taken as done, such a session gives its start back the same way, with one status-log event; its label and worktree stay. *S02-AC-3.*

## Gate
- **S02-AC-1** — Every session `run-session.sh` starts has `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS` in its environment: 0 by default, or the value set in the loop's environment. *Verify:* `scheduler/loop.test.sh`.
- **S02-AC-2** — A node session that ends, with rc 0 or not, with no PR and no QUESTION.md, after the CLI wrote to its `session.stderr` that it stopped background tasks still running after the last turn, uses up no start (on its second start it writes no FAILED and the node starts again at the next tick), and the end is one status-log event saying its background work was cut off and the start not counted. A session that ends the same way without that message is counted as before. *Verify:* `scheduler/loop.test.sh`.
- **S02-AC-3** — A triage session that ends with rc 0 and no QUESTION.md after that message is not treated as done: its issue keeps its label and its worktree, its start is given back, and the end is one status-log event saying so. *Verify:* `scheduler/loop.test.sh`.

## Risks
- The cut-off message and the variable's name are what the CLI uses today (seen 2026-11-09 in a real session's stderr; unverified as a stable interface). If the message changes, a cut-off session is counted as before; if the variable is ignored, sessions are cut off as before and recognised.
- With a ceiling of 0 a session waiting on a task that never ends waits forever and holds its slot; only issue #13 would make that visible.
- A session cut off again on every start gives its start back every time, so it is never held by FAILED; the status log shows each such end.
- A cut-off session's half-done edits stay uncommitted in its worktree; the next start finds them there.
