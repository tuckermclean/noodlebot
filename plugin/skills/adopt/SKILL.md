---
name: adopt
description: Start bringing a repository that has no docs/graph.yaml into the graph regime - read its inventory, README, docs, build files, CI and issues, ask the owner (QUESTION.md) to confirm the gate command, the out-of-scope paths and the areas, run the gate once to record what already fails, then draft SPEC.md, an AGENTS.md "Building a node" section and docs/graph.yaml (gate, out_of_scope, adoption areas, nodes empty) as one spec PR on spec/adopt. Produces specs only, never code or tests. Use for "/adopt <owner/name>" or when asked to put a repository under the node graph.
---

# /adopt <owner/name | dir> [--dry-run [--out <dir>]] [--answers <file>]

You take the first step of turning an existing repository into a **plan the scheduler can build from**: you
set up the graph regime (`SPEC.md`, an `AGENTS.md` "Building a node" section, and `docs/graph.yaml` with the
gate, the out-of-scope paths and the adoption areas, and no nodes yet), proposed as one PR the owner reviews.
You also record which tests already fail. Mapping the areas into nodes is later work. The owner decides scope,
the gate and the areas; you never guess them.

**Never** write implementation or tests, change the repository's code, merge, approve or push to its
main branch. Every forge operation goes through the forge CLI, written `<forge>` below: the command the run's environment and prompt name for it, used as `<forge> <family> <op> --opt value` (JSON out). With none (a run by hand), use `<plugin dir>/../scheduler/forge-cli.sh --repo <kind>:<owner/name>` (for example `github:owner/name`), the same command with the repository named. It fetches credentials itself: never print, echo or log a token, and use no other forge client.
With `--dry-run` the argument may also be a local directory instead of `owner/name`. A dry run works
offline and stops with files in an output directory: no push, no PR, no comment (see "Dry run").
If the repository already has `docs/graph.yaml`, stop and say so: changing its plan is a triage job.

## 1. Facts first (deterministic)
- Work in a fresh clone or worktree, never in someone's checkout:
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
- Compare the repository's test and fixture paths with the role guard's defaults (see section 3), e.g.
  a `fixtures/` directory that holds application data, or `tests.py` files the defaults miss.
- Read the issues, closed ones too, and merged PRs: they are the history of intent.
  `<forge> issue list --state all` (it may also return PRs, marked `is_pr` true: skip those),
  `<forge> pr list --state merged` and
  `<forge> issue view --number <n>` with `issue comments --number <n>` for the ones that matter. Note the work they ask for.
  They become nodes later, once the code is mapped; this PR drafts no node.
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
