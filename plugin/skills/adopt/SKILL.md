---
name: adopt
description: Start bringing a repository that has no docs/graph.yaml into the graph regime - read its inventory, README, docs, build files, CI and issues, ask the owner (QUESTION.md) to confirm the gate command, the out-of-scope paths and the areas, run the gate once to record what already fails, then draft SPEC.md, an AGENTS.md "Building a node" section and docs/graph.yaml (gate, out_of_scope, adoption areas, nodes empty) as one spec PR on spec/adopt. Produces specs only, never code or tests. Later modes of the same skill map the adoption areas one at a time (--area <name>: read only that area and write imported nodes that own its files, as one spec PR that takes the area off the list), turn the open issues into planned nodes (--plan) and update or answer feedback on an adoption's spec PRs (--update, --feedback). Use for "/adopt <owner/name>" or when asked to put a repository under the node graph.
---

# /adopt <owner/name | dir> [--dry-run [--out <dir>]] [--answers <file>]  |  /adopt --area <name>  |  /adopt --plan  |  /adopt --update <N>  |  /adopt --feedback <N>

The first form (sections 1 to 6) is the first-PR mode. The other four modes are run by the loop, one at a
time, in the checkout their prompt names: "--area <name>" (section 7), "--plan" (section 8),
"--update <N>" and "--feedback <N>" (section 9).

You take the first step of turning an existing repository into a **plan the scheduler can build from**: you
set up the graph regime (`SPEC.md`, an `AGENTS.md` "Building a node" section, and `docs/graph.yaml` with the
gate, the out-of-scope paths and the adoption areas, and no nodes yet), proposed as one PR the owner reviews.
You also record which tests already fail. Mapping the areas into nodes is later work. The owner decides scope,
the gate and the areas; you never guess them.

**Never** write implementation or tests, change the repository's code (apart from the scratch edits of section 7
step 2's check, reverted before any commit), merge, approve or push to its main branch. Every forge operation goes through the forge CLI, written `<forge>` below: the command the run's environment and prompt name for it, used as `<forge> <family> <op> --opt value` (JSON out). With none (a run by hand), use `<plugin dir>/../scheduler/forge-cli.sh --repo <kind>:<owner/name>` (for example `github:owner/name`), the same command with the repository named. It fetches credentials itself: never print, echo or log a token, and use no other forge client.
With `--dry-run` the argument may also be a local directory instead of `owner/name`. A dry run works
offline and stops with files in an output directory: no push, no PR, no comment (see "Dry run").
In the first-PR mode only: if the repository already has `docs/graph.yaml`, stop and say so (it already has a graph; changing its plan is a triage job). The modes of sections 7 to 9 work on a repository that already has its first PR (and, for 7 and 8, a graph) and never stop for that graph.

## 1. Facts first (deterministic)
- A run whose prompt names a checkout (a loop run) works there and makes no clone: skip the clone
  below, and the branch the prompt names is already checked out. The clone is for runs by hand only.
- Work (by hand) in a fresh clone or worktree, never in someone's checkout:
  `<forge> repo clone-url`, then `git clone <that URL> <dir>` (or `git fetch origin && git worktree add -b spec/adopt <dir> origin/<default branch>`).
  A real run's clone goes in `out/adopt/<name>/repo`. Create the branch `spec/adopt` there and leave
  it local and unpushed until section 5; on resume, re-create it from the current default branch if
  that moved while the owner answered. (A dry run on a local directory creates no clone and no
  branch and makes no commit in the input; it stops with files in the output directory.)
- Real run only: record in `FACTS.md` what `<forge> repo permissions` reports about the credential's
  permissions; an App installation token may report none, so this alone never stops the run; a push
  refused in section 5 stops the run and is reported. Never print a credential.
- Run `python3 -I <plugin dir>/skills/adopt/inventory.py --json --areas <dir>` on the clone and read its
  summary: the files by language and size, the entrypoints, the tests, the CI files, the candidates to
  leave out of scope (vendored or generated folders) with their reasons, the import links, and the
  proposed areas. This replaces reading every source file: do not read source files beyond what one
  question needs.
