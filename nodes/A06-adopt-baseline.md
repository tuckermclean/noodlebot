# A06 — adopt-baseline

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A01, A03 | A07 | M |

**Owns:** in `plugin/skills/adopt/SKILL.md`, the facts (section 1), the questions (section 2), the drafts of the first
adoption PR (section 3), its checks (section 4) and the dry run; the worked example under
`plugin/skills/adopt/example/`; the fixture repository and answers under `plugin/skills/adopt/testdata/`; their cases
in `plugin/skills/adopt/adopt.test.sh`.

## Purpose
After this node the first step of an adoption is small, checkable and honest about the repository's health. Instead of
reading the whole repository and drafting the whole plan at once, `/noodlebot:adopt` reads A03's inventory and the
project's own documents, asks the owner to confirm the test command, what to leave out and how to split the code
into areas, runs the test command once and records what already fails, and opens one PR that sets up the regime: the
main spec, the `AGENTS.md` section, and a graph with the `gate`, `out_of_scope` and the `adoption` areas, and no nodes
yet. Mapping the areas into imported nodes is A07's work.

## Tests
- `plugin/skills/adopt/adopt.test.sh` (extended):
  - the skill's text: it reads `inventory.py`'s output instead of every file, asks for the gate command, the
    out-of-scope paths and the areas (each with a recommendation), runs the gate once, records `known_red`, drafts no
    nodes, and runs `check-regime.py` and `check-coverage.py` before the PR;
  - a dry run on the fixture repository with recorded answers: its `docs/graph.yaml` has a `gate` whose `known_red`
    names the fixture's one failing test, `out_of_scope` with the fixture's vendored folder, and `adoption` areas
    that, with it, cover every tracked file; `check-regime.py` and `check-coverage.py` report `PROBLEMS 0` on the
    output.
- The example under `plugin/skills/adopt/example/` is the recorded dry run.

## Changes
1. **Facts from the inventory.** Section 1 runs `inventory.py --json --areas` on the clone and reads the summary, the
   README, any `AGENTS.md`, `CLAUDE.md` and docs, the build and CI files, and the issues. It does not read source
   files beyond what a question needs. *A06-AC-1.*
2. **The questions** keep today's (scope, priorities, what is done, principles, open decisions) and add three, each
   with a recommendation: the gate command (proposed from CI, the Makefile or the package scripts); the paths to
   leave out of scope, with reasons (proposed from the inventory's candidates); and the areas (the inventory's
   proposal, which the owner may rename, merge or split). *A06-AC-1.*
3. **The baseline.** After the answers, the skill runs the gate command once in the clone. Each failure is recorded in
   `gate.known_red` under a name the command prints the same way each run. A command that cannot run here stops the
   run with a question; an adoption needs a gate that runs. *A06-AC-2.*
4. **The first PR** drafts `SPEC.md`, the `AGENTS.md` "Building a node" section (with the gate command and the rules
   for `owns` and `known_red`), `.noodlebot/roles.yaml` where the guard's defaults do not fit, and `docs/graph.yaml`
   with the template, `gate`, `out_of_scope` and `adoption: {areas}`, and no nodes: open issues become nodes once the
   code is mapped (A07). `check-regime.py` and `check-coverage.py` must report `PROBLEMS 0` before the push, so every
   tracked file is out of scope or in an area. The PR is `spec/adopt`, as today. *A06-AC-2, A06-AC-3.*
5. **The dry run** does the same offline into its output folder, the gate run included. *A06-AC-3.*

## Gate
- **A06-AC-1** — The skill reads the inventory instead of every file and asks for the gate command, the out-of-scope paths and the areas, each with a recommendation. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A06-AC-2** — The skill runs the gate once, records its failures in `known_red`, stops with a question when the gate cannot run, and drafts a graph with `gate`, `out_of_scope` and `adoption` areas and no nodes. *Verify:* `sh plugin/skills/adopt/adopt.test.sh`.
- **A06-AC-3** — The recorded dry run on the fixture gives a graph whose `known_red` names the fixture's failing test and on which `check-regime.py` and `check-coverage.py` report `PROBLEMS 0`. *Verify:* `sh plugin/skills/adopt/adopt.test.sh` and the example under `plugin/skills/adopt/example/`.

## Risks
- The gate runs the repository's own command on the scheduler's machine. The command is the one the owner confirmed,
  and it runs in the adoption's clone, never in a checkout someone works in.
- A test suite that is flaky gives an unstable `known_red`; the skill runs the gate once, and a later node that sees a
  listed failure pass removes it (A05).
- A repository too small to split gets one area covering everything; the first PR is then mostly the gate and the
  main spec.
