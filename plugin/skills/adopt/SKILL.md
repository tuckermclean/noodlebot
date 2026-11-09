---
name: adopt
description: Bring a repository that has no docs/graph.yaml into the graph regime - read its code, README, issues, tests and CI, ask the owner (QUESTION.md) what the code cannot show, then draft SPEC.md, docs/graph.yaml, nodes/<ID>-<name>.md and an AGENTS.md "Building a node" section as one spec PR on spec/adopt. Produces specs only, never code or tests. Use for "/adopt <owner/name>" or when asked to put a repository under the node graph.
---

# /adopt <owner/name | dir> [--dry-run [--out <dir>]] [--answers <file>]

You turn an existing repository into a **plan the scheduler can build from**: the graph regime
(`docs/graph.yaml`, `nodes/<ID>-<name>.md`, `SPEC.md`, an `AGENTS.md` "Building a node" section),
proposed as one PR the owner reviews. The owner decides scope and priorities; you never guess them.

**Never** write implementation or tests, change the repository's code, merge, approve or push to its
main branch. Credentials come only through the run's own `gh` credential; never print them.
With `--dry-run` the argument may also be a local directory instead of `owner/name`. A dry run works
offline and stops with files in an output directory: no push, no PR, no comment (see "Dry run").
If the repository already has `docs/graph.yaml`, stop and say so: changing its plan is a triage job.

## 1. Facts first (deterministic)
- Work in a fresh clone or worktree, never in someone's checkout:
  `gh repo clone <owner/name> <dir>` (or `git fetch origin && git worktree add -b spec/adopt <dir> origin/<default branch>`).
  Create the branch `spec/adopt` there. (A dry run on a local directory creates no clone and no
  branch and makes no commit; it stops with files in the output directory.)
- Read the code layout, the README and any `AGENTS.md`/`CLAUDE.md`/docs, the existing tests, the CI
  workflows, and how to build, test and lint (Makefile, package scripts, workflow steps). Note which
  commands pass today.
- Read the open issues: `gh issue list --state open --json number,title,body,labels` and
  `gh issue view <n> --comments` for the ones that matter. Note the work they ask for.
- Write down what you found and what you could not tell. Do not invent intent from the code.

## 2. Ask the owner (QUESTION.md), then stop
Write `QUESTION.md` with the questions only the owner can answer, numbered, each with your
recommendation so a bare "yes" works. Ask what the code cannot show:
1. scope and non-goals: what this repository is for and what it is not;
2. priorities and order: which work comes first, which can wait (`track: now` / `later`);
3. what is done and what is only planned (existing code that is half-built, issues already fixed);
4. principles and constraints that every change must respect;
5. open decisions that block work, with a default for each;
6. anything in the facts that conflicts or is unclear.
`<name>` is the repository's name, or the directory's basename for a local directory.
Put it in the run's output folder, `out/adopt/<name>/QUESTION.md` (the `--out <dir>` of a dry run:
`<dir>/QUESTION.md`), and tell the owner where it is.
Unattended, the run's own instructions for questions win. **Then stop**: no drafts before the owner's
`ANSWER.md` exists (next to `QUESTION.md`, or the file given by `--answers`). On resume, read `ANSWER.md`; a question it leaves open
becomes an open decision with your default, not a guess presented as settled.

## 3. Drafts
Only after `ANSWER.md`. Order: the graph first, then the specs, so they agree.
- **`SPEC.md`**: what this is, principles (from the answers), architecture, the node spec template
  (a `## Node spec template` section giving the headings below), open decisions with defaults,
  conventions (branches `node/<ID>-<name>` and `spec/<topic>`, sizes, when a node is done).