- Read the README, any `AGENTS.md`/`CLAUDE.md` and docs, the build and CI files, and how to build,
  test and lint (Makefile, package scripts, workflow steps). Note which commands the repository runs.
- Of the repository's own commands (build, test, lint, its scripts), before the owner confirms the
  gate, run only one that its CI, Makefile or package scripts already run (for example the one test command), once, and only in the clone or worktree (a dry
  run: its temporary copy, see "Dry run"). Run it to see its output, so that the `fail_pattern` is
  proposed together with the gate command. Any other command of the repository's waits until the owner has confirmed the
  gate in the answers; never run one earlier. A command that cannot run here (heavy install, a
  database, Docker) is recorded as "not run: <reason>" plus what CI shows. A documented command that
  is itself broken is a fact to raise in section 2.
- Run that command, here and for the baseline in section 3, with `CI=true` and the agent session's variables
  unset (`CLAUDECODE`, `AI_AGENT`): a runner such as vitest changes its output, colour for one, when it sees
  them. The node skill judges CI's run of the gate with the same `fail_pattern`, so the pattern must match
  CI's lines too, once what CI adds is stripped (for example colour escape codes, or a fetched job log's
  timestamp prefix).
- Compare the repository's test and fixture paths with the role guard's defaults (see section 3), e.g.
  a `fixtures/` directory that holds application data, or `tests.py` files the defaults miss.
- Read the issues, closed ones too, and merged PRs: they are the history of intent.
  `<forge> issue list --state all` (it may also return PRs, marked `is_pr` true: skip those),
  `<forge> pr list --state merged` and
  `<forge> issue view --number <n>` with `issue comments --number <n>` for the ones that matter. Note the work they ask for.
  They become nodes later, once the code is mapped; this PR drafts no node.
- A closed PR that was never merged is not the owner's intent: do not read its drafts, recommend from them,
  cite, link or copy them. The same goes for a branch other than the default branch and the one this run works on
  (an earlier adoption attempt): do not read or use it. The drafts come from the default branch, its merged PRs,
  the issues and the owner's answers, and from nothing else.
- Write down what you found and what you could not tell in `FACTS.md` next to `QUESTION.md`, so a
  resumed run has it. Do not invent intent from the code.

## 2. Ask the owner (QUESTION.md), then stop
Write `QUESTION.md` with the questions only the owner can answer, numbered, each with your
recommendation so a bare "yes" works. A recommendation is a proposal, labelled as such, never a
settled fact ("Do not invent intent" still holds). Keep `QUESTION.md` short enough to read on a phone
(about 80 lines): the fewest questions that settle the plan. Ask what the code cannot show:
1. scope and non-goals: what this repository is for and what it is not;
2. priorities and order: which work comes first, which can wait (recorded in `SPEC.md` for the later nodes);
3. what is done and what is only planned (existing code that is half-built, issues already fixed);
4. principles and constraints that every change must respect;
5. open decisions that block work, with a default for each;
6. **the gate command**: the command that runs the whole test suite. Recommend the one CI, the Makefile
   or the package scripts already run, together with the proposed `fail_pattern` (a regular expression
   for the lines it prints for a failure, as seen in the run of section 1);
7. **the paths to leave out of scope**, with a reason each. Recommend the inventory's candidates with its
   reasons; a candidate the owner keeps in scope goes into an area;
8. **the areas**. Recommend the inventory's proposal, which the owner may rename, merge or split;
9. anything in the facts that conflicts or is unclear, including test or fixture paths that differ
   from the guard's defaults and a documented command that is broken. A quick gate that would not run
   through the gate's own runner is asked here too (see section 3).
`<name>` is the repository's name, or the directory's basename for a local directory.
Put it in the run's output folder, `out/adopt/<name>/QUESTION.md`, relative to the directory the
skill is run from (the `--out <dir>` of a dry run: `<dir>/QUESTION.md`), and tell the owner where it is.
Unattended, the run's own instructions for questions win. **Then stop**: no drafts before the owner's
`ANSWER.md` exists (next to `QUESTION.md`, or the file given by `--answers`). On resume, read `ANSWER.md`; a question it leaves open
becomes an open decision with your default, not a guess presented as settled. A follow-up question
(section 3) is appended to `QUESTION.md`, numbered after the earlier ones, and the run stops again: it
resumes past that question only when the answers file (the owner's newer `ANSWER.md`, or the
`--answers` file) answers it, never on the earlier answers alone.

