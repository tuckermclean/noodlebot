# A07 — adopt-loop

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A04, A06 | none | L |

**Owns:** in `scheduler/loop.sh`, the adoption units (when one starts, its state, its end); the session template
`scheduler/unattended-adopt.md` (new); the adoption kind in `scheduler/turn.py`; the adoption home issue in
`scheduler/report.py`; in `scheduler/issues.py`, triage waiting while an adoption is in progress; in
`plugin/skills/adopt/SKILL.md`, the `--area <name>` and `--plan` modes; the new test `scheduler/loop-a07.test.sh` and its
line in the `Makefile`'s `TESTS`, with its fixtures under `scheduler/testdata/`; their cases in
`scheduler/turn.test.sh`, `scheduler/report.test.sh` and `plugin/skills/adopt/adopt.test.sh`.

## Purpose
After this node the loop adopts a repository by itself, from the first PR to a complete graph. A repository on the
loop's list with no graph on its main branch gets the adoption's first session (A06). Once that PR is merged, the
loop maps the code one area at a time: each area's session reads only that area, writes imported nodes that own its
files, and opens one spec PR that also takes the area off the graph's list. When no area is left, one last session
turns the open issues into planned nodes. Each step waits for the owner's merge, and the graph on `main` is the only
record of how far the adoption has got, so nothing is lost when the machine or the loop changes.

## Tests
- `scheduler/loop-a07.test.sh` (new), with the fake forge and harness:
  - a repository with no graph on `origin/main`: one adoption session (`adopt/scaffold`), its prompt naming the
    repository and the skill; no second start while its spec PR is open; nothing more after it ends with a question;
  - a graph with two areas: one session for the first area, its prompt naming the area, its glob and the inventory
    command; after that area's PR is merged (the area gone from the graph), one session for the second; an area whose
    open PR waits starts nothing;
  - a graph with `adoption` and no area left: one `adopt/plan` session; after its PR is merged (no `adoption`),
    nothing;
  - an adoption PR closed without merging: that unit held by `FAILED` naming the PR;
  - a labelled issue while an adoption is in progress: no triage, one status-log line; triaged after the adoption
    ends;
  - an adoption unit and a triage share the one slot.
- `scheduler/turn.test.sh` (extended): the adoption kind goes with triages in the start queue.
- `scheduler/report.test.sh` (extended): an adoption unit's home issue "Adopt <name>" (labelled `noodlebot-unit`)
  gets its milestones and questions.
- `plugin/skills/adopt/adopt.test.sh` (extended): the `--area` and `--plan` modes' text, and a dry run of `--area` on
  the fixture whose output passes `check-regime.py` and `check-coverage.py`.
- A recorded real adoption, from the first PR to the plan PR, of a repository the owner chooses (A07-AC-5).

## Changes
1. **When an adoption unit starts.** Each tick, from the graph on `origin/main`:
   - no `docs/graph.yaml`: the unit `adopt/scaffold` (`/noodlebot:adopt <repo>`, A06), unless an open `spec/adopt` PR
     exists;
   - `adoption` with areas: the unit `adopt/<area name>` for the first area in the list that has no open
     `spec/adopt-<area name>` PR (`/noodlebot:adopt --area <name>`);
   - `adoption` with no area left: the unit `adopt/plan` (`/noodlebot:adopt --plan`).
   At most one adoption session runs at a time, in the triage's slot, through the start queue. A unit's state is
   `state/<name>/adopt/<key>/` with the usual markers: a question holds it until it is answered, its PR is waited for
   with `WAITING-PR`, and a PR closed without merging writes `FAILED`. *A07-AC-1, A07-AC-2.*
2. **Mapping an area** (`--area <name>`). The session runs `inventory.py` for the area, reads the area's files (and
   only those), and writes one or more imported nodes:
   - each node owns part of the area's files (together, all of them, each file once);
   - its spec describes what the code does: Purpose, the existing tests under Tests, "none: imported" under Changes,
     and criteria of current behaviour, each *Verify* naming the existing test that shows it or reading `unpinned`;
   - deps on the already-mapped nodes whose code it relies on;
   - the area removed from `adoption.areas`, and any further `out_of_scope` entries with reasons.
   `check-regime.py` and `check-coverage.py` report `PROBLEMS 0`, `check-spec-diff.py` passes, and one spec PR
   `spec/adopt-<name>` is opened. It writes no code and no tests. *A07-AC-3.*
3. **The plan** (`--plan`). The session reads the open issues (closed ones as history), turns each into a planned
   node or a criterion of one (deps on the imported nodes whose code it changes, `owns` for the files it will add,
   **Resolves:** the issue), removes `adoption` from the graph, and opens `spec/adopt-plan`, with the same checks.
   *A07-AC-3.*
4. **Triage waits** while the graph is missing or has `adoption`: a labelled issue is triaged once the adoption ends
   (the plan session has read it already, and the triage then finds it covered). *A07-AC-4.*
5. **Home issue.** Every adoption unit's milestones and questions go to one issue, "Adopt <name>", labelled
   `noodlebot-unit`, opened by the loop. *A07-AC-2.*
6. **The session template** `scheduler/unattended-adopt.md` names the repository, the unit, the skill's mode, the area
   and its glob, the state folder and the forge CLI, and ends the run with a spec PR plus `WAITING-PR`, or one
   `QUESTION.md`. It never merges. *A07-AC-1.*

## Gate
- **A07-AC-1** — A repository with no graph gets one `adopt/scaffold` session whose prompt names the repository and the skill, and none while its spec PR is open. *Verify:* `bash scheduler/loop-a07.test.sh`.
- **A07-AC-2** — Areas are mapped one at a time in list order, each after the previous area's PR is merged, then one plan session; a question holds a unit, a PR closed without merging fails it, and each unit reports on the "Adopt <name>" issue. *Verify:* `bash scheduler/loop-a07.test.sh` and `sh scheduler/report.test.sh`.
- **A07-AC-3** — A dry run of `--area` on the fixture writes imported nodes that together own exactly the area's files, removes the area from the graph, and passes `check-regime.py` and `check-coverage.py`; the `--plan` text turns open issues into planned nodes and removes `adoption`. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A07-AC-4** — A labelled issue is not triaged while an adoption is in progress, and is triaged after it. *Verify:* `bash scheduler/loop-a07.test.sh`.
- **A07-AC-5** — A real repository chosen by the owner is adopted end to end: the first PR, one PR per area, the plan PR, every one passing `check-regime.py` and `check-coverage.py`. *Verify:* the recorded run, with the PR links, in this node's PR.

## Risks
- A repository with many areas takes many PRs; one at a time keeps each reviewable, and the owner can merge an area
  PR as soon as it is right. Merging them is the throttle.
- An area session may need to read a file outside its area to understand it; it may read it, but it owns only its
  area's files, and the coverage check holds it to that.
- Imported criteria describe behaviour as the session read it. `unpinned` marks what no test shows; A08's pins are
  how a later change makes it certain.
- Adopting starts as soon as a repository without a graph is on the list. A repository listed by mistake gets one
  first-PR session, which waits on the owner's answers before anything else.
