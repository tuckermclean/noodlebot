# R01 — shared-roles

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | A01 | M |

**Owns:** `plugin/agents/` (tester, implementer, reviewer), `plugin/hooks/` (the role guard and its test), the role section of `plugin/skills/node/SKILL.md`.

## Purpose
After this node a repository under the regime needs no role agents of its own: the plugin provides a generic tester, implementer and reviewer, and a guard that holds each to its role. The paths each role may touch come from the repository (its test, fixture and spec paths), not from the plugin.

## Tests
- `plugin/hooks/guard.test.sh` (new): the guard's decisions for each role on writes inside and outside the test and spec paths, with a fixture repository configuration.
- A recorded session that dispatches the plugin's agents and shows the guard acting (or the record of why it cannot).

## Changes
1. **Find out what plugin agents support.** Whether a plugin agent's definition can carry hooks, and how a plugin-level hook can tell which role is acting. Record the answer, with its source, in the node's PR. *AC-3.*
2. **Generic role agents** in `plugin/agents/`, written from `noodlebot-*` and themonolith's `monolith-*` without naming a repository; repository facts come from its `AGENTS.md`. *AC-1.*
3. **The role guard** `plugin/hooks/guard.py`: a tester may write only the repository's test and fixture paths; an implementer may not write them or the spec paths; a reviewer writes nothing. The paths come from a small file in the repository (for example `.noodlebot/roles.yaml`), with defaults. *AC-2.*
4. **`/noodlebot:node`** dispatches the plugin's agents when the repository names none of its own. *AC-1.*

## Gate
- **R01-AC-1** — `plugin/agents/` holds a tester, an implementer and a reviewer that name no repository, and `/noodlebot:node` uses them when the repository's `AGENTS.md` names no role agents. *Verify:* a check in `plugin/hooks/guard.test.sh` (no repository names; the skill's rule) and a recorded session that dispatches them.
- **R01-AC-2** — The guard blocks a tester's write outside the test and fixture paths, an implementer's write to a test, fixture or spec path, and any reviewer write, and allows everything else. *Verify:* `plugin/hooks/guard.test.sh`.
- **R01-AC-3** — In a real session the guard applies to the plugin's agents; or, if Claude Code does not allow it, the PR records why (with its source) and how each role is held instead. *Verify:* the recorded session log, linked in the PR.

## Risks
- Plugin agents may not support hooks in their definitions (unverified); a plugin-level hook may have no way to know the acting role.
- themonolith keeps its own agents and guard until this node shows the plugin's are equivalent.