## 3. The baseline and the drafts of the first PR
Only after `ANSWER.md`. Order: the baseline, then the graph, then the other drafts, so they agree.
- **The baseline.** Run the confirmed gate command once in the clone (a dry run: its temporary copy) and
  keep its output in `FACTS.md`. If the gate cannot run here (it needs something the machine lacks, or
  it does not start), append a question to `QUESTION.md` (numbered after the earlier ones, with a recommendation) and stop;
  on resume read its answer from `ANSWER.md` (the owner's newer answer, or the `--answers` file). An
  adoption needs a gate that runs. Unattended, the run's own instructions for questions win.
  Record in `gate.fail_pattern` a regular expression matching the lines the command prints for a
  failure, and only those lines that name a failing test: a summary line that names none is not
  matched. Record each failing test in `gate.known_red` by its full name, as such a line prints it.
  In the baseline run every matched line then contains a `known_red` entry, and at least one line is
  matched when the command exits non-zero. When the output still does not make the pattern plain, ask
  one follow-up question for it (appended to `QUESTION.md` with a recommendation, answered in
  `ANSWER.md` or the `--answers` file on resume) and stop. A passing gate has an empty `known_red`.
- **`docs/graph.yaml`**: `template: {headings: [Purpose, Tests, Changes, Gate, Risks]}` (or the
  repository's own list), `gate: {command, fail_pattern, known_red}`, `out_of_scope:` (a `glob` and a
  `reason` each, from the answers), `adoption: {areas: [{name, globs}]}` from the answers, and `nodes: []`.
  Draft no node and no `nodes/` file: open issues become nodes later, once the code is mapped.
  Every tracked file must be out of scope, in an area, or one of the regime's own files (`SPEC.md`,
  `AGENTS.md`, `docs/graph.yaml`, `nodes/` and the like).
