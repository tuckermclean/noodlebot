# A11 — adopt-pr-answers

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A07, G01, G03 | none | S |

**Owns:** in `scheduler/loop.sh`, the rendering of a `spec/adopt*` PR's update prompt (`start_update`) and feedback
prompt (`start_feedback`) with the scaffold unit's `answered/` folder; in `scheduler/unattended-update.md` and
`scheduler/unattended-feedback.md`, the line (or placeholder) that names that folder; `scheduler/loop-a11.test.sh`
(new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #211

## Purpose
After this node a session that updates or answers feedback on an adoption's PR (`/noodlebot:adopt --update` or
`--feedback`, state in `state/<name>/pr/<N>/`) is told where the owner's answers to the first adoption PR's questions
are kept, `state/<name>/adopt/scaffold/answered/`, as the adoption units' own prompt already tells the area and plan
sessions (`@DIR@/../scaffold/answered/` in `scheduler/unattended-adopt.md`). The adopt skill says those answers bind
every later step. Today these sessions find them only in the replies on the "Adopt <name>" issue. The prompts of
other spec PRs and of node PRs do not change.

## Tests
- `scheduler/loop-a11.test.sh` (new), with the fake forge and the shared helpers of `scheduler/testdata/lib/` (as the
  `loop-a07*` files use them): a `spec/adopt-<area>` PR that conflicts with `main` gets an update session whose prompt
  (`pr/<N>/unattended.md`) names the scaffold unit's `answered/` folder by its absolute path; a `spec/adopt*` PR with
  new owner feedback gets a feedback session whose prompt names it too; a `spec/triage-*` PR's update or feedback
  prompt does not name it; and no rendered prompt holds a leftover `@...@` placeholder. The file waits for each
  session's prompt rather than sleeping, and stays under `TEST_FILE_BUDGET` (30 s).
- The existing `scheduler/loop-a07*.test.sh`, `scheduler/loop-g01*.test.sh` and `scheduler/loop-g03*.test.sh` cases pass
  unchanged.

## Changes
1. **The prompts name the folder.** For a `spec/adopt*` branch (`is_adopt_br`), `start_update` and `start_feedback`
   render the template with a line naming `$state/adopt/scaffold/answered/` (if present) as where the owner's answers to the
   first adoption PR's questions are kept, to be read with the replies on the "Adopt <name>" issue. For any other
   branch the line is empty. The templates hold that line's placeholder (or the loop adds the line), and every
   other line of both templates stays as it is. *A11-AC-1, A11-AC-2.*

## Gate
- **A11-AC-1** — The update and feedback sessions of a `spec/adopt*` PR get a prompt that names the absolute path of `state/<name>/adopt/scaffold/answered/` as where the owner's answers to the first adoption PR's questions are kept. *Verify:* `bash scheduler/loop-a11.test.sh`.
- **A11-AC-2** — The update and feedback prompts of a `spec/triage-*` PR do not name that folder, and no rendered prompt holds a leftover `@...@` placeholder; the existing A07, G01 and G03 loop cases pass unchanged. *Verify:* `bash scheduler/loop-a11.test.sh` and `make test`.

## Risks
- The scaffold unit's state folder is kept by the loop while the adoption runs. Once the adoption ends it may be
  gone, and a late update session then gets a path that does not exist. The line names the folder "if present",
  and the "Adopt <name>" issue still holds the answers.
- `unattended-feedback.md` also renders node feedback prompts (`start_feedback` with a node). The placeholder must
  render empty there, which the leftover-placeholder check covers for the triage case only. The implementer checks
  the node path too.
- `scheduler/loop.sh` is executed by running loops: it is replaced by a rename, never edited in place (SPEC §1.6).
- A new module of the loop would need copy lines in the frozen loop fixtures. This node adds none: it changes
  `loop.sh` and two templates that the fixtures already copy.