- **`docs/graph.yaml`**: `template: {headings: [Purpose, Tests, Changes, Gate, Risks]}` (or the
  repository's own list) and `nodes:`, each with `id` (a letter and two digits, one letter per family
  of work), kebab-case `name`, `deps` (only what a node's gate truly needs), `track`, one-sentence
  `summary`, and `decisions` where the owner must settle one first.
- **`nodes/<ID>-<name>.md`**, one per node, following the template: title `# <ID> — <name>`, a header
  row `| Track | Deps | Unlocks | Size |` matching the graph, **Owns:** (paths the node creates or
  changes), the template's headings, and criteria `**<ID>-AC-<n>**` numbered from 1, each one testable
  with *Verify:*. The checker (`<plugin dir>/skills/node/check-regime.py`; read it) requires: Deps and
  Unlocks written `none` when empty, Unlocks being the nodes that depend on this one, each criterion
  as one line `- **<ID>-AC-<n>** — … *Verify:* …`, and IDs of a capital letter and two digits. Work already done is not a node: say in `SPEC.md` that it exists, or note it in the
  Purpose of the node that builds on it. Size nodes honestly (S under a day, M two or three, L more).
  Issues become nodes or criteria. A node drafted from an issue gets `**Resolves:** #<n>` right after
  its **Owns:** line, so the node's PR fixes it; this PR itself only says `Refs #N`.
  Drafts name no repository, not even the plugin: refer to the plugin's skills and checker by role
  and placeholder path (`<plugin dir>/...`).
- **`AGENTS.md`**, a "Building a node" section (add to an existing file, do not replace it):
  authority order (`SPEC.md`, `docs/graph.yaml`, the node spec, then `AGENTS.md`); role agents: the
  plugin's tester, implementer and reviewer, unless the repository has its own; the spec checker
  (`python3 -I <plugin dir>/skills/node/check-regime.py`, PROBLEMS 0); the test, lint and CI commands
  that exist; the form of a red target (a command that exits non-zero before and 0 after); the test and
  fixture paths; porting rules or "none"; what CI evidence to record.
- **The role guard's config** (`<plugin dir>/hooks/guard.py`: its docstring gives the file's location,
  its `DEFAULTS` the default globs, which treat `**/*.test.sh`, `**/tests/**`, `**/testdata/**`,
  `**/fixtures/**` etc. as tests) only if those defaults do not match the repository's test paths
  (`tests:` and `specs:`, root-relative globs).
Do not write implementation or tests.

## 4. Check
Run `python3 -I <plugin dir>/skills/node/check-regime.py --root <dir>` until it prints `PROBLEMS 0`,
fixing the drafts (not the checker). Also check the drafted `AGENTS.md` commands exist.

## 5. The PR
- One commit on `spec/adopt`, subject `Spec: adopt the repository into the graph regime`, body: what
  was drafted and the owner's answers it carries out.
- Push the branch and open one PR (`gh pr create`). Body: what was drafted; which owner answers it
  carries out (by number); open decisions and their defaults; what to check first (scope, track
  order, sizes); `Refs #N` for the issues the nodes cover. Never merge, approve or push to main.

**Closing keywords.** GitHub closes an issue when a PR description, or a commit message that reaches main, contains a
closing keyword (close, closes, closed, fix, fixes, fixed, resolve, resolves, resolved, with or
without a colon) followed by its number. Write none here: use "issue #N" or "Refs #N", because the
node that builds the work, not this PR, fixes the issue.

## Dry run
With `--dry-run`, run sections 1 to 4 offline against a local directory or a clone:
- Issues come from `issues.json` in that directory if present (the form of
  `gh issue list --json number,title,body,labels`), else there are none.
- The owner's answers come from the `--answers <file>` the caller names, else an `ANSWER.md` in the
  output directory, else one in the input directory. If none exists, write `QUESTION.md` (into the
  output directory) and stop as usual. If one exists, `QUESTION.md` is still written there first, as the record.
- Write the drafts into an output directory (`--out <dir>`, else `out/adopt/<name>/`) holding
  `SPEC.md`, `AGENTS.md`, `docs/graph.yaml` and `nodes/`; never write into the input directory. Run the
  checker with `--root` on it. No push, no PR, no comment.
- Print a result summary: the output directory, nodes and criteria drafted, the checker's last line.

## 6. Report
End with: the repository, the PR URL (or the output directory for a dry run), the nodes drafted, the
checker's result, and what the owner should check first.