- **`SPEC.md`**: what this is, principles (from the answers), the state (what is done, what is planned
  and the priorities, from the answers to questions 2 and 3), architecture, the node spec template
  (a `## Node spec template` section giving the headings above), open decisions with defaults,
  conventions (branches `node/<ID>-<name>` and `spec/<topic>`, sizes, when a node is done).
  Drafts name no repository (no owner/name of any, not even the plugin's own). They do name the
  plugin's node skill directly as `/noodlebot:node <ID>` and the guard's config file as
  `.noodlebot/roles.yaml`; the checker is `<plugin dir>/skills/node/check-regime.py`.
- **Drafts stay true.** `SPEC.md` and `AGENTS.md` state nothing the area or plan PRs make false: no "no node
  yet", no "in an area or a node", no other in-progress state of the adoption. They must be true as the areas
  are mapped and after `adoption` is removed, since later PRs cannot edit AGENTS.md.
- **`AGENTS.md`**, a "Building a node" section (add to an existing file, do not replace it):
  build a node with `/noodlebot:node <ID>`; authority order (`SPEC.md`, `docs/graph.yaml`, the node spec, then `AGENTS.md`); role agents: the
  plugin's tester, implementer and reviewer, unless the repository has its own; the spec checkers
  (`python3 -I <plugin dir>/skills/node/check-regime.py` and `check-coverage.py`, PROBLEMS 0);
  **the gate command**: the whole suite, which runs in CI on the PR; **a quick gate** that a session runs
  locally instead: the red targets and the test files of what a change touches, run through the gate's
  own runner; the rules for `owns` (a node changes only the files it owns and its direct deps' files) and
  for `known_red` (a listed failure stays until a node fixes it and then removes it); the form of a red
  target (a command that exits non-zero before and 0 after); the test and fixture paths; porting rules or
  "none"; what CI evidence to record; and a **Spec files:** line, one physical line naming the
  repository's spec files as paths in backticks (folders with a trailing `/`), normally `SPEC.md`,
  `docs/graph.yaml`, `nodes/`: a spec PR changes only these.
  The AGENTS.md draft records what CI's lines may add to the gate's output, for example colour escape codes and a
  fetched job log's timestamp prefix, and says that `fail_pattern` matches once they are stripped.
- **The quick gate's output.** The checks of a node's gate run judge failures with `fail_pattern`, which is
  written for the output of the gate command. Draft a quick gate only through the gate's own runner,
  where that runner takes a list of files and prints the lines `fail_pattern` reads. A quick gate that
  would run another command (the runner takes no list of files) or print another output format may
  print lines `fail_pattern` cannot read, so it is a question to the owner, not a draft: ask it in
  section 2 or as the follow-up question above, with a recommendation (for example the whole gate as the
  quick gate, or a quick gate whose failure lines the pattern matches), and draft the owner's answer.
- **The role guard's config** (`<plugin dir>/hooks/guard.py`: its docstring gives the file's location,
  its `DEFAULTS` the default globs, which treat `**/*.test.sh`, `**/tests/**`, `**/testdata/**`,
  `**/fixtures/**` etc. as tests) only if those defaults do not match the repository's test paths
  (`tests:` and `specs:`, root-relative globs), in `.noodlebot/roles.yaml` at the repository root.
- **No guess presented as settled.** Where the drafts need a choice the answers do not make, put it in
  `SPEC.md`'s open decisions with a default. Before finishing, check the drafts against `SPEC.md`'s
  principles and the answers.
Do not write implementation or tests.

## 4. Check
Run `python3 -I <plugin dir>/skills/node/check-regime.py --root <dir>` and
`python3 -I <plugin dir>/skills/node/check-coverage.py --root <dir>` until both print `PROBLEMS 0`,
fixing the drafts (not the checkers), and before the push. `check-coverage.py` needs a git repository
whose tracked files are the ones to cover: in a real run the clone, with the drafts committed on
`spec/adopt`; in a dry run lay the drafts over the temporary copy and commit them there (never in the
input). The gate run happens in that same tree, so stage and commit only the drafted paths (`SPEC.md`,
`AGENTS.md`, `docs/graph.yaml`, and `.noodlebot/roles.yaml` when drafted), e.g. `git add -- <those paths>`,
never `git add -A`. Files the gate run left behind (caches, `node_modules`, build output) are not part of
the PR: if they would otherwise be committed, remove them (e.g. `git clean`) first. A fix after a
checker run goes into that same commit (`git commit --amend`), so the branch holds one commit (section 5).
Also check the drafted `AGENTS.md` commands exist, and that the quick gate runs.

## 5. The PR
- One commit on `spec/adopt`, subject `Spec: adopt the repository into the graph regime`, body: what
  was drafted and the owner's answers it carries out. It holds only the drafted paths (`git add -- <paths>`,
  never `git add -A`); files the gate run left behind are not in it.
- Before the push, run the checker against origin/main (origin/<default branch> where that is not main):
  `python3 -I <plugin dir>/skills/node/check-spec-diff.py --allow AGENTS.md --allow .noodlebot/roles.yaml origin/main HEAD`
  (drop `--allow .noodlebot/roles.yaml` when section 3 drafted no such file). Both are outside the
  default list: this PR is the one that sets up the regime files, and no **Spec files:** line exists at
  origin/main yet. On exit 1 it names the other paths (`NOT SPEC <path>`): stop, and do not push. On
  exit 2 (git failed) stop too.
- Push the branch and open one PR (`<forge> pr create --head spec/adopt --base <default branch> --title <title> --body-file <file>`, the branch pushed first with `<forge> branch push --path <dir> --branch spec/adopt`). Body: what was drafted; which owner answers it
  carries out (by number); open decisions and their defaults; what to check first (the gate, what is out of scope, the areas, the
  baseline's `known_red`); `Refs #N` for the issues that the later nodes will cover, if any. Never merge, approve or push to main.

**Closing keywords.** A forge closes an issue when a PR description, or a commit message that reaches main, contains a
closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, with or
without a colon) followed by its number. Write none here: use "issue #N" or "Refs #N", because the
loop closes the issue once the nodes that build the work are merged.

