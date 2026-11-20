# D18 — bounded-tests

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | D09, R02, A06 | none | S |

**Owns:** the bounded-run rule (one paragraph or bullet each) in `plugin/skills/node/SKILL.md` (where it names the quick test gate), in `plugin/agents/tester.md`, `plugin/agents/implementer.md` and `plugin/agents/reviewer.md`, and in this repository's `.claude/agents/noodlebot-tester.md`, `.claude/agents/noodlebot-implementer.md` and `.claude/agents/noodlebot-reviewer.md`; the bounded-run sentence of `AGENTS.md`'s **Tests:** line; the bounded-run line of the AGENTS.md draft in `plugin/skills/adopt/SKILL.md`; `plugin/skills/node/bounded-tests.test.sh` (new) and its line in the `Makefile`'s `TESTS`.
**Resolves:** #218

## Purpose
After this node every session is told to keep its local test runs small: test runners run with bounded workers, one runner at a time, never a whole suite with its cache turned off, and a script that repeats the tests (a mutation sweep) runs them one after another and leaves no mutated file behind. The node skill, its three role agents and this repository's own agents say so; this repository's `AGENTS.md` names its own bounds; the adopt skill's AGENTS.md draft names the concrete flags of an adopted repository's test runner.

## Tests
- `plugin/skills/node/bounded-tests.test.sh` (new) reads the files this node changes and shows, each check on the clause it names:
  - `plugin/skills/node/SKILL.md` and each of `plugin/agents/{tester,implementer,reviewer}.md` and `.claude/agents/noodlebot-{tester,implementer,reviewer}.md` state that a local test run uses bounded workers (the bound `AGENTS.md` names, else at most two), runs one test runner at a time, and never runs a whole suite with its cache off; and that a script repeating the tests (a mutation sweep) runs one run at a time, restores each changed file on every exit (a trap), and checks the worktree is clean (`git status`) after it;
  - the plugin files name no repository and no forge (as `scheduler/agnostic.test.sh` checks);
  - `AGENTS.md`'s **Tests:** line names this repository's bound (`TEST_JOBS=2` for the quick gate) and that a script repeating the tests runs one test file at a time;
  - `plugin/skills/adopt/SKILL.md`'s AGENTS.md draft has a line naming the test runner's bounded-worker flags as the adopted repository's own fact;
  - each check fails when its clause is removed or reversed (a mutation sweep of the wording recorded at RED).
- Every existing `plugin/**/*.test.sh` passes unchanged.

## Changes
1. **The node skill and agents.** One rule where the skill and each agent name the quick test gate: bounded workers, one runner at a time, no whole suite with the cache off; a repeating script runs one run at a time, restores on every exit and is followed by a clean-worktree check. *D18-AC-1.*
2. **This repository.** `AGENTS.md`'s **Tests:** line and the three `.claude/agents/noodlebot-*.md` say the same with this repository's bound. *D18-AC-2.*
3. **The adopt skill.** Its AGENTS.md draft gets a line for the test runner's bounded-worker flags (for example a worker limit), taken from the repository. *D18-AC-3.*

## Gate
- **D18-AC-1** — `plugin/skills/node/SKILL.md` and `plugin/agents/{tester,implementer,reviewer}.md` tell sessions to run test runners locally with bounded workers (the bound `AGENTS.md` names, else at most two), one runner at a time, never a whole suite with its cache off, and to run a script that repeats the tests one run at a time, restoring each changed file on every exit and checking the worktree is clean after it; they name no repository and no forge. *Verify:* `plugin/skills/node/bounded-tests.test.sh` and `scheduler/agnostic.test.sh`.
- **D18-AC-2** — `AGENTS.md`'s **Tests:** line and `.claude/agents/noodlebot-{tester,implementer,reviewer}.md` state this repository's bound (`TEST_JOBS=2` for the quick gate) and that a script repeating the tests runs one test file at a time and restores on every exit. *Verify:* `plugin/skills/node/bounded-tests.test.sh`.
- **D18-AC-3** — The AGENTS.md draft of `plugin/skills/adopt/SKILL.md` has a line for the test runner's bounded-worker flags, as the adopted repository's own fact. *Verify:* `plugin/skills/adopt/SKILL.md` checked by `plugin/skills/node/bounded-tests.test.sh`.

## Risks
- The rule is wording: a session can still ignore it; S12's memory ceiling is what holds when it does.
- Another repository's concrete flags (a jest worker limit, say) belong in that repository's `AGENTS.md`, through its own issue; this node only makes the adopt skill draft such a line for new adoptions.
- Bounded workers make a session's local runs slower; the whole suite still runs in CI on the PR (D09).
