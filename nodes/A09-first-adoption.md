# A09 — first-adoption

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | A07, A08 | none | M |

**Owns:** the record of the run, `plugin/skills/adopt/first-adoption.md` (new); fixes to `plugin/skills/adopt/SKILL.md`
and `scheduler/unattended-adopt.md` that the run shows are needed, each made test-first with its case in
`plugin/skills/adopt/adopt.test.sh`.

## Purpose
After this node a real repository has been adopted end to end by the deployed loop, and the record shows what it took.
The fakes prove the loop's and the skill's logic; only a real repository shows whether the inventory's areas, the
questions, the area sessions' imported nodes and the plan hold up. Whatever the run shows is wrong in the adopt skill
or its template is fixed here, test-first.

## Tests
- `plugin/skills/adopt/adopt.test.sh` (extended): one case per fix the run makes to the skill or the template.
- The recorded run (A09-AC-1, A09-AC-2).

## Changes
1. **The run.** The session asks the owner, as its first question, which repository to adopt (with a recommendation of
   a small one on the loop's list or to be added to it). Once the owner has added it to `~/.config/noodlebot/repos`, the
   loop adopts it: the first PR, one PR per area, the plan PR, each merged by the owner. *A09-AC-1.*
2. **The record.** `plugin/skills/adopt/first-adoption.md` lists every adoption PR with its link, the areas and how
   many imported nodes each gave, the gate and its `known_red`, the questions asked and answered, the output of
   `check-regime.py` and `check-coverage.py` on the final `main`, and what went wrong. *A09-AC-2.*
3. **Fixes.** Each problem the run shows in the skill or the template is fixed test-first in this node's PR, with its
   case in `adopt.test.sh`; a problem elsewhere is reported to the owner as a question or an issue. *A09-AC-2.*

## Gate
- **A09-AC-1** — A real repository the owner chose was adopted by the deployed loop from no graph to a graph without `adoption`, through the first PR, one PR per area and the plan PR, all merged. *Verify:* the record's PR links.
- **A09-AC-2** — The record holds every adoption PR's link, the areas and their nodes, the gate, the questions, and `check-regime.py` and `check-coverage.py` reporting `PROBLEMS 0` on the final `main`; each fix to the skill or template has its case. *Verify:* `plugin/skills/adopt/first-adoption.md` and `sh plugin/skills/adopt/adopt.test.sh`.

## Risks
- The run takes as long as the owner's merges: one PR per area. The node's session waits between them with a
  `QUESTION.md` only (a `WAITING-PR` would name another repository's PR, which this repository's loop cannot track),
  and may need several starts.
- The chosen repository's code is read by sessions; the owner chooses one whose contents may be.