## Dry run
With `--dry-run`, run sections 1 to 4 offline against a local directory or a clone:
- First copy the input directory to a temporary folder that is a git repository of its own. When the
  input's `.git` is a directory, copy the input with it (tracked files included). When `.git` is a
  file (a git worktree: it points at a shared repository, so a commit in such a copy moves the input's
  branch) or there is none (a subfolder of another repository, like `testdata/repo/`), copy the files
  without `.git`, `git init` the copy and commit its files with `git add -f` (so files an outer
  ignore list would hide are kept) before anything runs. That `-f` is for this first commit only: the
  drafts are later staged by path, never with `git add -A` or `-f` (see section 4).
  Every command the skill runs (the section 1 command, the inventory, the gate run of section 3, the
  checkers) runs in that copy, and the drafts are laid over the copy and committed there for
  `check-coverage.py`. Nothing is written into the input.
- Issues come from `issues.json` in that directory if present (the form of
  `<forge> issue list --state all`: a JSON list of objects with number, title, body, labels, state; an entry without `state` counts
  as open), else there are none.
- The owner's answers come from the `--answers <file>` the caller names, else an `ANSWER.md` in the
  output directory, else one in the input directory. If none exists, write `QUESTION.md` (into the
  output directory) and stop as usual. If one exists, `QUESTION.md` is still written there first, as the record.
