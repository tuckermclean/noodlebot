# A07 — adopt-loop

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A04, A06 | none | L |

**Owns:** in `scheduler/loop.sh`, the adoption state read from `origin/main`, the adoption units (when one starts, its
worktree and state, its end), triage waiting during an adoption, and the routing of updates and feedback for
`spec/adopt*` PRs; the session template `scheduler/unattended-adopt.md` (new); the adoption kind in `scheduler/turn.py`;
the adoption home issue and its answers in `scheduler/report.py`; in `plugin/skills/adopt/SKILL.md`, the `--area
<name>`, `--plan`, `--update <N>` and `--feedback <N>` modes; the recorded `--area` dry run under
`plugin/skills/adopt/example-area/`; the new test `scheduler/loop-a07.test.sh` and its line in the `Makefile`'s
`TESTS`, with its fixtures under `scheduler/testdata/`; their cases in `scheduler/turn.test.sh`,
`scheduler/report.test.sh` and `plugin/skills/adopt/adopt.test.sh`.

## Purpose
After this node the loop adopts a repository by itself, from the first PR to a complete graph. A repository on the
loop's list with no graph on its main branch gets the adoption's first session (A06). Once that PR is merged, the loop
maps the code one area at a time: each area's session reads only that area, writes imported nodes that own its files,
and opens one spec PR that also takes the area off the graph's list. When no area is left, one last session turns the
open issues into planned nodes. Each step waits for the owner's merge, and the graph on `main` is the only record of
how far the adoption has got, so nothing is lost when the machine or the loop changes.

## Tests
- `scheduler/loop-a07.test.sh` (new), with the fake forge and harness:
  - a repository with no graph on `origin/main`: one adoption session (`adopt/scaffold`) in its own worktree, its
    prompt naming the repository and the skill; no second start while its spec PR is open; a question holds it, and
    the owner's reply on the "Adopt <name>" issue becomes its `ANSWER.md` and starts it again;
  - a graph with two areas: one session for the first area, its prompt naming the area, its globs and the inventory
    command; nothing for the second area while the first area's PR is open or its unit is held; after that PR is
    merged (the area gone from the graph), one session for the second;
  - a graph with `adoption` and no area left: one `adopt/plan` session; after its PR is merged (no `adoption`), nothing;
  - an adoption PR closed without merging: that unit held by `FAILED` naming the PR;
  - owner feedback on a `spec/adopt-<name>` PR, and that PR conflicting with main: an adopt session with `--feedback`
    or `--update`, not a triage;
  - a labelled issue while an adoption is in progress: `issues.py` not asked, one status-log line; triaged after the
    adoption ends;
  - an adoption unit and a triage share the one slot;
  - the loop running from a checkout without `unattended-adopt.md`: no adoption start, one status-log line, the tick
    carries on.
- `scheduler/turn.test.sh` (extended): the adoption kind goes with triages in the start queue.
- `scheduler/report.test.sh` (extended): the "Adopt <name>" issue (labelled `noodlebot-unit`) gets each adoption unit's
  milestones and questions, and an owner reply there is recorded as the open unit's answer.
- `plugin/skills/adopt/adopt.test.sh` (extended): the `--area`, `--plan`, `--update` and `--feedback` modes' text, and
  the recorded `--area` dry run under `example-area/` (made from `example-baseline/`), whose imported nodes together
  own exactly the area's files and which passes `check-regime.py` and `check-coverage.py`.
- A recorded real adoption, from the first PR to the plan PR, of a repository the owner chooses (A07-AC-6).

## Changes
1. **The adoption state.** Each tick, before the triage step, the loop reads `docs/graph.yaml` at `origin/main` (as it
   already reads YAML for spec-PR clashes):
   - no graph: the unit `adopt/scaffold` (`/noodlebot:adopt <repo>`, A06), unless an open `spec/adopt` PR exists;
   - `adoption` with areas: the unit `adopt/<name>` for the first area in the list (`/noodlebot:adopt --area <name>`);
     nothing starts while that area has an open `spec/adopt-<name>` PR or its unit is held (a question, `FAILED`);
   - `adoption` with no area left: the unit `adopt/plan` (`/noodlebot:adopt --plan`);
   - otherwise there is no adoption.
   At most one adoption session runs at a time, in the triage's slot, through the start queue. *A07-AC-1, A07-AC-2.*
