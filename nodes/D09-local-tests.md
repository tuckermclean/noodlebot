# D09 — local-tests

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D03, R02 | none | S |

**Owns:** in `AGENTS.md`, the `make test` line of Commands and the **Tests:** and **CI evidence:** lines of "Building a
node" (the quick gate and the whole suite); in `plugin/skills/node/SKILL.md`, the wording of the quick test gate at
GREEN (step 3), of local runs (step 5), of the update procedure's test run (its step 4) and of the feedback procedure's
(its step 3); the quick-gate lines of `plugin/agents/tester.md`, `plugin/agents/implementer.md` and
`plugin/agents/reviewer.md` and of this repository's `.claude/agents/noodlebot-tester.md`,
`.claude/agents/noodlebot-implementer.md` and `.claude/agents/noodlebot-reviewer.md`; the test-run lines of the
session templates `scheduler/unattended*.md` (the MERGE CONFLICTS rerun); their cases in
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
  test files of the files a change touches, run as `make test TESTS="<files>"`, and leaves the whole `make test` to CI
  on the PR; `.claude/agents/noodlebot-*.md` and `scheduler/unattended*.md` name the quick gate, and none of them tells
  a session to run the whole `make test` (a bare `make test` with no `TESTS=`) as its gate. A planted bare `make test`
  in a copy of an agent file makes the check fail, naming file and line.

## Changes
1. **The quick gate in `AGENTS.md`.** The **Tests:** line says: the quick gate is the change's red targets plus the
   test files of each file it touches (for `scheduler/<name>.sh` or `.py`, `scheduler/<name>.test.sh` and
   `scheduler/<name>-*.test.sh`; for another file, the test files that name it), run through
   `make test TESTS="<files>"`; the whole `make test` runs in CI on the PR (`.github/workflows/test.yml`), and a session
   does not run it locally. The Commands line keeps `make test` as the whole suite and says it is CI's. The **CI
   evidence:** line names the PR's CI run as the whole suite's evidence. *D09-AC-1.*
2. **The node skill.** Where the skill runs "the repository's quick test gate" (GREEN, local runs, the reviewer's
   re-run), it is the quick gate `AGENTS.md` names, run locally; the whole suite is shown by the PR's CI run, recorded
   in the evidence table. The update procedure (step 4) and the feedback procedure (step 3) run the quick gate for the
   files the merge or the change touched and the red targets, and take the whole suite's result from the PR's CI run
   after the push, said on the PR. *D09-AC-2.*
3. **The agents.** `plugin/agents/*.md` and this repository's `.claude/agents/noodlebot-*.md` name the quick gate where
   they now name `make test` or the quick test gate, never the whole suite. *D09-AC-2, D09-AC-1.*
4. **The session templates.** The MERGE CONFLICTS rerun of `scheduler/unattended.md` and
   `scheduler/unattended-followup.md` (and any other test run a template asks for) is the quick gate plus every red
   target of the node. *D09-AC-1.*

## Gate
- **D09-AC-1** — `AGENTS.md` defines the quick gate as the red targets plus the touched files' test files, run with `make test TESTS="<files>"`, and leaves the whole `make test` to CI on the PR as the whole suite's evidence; this repository's agents and the session templates name the quick gate and none tells a session to run the whole `make test` locally; a planted bare `make test` gate line fails the check, naming file and line. *Verify:* `sh scheduler/quick-gate.test.sh`.
- **D09-AC-2** — The node skill and the plugin's tester, implementer and reviewer run the quick gate locally at GREEN, in local runs, in the reviewer's re-run, and in the update and feedback procedures, and take the whole suite's evidence from the PR's CI run. *Verify:* `sh plugin/skills/node/skill.test.sh`.

## Risks
- A change to `scheduler/loop.sh` still touches many `loop*.test.sh` files; the quick gate is lighter than the whole
  suite, not light. `TEST_JOBS` still bounds how many run at once.
- A test file that breaks only with a change elsewhere is found in CI, after the push, rather than before it. The PR's
  CI run is already required evidence, so it is found before the owner merges.
- Sessions follow the texts by reading them; nothing stops one from running the whole suite anyway. The check covers
  the texts, not the sessions.
- `deploy.sh`'s local `make test` (a deploy without `deploy-ci`) is unchanged; D07's CI gate is how a deploy avoids it.
