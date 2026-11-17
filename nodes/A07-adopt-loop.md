# A07 — adopt-loop

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A04, A06 | A09 | L |

**Owns:** in `scheduler/loop.sh`, the adoption state read from `origin/main`, the adoption units (when one starts, its
worktree and state, its end), triage waiting during an adoption, and the skill and template used for updates and
feedback of `spec/adopt*` PRs, and the throttle's view of adoption sessions in `scheduler/usage.py` (with its case
in `scheduler/usage.test.sh`), `scheduler/status.sh` and `scheduler/loops.sh` (with their cases in a
`scheduler/loop-a07*.test.sh`); the session template `scheduler/unattended-adopt.md` (new); the adoption kind in `scheduler/turn.py`;
the adoption home issue ("Adopt <name>", created as unit home issues are, closed when the plan PR is merged) and its
answers in `scheduler/report.py`; in `plugin/skills/adopt/SKILL.md`, the frontmatter description and the usage line
(with the new modes), the "already has a graph, stop" line (which then applies to the first-PR mode only), section 1's
clone (for runs by hand only; a loop run works in the checkout its prompt names), and the `--area
<name>`, `--plan`, `--update <N>` and `--feedback <N>` modes; the recorded `--area` dry run under
`plugin/skills/adopt/example-area/`; the new tests `scheduler/loop-a07*.test.sh` (split so each file stays under
`TEST_FILE_BUDGET`, the end-to-end run in its own file) and their lines in the `Makefile`'s
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
- `scheduler/loop-a07*.test.sh` (new, split by scenario, each under `TEST_FILE_BUDGET`; the end-to-end run in its own
  file), with the fake forge and harness:
  - an `origin/main` that does not resolve (a failed fetch): no adoption session, one status-log line;
  - a repository with no graph on `origin/main`: one adoption session (`adopt/scaffold`) in its own worktree, its
    prompt naming the repository, the skill and its worktree as the checkout to work in; no second start while its
    spec PR is open; a question holds it, and
    the owner's reply on the "Adopt <name>" issue becomes its `ANSWER.md` and starts it again;
  - a graph with two areas: one session for the first area, its prompt naming the area, its globs and the inventory
    command; nothing for the second area while the first area's PR is open or its unit is held; after that PR is
    merged (the area gone from the graph), one session for the second;
  - a graph with `adoption` and no area left: one `adopt/plan` session; after its PR is merged (no `adoption`), nothing;
  - an adoption PR closed without merging: that unit held by `FAILED` naming the PR;
  - owner feedback on a `spec/adopt-<name>` PR, and that PR conflicting with main: a session in `pr/<N>/` as today,
    rendered from `unattended-feedback.md` or `unattended-update.md` with `/noodlebot:adopt --feedback|--update <N>`,
    not a triage, after the unit's own worktree has been removed so the PR's branch can be checked out;
  - a labelled issue while an adoption is in progress: `issues.py` not asked, one status-log line; triaged after the
    adoption ends;
  - an adoption unit and a triage share the one slot;
  - a running adoption session counted by `usage.py` (in `scheduler/usage.test.sh`) and listed by `status.sh` and
    `loops.sh status`;
  - a scaffold, an area and a plan unit whose PR was merged after the tick's fetch (its `WAITING-PR` names a merged PR,
    the fetched graph not showing it yet): no second session, one status-log line, until `origin/main` shows it;
  - the loop running from a checkout without `unattended-adopt.md`: no adoption start, one status-log line, the tick
    carries on;
  - end to end with the fake forge: scaffold, area one, area two and plan, each PR merged by the fake, ending with a
    graph without `adoption` that `check-regime.py` and `check-coverage.py` pass.
- `scheduler/turn.test.sh` (extended): the adoption kind goes with triages in the start queue.
- `scheduler/report.test.sh` (extended): the "Adopt <name>" issue (labelled `noodlebot-unit`) gets each adoption unit's
  milestones and questions; an owner reply there is recorded as the open unit's answer; the issue is closed once the
  plan PR is merged.
