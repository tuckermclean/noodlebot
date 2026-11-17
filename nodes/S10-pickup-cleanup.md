# S10 — pickup-cleanup

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | S09 | none | S |

**Owns:** in `scheduler/harnesses/claude_code.py`, the arguments of `small_start` (the pickup run's command), with its
conformance case in `scheduler/harness.test.sh`; in `scheduler/pickup.py`, the removal of finished run folders and its
line in the module's docstring; their cases in a new `scheduler/pickup-s10.test.sh` (its own file, to keep the existing
pickup files under `TEST_FILE_BUDGET`) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #139

## Purpose
After this node a pickup run leaves nothing behind. Today the Claude Code backend's `small_start` runs `claude -p`
without `--no-session-persistence`, so each pickup run (up to `PICKUP_RUNS`, 12, per 5-hour window) leaves a
transcript under the harness's home (`~/.claude/projects`), and `pickup.py` never removes the run folders it makes
under its state. Afterwards the small run writes no transcript, and a finished run's folder is removed once it is seven
days old, so the runtime's state stays bounded. Seven days, not fewer: `scheduler/usage.py` reads the usage events of
`pickup/*` run folders for up to a week (`WEEK`), so a folder removed sooner would drop its usage from the weekly
reading.

## Tests
- `scheduler/harness.test.sh` (extended): the Claude Code backend's small start passes `--no-session-persistence`
  (seen in the fake `claude`'s recorded arguments) and keeps the other arguments it passes today; a node session's start
  and resume are unchanged.
- `scheduler/pickup-s10.test.sh` (new), with the fake harness: a finished run (every decision carried out, every reply
  posted) whose last change (the newest mtime of any file in its folder, the folder's own included) is more than seven
  days old is removed at the next pickup step; a finished run whose folder is older but holds a file changed within
  seven days is kept; a run with a reply still to retry is kept whatever its age, and removed once that reply is posted
  and seven days have passed; the handled record and the budget record (`pickup.json`) are untouched, so a removed run's items are never
  picked up again and its run still counts in its window.

## Changes
1. **No transcript.** `small_start` passes `--no-session-persistence`; nothing else about the pickup run's command
   changes. *S10-AC-1.*
2. **Run folders removed.** At each pickup step, after replies that failed earlier are retried, `pickup.py` removes each
   of its run folders whose decisions are all carried out and whose replies are all posted, and whose last change is
   more than seven days old. A run folder's last change is the newest mtime of the folder and every file in it (the
   raw log `usage.py` dates a run by among them), so a folder is never removed while `usage.py` still counts it. A run
   with anything left to do is kept. The handled record and the budget record are what the
   later steps read; neither is in a run folder. *S10-AC-2.*

## Gate
- **S10-AC-1** — The Claude Code backend's small start passes `--no-session-persistence` and otherwise the same arguments as before; node starts and resumes are unchanged. *Verify:* `sh scheduler/harness.test.sh`.
- **S10-AC-2** — A finished pickup run's folder is removed at the first pickup step more than seven days after its last change (the newest mtime in the folder); a younger one (an old folder with a file changed within seven days among them), and one with a reply still to retry, are kept; a removed run's items are not picked up again and its run still counts in its budget window; the existing pickup tests pass unchanged. *Verify:* `sh scheduler/pickup-s10.test.sh`, `sh scheduler/pickup.test.sh`, `sh scheduler/pickup-retry.test.sh` and `sh scheduler/pickup-window.test.sh`.

## Risks
- Transcripts the earlier pickup runs left under `~/.claude/projects` stay; removing them is a one-time cleanup by hand.
- Seven days of run folders are kept, for `usage.py`'s weekly reading and to diagnose a wrong decision; a decision
  found wrong later than that has only the status log and the replies on the forge.
- `--no-session-persistence` is a Claude Code flag; another backend's small start has its own way, or none needed.