2. **The unit.** Its state is `state/<name>/adopt/<key>/` with the usual markers (a question holds it until it is
   answered; its PR is waited for with `WAITING-PR`; a PR closed without merging writes `FAILED`). Its session works
   in `worktrees/<name>/adopt-<key>`, on `spec/adopt` (scaffold) or `spec/adopt-<key>` from `origin/main`, removed once
   the PR is merged or closed. Its milestones and questions go to one issue, "Adopt <name>", labelled
   `noodlebot-unit`, opened by the loop; since one adoption unit is open at a time, an owner reply there answers it.
   *A07-AC-2.*
3. **Mapping an area** (`--area <name>`). The session runs `inventory.py --json --glob <glob>` for each of the area's
   globs and reads the area's files (it may read others to understand them, but maps only these). It writes one or
   more imported nodes:
   - each node owns part of the area's files (together, all of them, each file once);
   - its spec describes what the code does: Purpose, the existing tests under Tests, "none: imported" under Changes,
     and criteria of current behaviour, each *Verify* naming the existing test that shows it or reading `unpinned`;
   - deps on the already-mapped nodes whose code it relies on;
   - the area removed from `adoption.areas`, and any further `out_of_scope` entries with reasons.
   `check-regime.py` and `check-coverage.py` report `PROBLEMS 0`, `check-spec-diff.py` passes, and one spec PR
   `spec/adopt-<name>` is opened. It writes no code and no tests. *A07-AC-3.*
4. **The plan** (`--plan`). The session reads the open issues (closed ones as history), turns each into a planned node
   or a criterion of one (deps on the imported nodes whose code it changes, `owns` for the files it will add,
   **Resolves:** the issue), removes `adoption` from the graph, and opens `spec/adopt-plan`, with the same checks.
   *A07-AC-3.*
5. **Updates and feedback** on `spec/adopt*` PRs (a conflict with main, the owner's comments and reviews) start the
   adoption unit again with `--update <N>` or `--feedback <N>` instead of a triage. *A07-AC-4.*
6. **Triage waits** while the graph is missing or has `adoption`: the loop does not ask `issues.py` for a triage and
   logs one line. A labelled issue is triaged once the adoption ends (the plan session read it already, and the triage
   finds it covered). *A07-AC-5.*
7. **The session template** `scheduler/unattended-adopt.md` names the repository, the unit, the skill's mode, the area
   and its globs, the state folder and the forge CLI, and ends the run with a spec PR plus `WAITING-PR`, or one
   `QUESTION.md`. It never merges. A checkout without the template starts no adoption and logs it once. *A07-AC-1.*

## Gate
- **A07-AC-1** — A repository with no graph gets one `adopt/scaffold` session in its own worktree whose prompt names the repository and the skill, none while its spec PR is open, and none (one log line) when the template is missing. *Verify:* `bash scheduler/loop-a07.test.sh`.
- **A07-AC-2** — Areas are mapped one at a time in list order, the next only after the previous area's PR is merged, then one plan session; a question holds a unit and an owner reply on the "Adopt <name>" issue answers it; a PR closed without merging fails it. *Verify:* `bash scheduler/loop-a07.test.sh` and `sh scheduler/report.test.sh`.
- **A07-AC-3** — The recorded `--area` dry run writes imported nodes that together own exactly the area's files, removes the area from the graph, and passes `check-regime.py` and `check-coverage.py`; the `--plan` text turns open issues into planned nodes and removes `adoption`. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A07-AC-4** — Feedback on and a conflict of a `spec/adopt*` PR start the adoption unit with `--feedback` or `--update`, not a triage. *Verify:* `bash scheduler/loop-a07.test.sh`.
- **A07-AC-5** — A labelled issue is not triaged while an adoption is in progress, and is triaged after it. *Verify:* `bash scheduler/loop-a07.test.sh`.
- **A07-AC-6** — A real repository chosen by the owner is adopted end to end: the first PR, one PR per area, the plan PR, every one passing `check-regime.py` and `check-coverage.py`. *Verify:* the recorded run, with the PR links, in this node's PR.

## Risks
- A repository with many areas takes many PRs; one at a time keeps each reviewable, and merging them is the throttle.
- An area session may read files outside its area to understand it, but owns only its area's files, and the coverage
  check holds it to that.
- Imported criteria describe behaviour as the session read it. `unpinned` marks what no test shows; A08's pins are how
  a later change makes it certain.
- Adopting starts as soon as a repository without a graph is on the list. A repository listed by mistake gets one
  first-PR session, which waits on the owner's answers before anything else.