- `plugin/skills/adopt/adopt.test.sh` (extended): the `--area`, `--plan`, `--update` and `--feedback` modes' text, that a run
  whose prompt names a checkout works there and makes no clone, and
  the recorded `--area` dry run under `example-area/` (A06's `testdata/baseline/` fixture with `example-baseline/`'s
  drafts), whose imported nodes together own exactly the area's files not put out of scope; laid over the fixture repository and committed
  as in A06's test, `check-regime.py` and `check-coverage.py` pass.

## Changes
1. **The adoption state.** Each tick, before the triage step, the loop reads `docs/graph.yaml` at `origin/main` (as it
   already reads YAML for spec-PR clashes). When `origin/main` does not resolve, nothing about adoption starts and one
   line is logged:
   - no graph (`origin/main` resolves and has no `docs/graph.yaml`): the unit `adopt/scaffold` (`/noodlebot:adopt
     <repo>`, A06);
   - `adoption` with areas: the unit `adopt/<name>` for the first area in the list (`/noodlebot:adopt --area <name>`);
   - `adoption` with no area left: the unit `adopt/plan` (`/noodlebot:adopt --plan`);
   - otherwise there is no adoption.
   Nothing starts for a unit while its PR (`spec/adopt`, `spec/adopt-<name>`, `spec/adopt-plan`) is open, while it is
   held (a question, `FAILED`), or while its `WAITING-PR` names a merged PR that the fetched `origin/main` does not show
   yet (scaffold: still no graph; area: the area still listed; plan: `adoption` still present): one log line, and the
   next fetch catches up.
   At most one adoption session runs at a time, in the triage's slot, through the start queue. *A07-AC-1, A07-AC-2.*
2. **The unit.** Its state is `state/<name>/adopt/<key>/` with the usual markers (a question holds it until it is
   answered; its PR is waited for with `WAITING-PR`; a PR closed without merging writes `FAILED`). Its session works
   in `worktrees/<name>/adopt-<key>`, on `spec/adopt` (scaffold) or `spec/adopt-<key>` from `origin/main`. The worktree
   is removed once the unit has written `WAITING-PR` (its branch is pushed by then) or `FAILED`, so an update or
   feedback session of its PR can check the branch out; a session that ends otherwise (a usage limit, a stop) keeps
   it for its resume. The throttle (`usage.py`), `status.sh` and `loops.sh status` count adoption sessions like
   other sessions. Its milestones and questions go to one issue, "Adopt <name>", labelled
   `noodlebot-unit`, which `report.py` creates as it creates other units' home issues; since one adoption unit is open
   at a time, an owner reply there answers it. The issue is closed once the plan PR is merged.
   *A07-AC-2.*
3. **Mapping an area** (`--area <name>`). The session runs `inventory.py --json --glob <glob>` for each of the area's
   globs and reads the area's files (it may read others to understand them, but maps only these). It writes one or
   more imported nodes:
   - each node owns part of the area's files (together, all of the area's files not put out of scope, each once);
   - its spec describes what the code does: Purpose, the existing tests under Tests, "none: imported" under Changes,
     and criteria of current behaviour, each *Verify* naming the existing test that shows it or reading `unpinned`;
   - deps on the already-mapped nodes whose code it relies on;
   - the area removed from `adoption.areas`, and any further `out_of_scope` entries with reasons.
   `check-regime.py` and `check-coverage.py` report `PROBLEMS 0`, `check-spec-diff.py` passes, and one spec PR
   `spec/adopt-<name>` is opened. It writes no code and no tests. *A07-AC-3.*
4. **The plan** (`--plan`). The session reads the open issues (closed ones as history), turns each into a planned node
   or a criterion of one (placed as A02 says: deps on the nodes whose files it changes and on the nodes whose globs match the paths it
   will add files at, `owns` only for added paths no existing glob matches; **Resolves:** the issue), removes `adoption` from the graph, and opens `spec/adopt-plan`, with the same checks.
   *A07-AC-3.*
