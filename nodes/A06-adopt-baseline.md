# A06 — adopt-baseline

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A01, A03, A04 | A07 | M |

**Owns:** in `plugin/skills/adopt/SKILL.md`, the facts (section 1), the questions (section 2), the drafts of the first
adoption PR (section 3), its checks (section 4) and the dry run; the new recorded dry run under
`plugin/skills/adopt/example-baseline/`; the new fixture repository and answers under
`plugin/skills/adopt/testdata/baseline/` (`repo/` and `ANSWER.md`); their cases in `plugin/skills/adopt/adopt.test.sh`.
The existing fixture `plugin/skills/adopt/testdata/repo/` and worked example `plugin/skills/adopt/example/` stay as they
are.

## Purpose
After this node the first step of an adoption is small, checkable and honest about the repository's health. Instead of
reading the whole repository and drafting the whole plan at once, `/noodlebot:adopt` reads A03's inventory and the
project's own documents, asks the owner to confirm the test command, what to leave out and how to split the repository
into areas, runs the test command once and records what already fails, and opens one PR that sets up the regime: the
main spec, the `AGENTS.md` section, and a graph with the `gate`, `out_of_scope` and the `adoption` areas, and no nodes
yet. Mapping the areas into imported nodes is A07's work. This replaces the part of A01's flow that drafted node
specs in the first PR; A01's worked example `example/` stays as the record of that earlier flow.

## Tests
- `plugin/skills/adopt/adopt.test.sh` (extended):
  - the skill's text: it reads `inventory.py`'s output instead of every file, asks for the gate command, the
    out-of-scope paths and the areas (each with a recommendation), runs the gate once, records `known_red`, drafts
    `nodes: []`, and runs `check-regime.py` and `check-coverage.py` before the PR;
  - the recorded dry run under `example-baseline/`, made from `testdata/baseline/repo/` (a small repository with a
    vendored folder, which the test creates at run time and adds with `git add -f`, and one failing test) and
    `testdata/baseline/ANSWER.md`: its `docs/graph.yaml` has `nodes: []`, a `gate` with a `fail_pattern` and a
    `known_red` naming the fixture's failing test, `out_of_scope` with the vendored folder, and `adoption` areas;
  - the coverage of that dry run: the test copies the fixture repository to a temporary folder, lays the drafted
    `SPEC.md`, `AGENTS.md`, `docs/graph.yaml`, `nodes/` and `.noodlebot/roles.yaml` over it (not `QUESTION.md` or
    `FACTS.md`), commits it with `git init`, and runs `check-regime.py --root` and `check-coverage.py --root` there,
    both `PROBLEMS 0`.
  - The existing checks of `example/` keep passing unchanged.

## Changes
1. **Facts from the inventory.** Section 1 runs `inventory.py --json --areas` on the clone and reads the summary, the
   README, any `AGENTS.md`, `CLAUDE.md` and docs, the build and CI files, and the issues. It does not read source
   files beyond what a question needs. *A06-AC-1.*
2. **The questions** keep today's (scope, priorities, what is done, principles, open decisions) and add three, each
   with a recommendation: the gate command (proposed from CI, the Makefile or the package scripts); the paths to
   leave out of scope, with reasons (proposed from the inventory's candidates); and the areas (the inventory's
   proposal, which the owner may rename, merge or split). A candidate the owner keeps in scope goes into an area.
   *A06-AC-1.*
3. **The baseline.** After the answers, the skill runs the gate command once in the clone. It records in
   `gate.fail_pattern` a regular expression matching the lines the command prints for a failure (asked for with the
   gate command when the output does not make it plain), and each failing test in `gate.known_red` as its full name
   as such a line prints it (the text A05 matches). The pattern matches only lines that name a failing test (a
   summary line that names none is not matched), so that in the baseline run every matched line contains a
   `known_red` entry, and at least one line is matched when the command exits non-zero: the baseline passes A05's
   rule. A command that cannot run here stops the run with a question: an adoption needs a gate that runs.
   *A06-AC-2.*
4. **The first PR** drafts `SPEC.md`, the `AGENTS.md` "Building a node" section (with the gate command and the rules
   for `owns` and `known_red`), `.noodlebot/roles.yaml` where the guard's defaults do not fit, and `docs/graph.yaml`
   with the template, `gate`, `out_of_scope`, `adoption: {areas}` and `nodes: []`. Open issues become nodes once the
   code is mapped (A07). `check-regime.py` and `check-coverage.py` must report `PROBLEMS 0` before the push: every
   tracked file is a regime file, out of scope, or in an area. The PR is `spec/adopt`, as today. *A06-AC-2,
   A06-AC-3.*
5. **The dry run** does the same offline into its output folder, the gate run included: it copies the input
   repository to a temporary folder first and runs the gate there, so nothing is written into the input. *A06-AC-3.*

## Gate
- **A06-AC-1** — The skill reads the inventory instead of every file and asks for the gate command, the out-of-scope paths and the areas, each with a recommendation. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A06-AC-2** — The skill runs the gate once, records a `fail_pattern` and each failing test's full name in `known_red`, stops with a question when the gate cannot run, and drafts a graph with `gate`, `out_of_scope`, `adoption` areas and `nodes: []`. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A06-AC-3** — The recorded dry run under `example-baseline/` gives a graph with `nodes: []` whose `known_red` names the fixture's failing test; the test runs its `gate.command` in a copy of the fixture, applies `fail_pattern`, and finds at least one matched line, each containing a `known_red` entry; and laid over the fixture repository as the Tests say, `check-regime.py` and `check-coverage.py` report `PROBLEMS 0`; the checks of `example/` still pass. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.

## Risks
- The gate runs the repository's own command on the scheduler's machine. The command is the one the owner confirmed,
  and it runs in the adoption's clone, never in a checkout someone works in.
- A flaky suite gives an unstable `known_red`; the skill runs the gate once, and a later node that sees a listed
  failure pass removes it (A05).
- A repository too small to split gets one area covering everything.
- A frozen check of `adopt.test.sh` allows "noodlebot" in the adopt skill only as `/noodlebot:<skill>` and
  `.noodlebot/`; the new text names no label or other noodlebot word.
