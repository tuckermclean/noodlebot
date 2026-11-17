# D09 — local-tests

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03, R02 | none | S |

**Owns:** in `AGENTS.md`, the `make test` line of Commands and the **Tests:** and **CI evidence:** lines of "Building a
node" (the quick gate and the whole suite); in `plugin/skills/node/SKILL.md`, the wording of the quick test gate at
GREEN (step 3), of local runs (step 5), of the update procedure's test run (its step 4) and of the feedback procedure's
(its step 3); the quick-gate lines of `plugin/agents/tester.md` (with its line on wiring a new test file in),
`plugin/agents/implementer.md` and `plugin/agents/reviewer.md` and of this repository's
`.claude/agents/noodlebot-tester.md`, `.claude/agents/noodlebot-implementer.md` and
`.claude/agents/noodlebot-reviewer.md`; the test-run lines of the session templates that run tests
(`scheduler/unattended.md` and `scheduler/unattended-followup.md`, their MERGE CONFLICTS rerun, and
`scheduler/unattended-node-update.md`, its rerun after a merge); their cases in
`plugin/skills/node/skill.test.sh` and the new `scheduler/quick-gate.test.sh` with its line in the `Makefile`'s `TESTS`.
**Resolves:** #139

## Purpose
After this node a session on the scheduler's machine runs only the tests its change touches, and the whole suite runs
in CI on the PR. Today `AGENTS.md` makes `make test` both the quick gate and the whole suite, and `runtests.sh` runs
`2 × nproc` files at once, so several sessions each running the whole suite drove the 4-CPU host to a load of about 20
and slowed every session, loop and deploy on it. The quick gate becomes the red targets and the test files of what the
change touches; the PR's CI run of `make test` is the evidence that the whole suite passes.

## Tests
- `plugin/skills/node/skill.test.sh` (extended): the skill says the quick test gate is what the repository's
  `AGENTS.md` names, run locally, and that the whole suite's evidence is the PR's CI run; its GREEN check, local runs,
  update procedure and feedback procedure run the quick gate (the red targets and the touched files' tests) locally and
  read the whole suite from CI; the three plugin agents name the quick gate and no whole-suite run.
- `scheduler/quick-gate.test.sh` (new): this repository's `AGENTS.md` defines the quick gate as the red targets plus the
  test files of the files a change touches, run as `TEST_JOBS=2 make test TESTS="<files>"`, and leaves the whole
  `make test` to CI on the PR; `.claude/agents/noodlebot-*.md` and the session templates that run tests
  (`scheduler/unattended.md`, `scheduler/unattended-followup.md` and `scheduler/unattended-node-update.md`, no other)
  name the quick gate, and none of them tells a session to run the whole suite as its gate: neither a bare `make test`
  (no `TESTS=`) nor "the repository's test entry point". A planted bare `make test` in a copy of an agent file, and a
  planted "test entry point" in a copy of `unattended-node-update.md`, each make the check fail, naming file and line.

## Changes
1. **The quick gate in `AGENTS.md`.** The **Tests:** line says: the quick gate is the change's red targets plus the
   test files of each file it touches (for `scheduler/<name>.sh` or `.py`, `scheduler/<name>.test.sh` and
   `scheduler/<name>-*.test.sh`; for another file, the test files that name it), run through
   `TEST_JOBS=2 make test TESTS="<files>"`, so that a change to `scheduler/loop.sh`, whose quick gate is about a hundred
   test files, runs two at a time; the whole `make test` runs in CI on the PR (`.github/workflows/test.yml`), and a session
   does not run it locally. The Commands line keeps `make test` as the whole suite and says it is CI's. The **CI
   evidence:** line names the PR's CI run as the whole suite's evidence. *D09-AC-1.*
2. **The node skill.** Where the skill runs "the repository's quick test gate" (GREEN, local runs, the reviewer's
   re-run), it is the quick gate `AGENTS.md` names, run locally; the whole suite is shown by the PR's CI run, recorded
   in the evidence table. The update procedure (step 4) and the feedback procedure (step 3) run the quick gate for the
   files the merge or the change touched and the red targets, and take the whole suite's result from the PR's CI run
   after the push, said on the PR. *D09-AC-2.*
3. **The agents.** `plugin/agents/*.md` and this repository's `.claude/agents/noodlebot-*.md` name the quick gate where
   they now name `make test` or the quick test gate, never the whole suite. The tester's line on a new test file
   (`plugin/agents/tester.md`, "wired into the repository's quick test gate") says instead that the file is added to
   the list of test files `AGENTS.md` names, such as a `Makefile`'s `TESTS`, from which the whole suite and the quick
   gate run; `.claude/agents/noodlebot-tester.md` names the `Makefile`'s `TESTS`. *D09-AC-2, D09-AC-1.*
4. **The session templates.** The MERGE CONFLICTS rerun of `scheduler/unattended.md` and
   `scheduler/unattended-followup.md` is the quick gate plus every red target of the node, and
   `scheduler/unattended-node-update.md`'s rerun after the merge ("the repository's test entry point" today) is the
   quick gate for the files the merge touched plus the PR's red targets. The templates that run no tests are
   unchanged. *D09-AC-1.*

## Gate
- **D09-AC-1** — `AGENTS.md` defines the quick gate as the red targets plus the touched files' test files, run with `TEST_JOBS=2 make test TESTS="<files>"`, and leaves the whole `make test` to CI on the PR as the whole suite's evidence; this repository's agents and the session templates that run tests (`unattended.md`, `unattended-followup.md`, `unattended-node-update.md`) name the quick gate and none tells a session to run the whole suite locally (a bare `make test` or "the repository's test entry point"); a planted bare `make test` in an agent file and a planted "test entry point" in `unattended-node-update.md` each fail the check, naming file and line. *Verify:* `sh scheduler/quick-gate.test.sh`.
- **D09-AC-2** — The node skill and the plugin's tester, implementer and reviewer run the quick gate locally at GREEN, in local runs, in the reviewer's re-run, and in the update and feedback procedures, and take the whole suite's evidence from the PR's CI run; the plugin's tester adds a new test file to the list of test files `AGENTS.md` names (such as a `Makefile`'s `TESTS`). *Verify:* `sh plugin/skills/node/skill.test.sh`.

## Risks
- A change to `scheduler/loop.sh` still touches about a hundred test files; the quick gate is lighter than the whole
  suite, not light, and `TEST_JOBS=2` makes it slower in wall time to keep the host's load down. A file over its
  `TEST_FILE_BUDGET` only when run two at a time prints a `SLOW` line locally and does not fail: the budget is
  enforced only where `TEST_BUDGET_ENFORCE=1` is set, in CI.
- A test file that breaks only with a change elsewhere is found in CI, after the push, rather than before it. The PR's
  CI run is already required evidence, so it is found before the owner merges.
- Sessions follow the texts by reading them; nothing stops one from running the whole suite anyway. The check covers
  the texts, not the sessions.
- `deploy.sh`'s local `make test` (a deploy without `deploy-ci`) is unchanged; D07's CI gate is how a deploy avoids it.