- Write the drafts into an output directory (`--out <dir>`, else `out/adopt/<name>/`) holding
  `QUESTION.md`, `FACTS.md` (with the gate run's output), `SPEC.md`, `AGENTS.md` and `docs/graph.yaml`
  (and `.noodlebot/roles.yaml` only when drafted); never write into the input directory. Run both
  checkers with `--root` on the copy with the drafts laid over it. No push, no PR, no comment.
- Print a result summary: the output directory, the areas drafted, the gate run's result and its
  `known_red`, the checkers' last lines, the questions asked, and every point where this skill was unclear.

## 6. Report
End with: the repository, the PR URL (or the output directory for a dry run), the areas and the baseline (what already fails), the
checkers' results, and what the owner should check first.

## 7. Map an area: `/adopt --area <name>`
Run by the loop for the first area still listed under `adoption.areas` of `docs/graph.yaml`, after the first PR
and every earlier area's PR are merged. Work in the checkout the prompt names (no clone), on the branch
`spec/adopt-<name>` made from `origin/<default branch>`. Take the area's name and globs from the graph, not
from memory. Ask the owner (QUESTION.md, as in section 2) only what the code cannot show; unattended, the run's own
instructions for questions win.
Read the owner's answers to the first PR's questions (the replies on the adoption's issue, which the loop titles
`Adopt <name>`; in a loop run, also the first PR unit's `answered/` folder): they bind this step.
1. Run `python3 -I <plugin dir>/skills/adopt/inventory.py --json --glob <glob> <checkout>` for each of the area's globs
   and read the area's files. You may read other files to understand them, but you map only the area's files.
2. Write one or more imported nodes (`status: imported`, `track: done`, in `docs/graph.yaml`, each with a
   `nodes/<ID>-<name>.md`; take each ID from the `next free:` line of `python3 -I <plugin dir>/skills/triage/nodes.py`, run from the checkout, as triage does. A node of a letter already in use takes that letter's next free number. Pick a new letter only when `nodes.py` exits 0. When it exits 1 and reports the open spec PRs' IDs as unknown (`no next free ID`), it cannot tell which letters the open PRs took: end the run without a PR, as triage does; a later start tries again. When no letter is in use (the graph has `nodes: []`) or the area has none yet, pick for the area an unused capital letter (an ID is one capital letter and two digits, as `check-regime.py` requires) and number its nodes `<L>01`, `<L>02`, ...; the first area's letter is new, and each later area gets its own new letter, never one that `nodes.py` or the graph shows in use). Each node:
   - owns part of the area's files, as `owns` globs, each of them also written in backticks on the spec's **Owns:** line
     (`check-regime.py` reports an `owns` glob missing from that line; the header row must match): together the nodes own all of the area's files except those you
     put out of scope, and each file once (no overlap between nodes);
   - has a spec that says what the code does, with the template's headings: Purpose; Tests, the existing tests;
     Changes, the single line "none: imported"; Gate, criteria of the current behaviour, each with a *Verify:*
     naming the existing test that shows it (a file the repository tracks) or reading `unpinned` when no test does.
     A criterion claims only what the test named in its *Verify:* asserts, and that
     test fails when the behaviour the criterion states breaks. Check each pinned criterion: break that behaviour
     in a scratch edit, run the named test, then restore the file; the scratch edit is reverted and nothing is
     committed (the PR stays specs only). Undo one with `git checkout -- <file>` or `git restore <file>`. Before the
     commit, `git status` has to show that only spec files are modified or staged (untracked files the gate run leaves
     do not count). A clause the test does not catch is `unpinned`, a criterion of its own.
     A test that cannot run here makes its criterion `unpinned` too;
     Risks. Describe what you read; do not invent intent;
   - lists as `deps` the already-mapped nodes whose code it relies on.
   The one change allowed to a node outside the area: the header row's Unlocks of each node a new node depends on
   is kept in sync with the graph (`check-regime.py` derives it from the `deps`), as triage does; never its criteria, Purpose or `owns`.
3. Remove the area from `adoption.areas`. A file of the area that should not be owned (vendored, generated) goes
   into a further `out_of_scope` entry, with a glob and a reason; such a file is then not owned by any node.
   Keep the other areas, the existing `out_of_scope` entries and the gate unchanged.
4. Run `python3 -I <plugin dir>/skills/node/check-regime.py` and `check-coverage.py` until both report
   `PROBLEMS 0`; a `check-coverage.py` problem outside the area (a file no area, node or `out_of_scope` entry covers, say) is a `QUESTION.md`, never an ownership change outside the area: write it and end the run without a PR, pushing nothing. Commit, then (it compares commits) run `python3 -I <plugin dir>/skills/node/check-spec-diff.py origin/<default branch> HEAD`
   until it passes (exit 0), fixing the drafts, not the checkers, and committing each fix; exit 2 (git failed) stops the run, as in section 5.
5. Push `spec/adopt-<name>` and open one spec PR (one PR for the area, as in section 5), body: the
   nodes, what each owns, the criteria marked `unpinned`, any new out_of_scope entry; `Refs #N` for issues the
   nodes touch, no closing keyword. End with a `WAITING-PR` marker in the state folder as the prompt says. You write no code and no
   tests, never change a file outside the spec files (apart from the scratch edits of step 2's check, reverted before
   any commit), and never merge.

## 8. Plan the open issues: `/adopt --plan`
Run by the loop once no area is left under `adoption.areas`. Work in the checkout the prompt names, on
`spec/adopt-plan`.
Read the owner's answers to the first PR's questions (the replies on the adoption's issue, which the loop titles
`Adopt <name>`; in a loop run, also the first PR unit's `answered/` folder): they bind this step.
1. Read the open issues (`<forge> issue list --state all`, skipping PRs; closed ones are history) with their
   comments, and the graph and node specs now on `origin/<default branch>`.
2. Turn each open issue into a planned node (`status: planned`), or into a criterion of an existing planned
   node, by the triage rules: `deps` on the nodes whose files it changes and on the nodes whose globs match
   the paths it will add files at; `owns` only for added paths that no node's glob and no `out_of_scope`
   glob matches; **Resolves:** #N for its issue. Never change the criteria of an imported node: the change
   is a new node of its own (only the header row's Unlocks of the nodes it depends on is kept in sync, as in section 7 step 2). An issue that needs the owner's decision goes to QUESTION.md with your recommendation.
3. Remove `adoption` from `docs/graph.yaml` (the whole key), so the graph shows the adoption is over.
4. Run the same checks as in section 7 step 4 (`check-regime.py`, `check-coverage.py`, then, after committing, `check-spec-diff.py origin/<default branch> HEAD`).
5. With everything committed, push `spec/adopt-plan` and open one PR with `Refs #N` for each issue (no closing keyword), then
   `WAITING-PR` as the prompt says. Never merge.

## 9. Update and feedback: `/adopt --update <N>` and `/adopt --feedback <N>`
Run by the loop for one of the adoption's own open spec PRs (`spec/adopt`, `spec/adopt-<name>`,
`spec/adopt-plan`) in the checkout the prompt names, which is on the PR's branch, brought to `origin/<branch>`
(a fast-forward). Create no other branch. Mirror the triage skill's update and feedback modes.
Read the owner's answers to the first PR's questions (the replies on the adoption's issue, which the loop titles
`Adopt <name>`; in a loop run, also the first PR unit's `answered/` folder): they bind this step.
- **`--update <N>`**: the PR conflicts with main. `git fetch origin`, then merge `origin/<default branch>`
  into the branch: a merge commit, never a rebase, never a force push. Resolve a conflict that needs no
  judgment by keeping both sides (both graph rows, both areas' removals, and main's header row with the branch's change put back in); leave no conflict markers. A
  conflict that needs a judgment: `git merge --abort`, push nothing, comment on the PR with the files and why, end.
  Where main has since taken a node ID of the PR, renumber the PR's node as triage does (spec file, graph entry,
  criteria IDs, references, the header rows it changes in other specs) in one commit on top. Rerun `check-regime.py`, `check-coverage.py` and
  `check-spec-diff.py` until they pass (`PROBLEMS 0`; the spec-diff check is
  `python3 -I <plugin dir>/skills/node/check-spec-diff.py origin/<default branch> HEAD`, run on the committed merge). For the `spec/adopt` PR, which
  adds `AGENTS.md` (and `.noodlebot/roles.yaml` when drafted) before main has a **Spec files:** line, run it as in
  section 5 with `--allow AGENTS.md [--allow .noodlebot/roles.yaml]` before `origin/<default branch> HEAD`; without them it always reports
  `NOT SPEC` for those files. Exit 2 of `check-spec-diff.py` (git failed) stops the run: push nothing,
  `git reset --hard origin/<branch>` (no merge commit left) and end. If the merge had conflicts, run the resolution review before anything is pushed,
  as triage's update mode (step 4) does: dispatch a new reviewer (the repository's reviewer role,
  `noodlebot:reviewer` when it names none) with the merge commit and its diffs against both parents; it checks
  that the resolution keeps the intent of both sides and that no node is owned twice or left unowned. Post its verdict on the PR as
  `Resolution review (<verdict>)`, a comment, never an approval. Nothing is pushed until it approves; on
  `request_changes` fix the findings as new commits and run one more new reviewer. A second rejection pushes nothing:
  comment the findings on the PR, `git reset --hard origin/<branch>` and end. Then push the branch and comment on the PR with what was merged.
- **`--feedback <N>`**: read `FEEDBACK.md` in the state folder (each item has its kind, URL, author, body, and for a
  line comment its file, line and thread). Change the PR's specs as it asks, as one new commit (never an
  amend, a rebase or a force push), keeping the area's files owned once each; run the same checks as `--update` (`check-regime.py`, `check-coverage.py`, commit, then
  `python3 -I <plugin dir>/skills/node/check-spec-diff.py origin/<default branch> HEAD`, with `--allow AGENTS.md [--allow .noodlebot/roles.yaml]`
  before the refs for the `spec/adopt` PR) until they pass; a coverage problem outside the PR's area is a `QUESTION.md`, never an ownership change
  outside the area, and check-spec-diff exit 2 (git failed) stops the run; either ends the run: push nothing, `git reset --hard origin/<branch>`, end (the `QUESTION.md` written last). Other nodes' header-row Unlocks are kept in sync as in section 7 step 2. A point only the owner can decide goes to QUESTION.md with your recommendation, written last.
  A wording the feedback suggests is checked against the code, as your own would be, before it is applied: for a
  pinned criterion, its test must fail when the claim breaks.
  Push the branch, then update the PR's title and body wherever the feedback's change makes them wrong, not only
  when its nodes changed (its nodes, the `unpinned` list, a fact or risk the body repeats), and reply to each point: a
  line comment in its own thread, the others in one PR comment; each reply says what changed, with the commit,
  or why nothing did. Resolve the line threads you fixed.
Both modes write no code and no tests (apart from the scratch edits of section 7 step 2's check, reverted before any
commit), and never merge, approve or push to the default branch.