5. **Updates and feedback** on `spec/adopt*` PRs (a conflict with main, the owner's comments and reviews) keep their
   state in `pr/<N>/` as for any spec PR (`feedback.py` and the pickup step unchanged) and are rendered from the
   existing `unattended-update.md` and `unattended-feedback.md`, with `@CMD@` set to `/noodlebot:adopt --update <N>`
   or `--feedback <N>` instead of the triage's.
   *A07-AC-4.*
6. **Triage waits** while the graph is missing or has `adoption`: the loop does not ask `issues.py` for a triage and
   logs one line. A labelled issue is triaged once the adoption ends (the plan session read it already, and the triage
   finds it covered). *A07-AC-5.*
7. **The session template** `scheduler/unattended-adopt.md` names the repository, the unit, the skill's mode, the area
   and its globs, the checkout to work in (the unit's worktree; the skill makes no clone of its own), the state folder
   and the forge CLI, and ends the run with a spec PR plus `WAITING-PR`, or one
   `QUESTION.md`. It never merges. A checkout without the template starts no adoption and logs it once. *A07-AC-1.*

## Gate
- **A07-AC-1** — A repository with no graph gets one `adopt/scaffold` session in its own worktree whose prompt names the repository, the skill and its worktree as the checkout, none while its spec PR is open, and none (one log line) when the template is missing. *Verify:* each `bash scheduler/loop-a07*.test.sh`.
- **A07-AC-2** — Areas are mapped one at a time in list order, the next only after the previous area's PR is merged, then one plan session; a question holds a unit and an owner reply on the "Adopt <name>" issue answers it; a PR closed without merging fails it; a unit (scaffold, area or plan) whose PR merged after the fetch starts no second session; the "Adopt <name>" issue is closed after the plan PR merges. *Verify:* each `bash scheduler/loop-a07*.test.sh` and `sh scheduler/report.test.sh`.
- **A07-AC-3** — The recorded `--area` dry run writes imported nodes that together own exactly the area's files not put out of scope, removes the area from the graph, and passes `check-regime.py` and `check-coverage.py`; the `--plan` text turns open issues into planned nodes and removes `adoption`. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A07-AC-4** — Feedback on and a conflict of a `spec/adopt*` PR start a session in `pr/<N>/` from the feedback or update template running `/noodlebot:adopt --feedback` or `--update`, not a triage, on the PR's branch, which the adoption unit's removed worktree no longer holds; the throttle counts adoption sessions and `status.sh` and `loops.sh status` list them. *Verify:* each `bash scheduler/loop-a07*.test.sh` and `sh scheduler/usage.test.sh`.
- **A07-AC-5** — A labelled issue is not triaged while an adoption is in progress, and is triaged after it. *Verify:* each `bash scheduler/loop-a07*.test.sh`.
- **A07-AC-6** — With the fake forge, a repository goes from no graph through the first PR, two area PRs and the plan PR to a graph without `adoption` that `check-regime.py` and `check-coverage.py` pass, and an `origin/main` that does not resolve starts no adoption. *Verify:* each `bash scheduler/loop-a07*.test.sh`.

## Risks
- A repository with many areas takes many PRs; one at a time keeps each reviewable, and merging them is the throttle.
- An area session may read files outside its area to understand it, but owns only its area's files, and the coverage
  check holds it to that.
- Imported criteria describe behaviour as the session read it. `unpinned` marks what no test shows; A08's pins are how
  a later change makes it certain.
- Adopting starts as soon as a repository without a graph is on the list. A repository listed by mistake gets one
  first-PR session, which waits on the owner's answers before anything else.
- The API and the site list sessions from `node/`, `issue/` and `pr/`; an adoption session in `adopt/` shows in the
  status log and on its home issue, not there, until a later node adds it.
- A frozen check of `adopt.test.sh` allows "noodlebot" in the adopt skill only as `/noodlebot:<skill>` and
  `.noodlebot/`; the new modes' text names no label or other noodlebot word.
- A real adoption of a repository is A09's, after this node and A08 are merged and deployed.
