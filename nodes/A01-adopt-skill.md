# A01 — adopt-skill

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | R01 | none | L |

**Owns:** `plugin/skills/adopt/` (the skill and its fixture-based checks).

## Purpose
After this node the bot can bring a repository that has no graph into the regime: `/noodlebot:adopt <owner/name>` reads its code, README and open issues, asks the owner what the code cannot show (scope, priorities, what is done), and drafts `SPEC.md`, `docs/graph.yaml`, the node specs and an `AGENTS.md` "Building a node" section as one PR for the owner. noodlebot's own adoption (done by hand) is the worked example.

## Tests
- A fixture repository without a graph, and a dry run of the skill on it whose output `check-regime.py` checks.
- A recorded real run on a small repository chosen by the owner.

## Changes
1. **The skill** `plugin/skills/adopt/SKILL.md`: facts first (code, README, issues, existing tests and CI), then questions to the owner as a QUESTION.md, then the drafts, then `check-regime.py`, then one PR on a `spec/adopt` branch. *AC-1, AC-2, AC-3.*
2. **Role agents** come from the plugin (R01), so the adopted repository needs none of its own. *AC-2.*

## Gate
- **A01-AC-1** — `/noodlebot:adopt` exists in the plugin and names no repository. *Verify:* a check in the skill's test.
- **A01-AC-2** — On the fixture repository, a dry run produces `SPEC.md`, `docs/graph.yaml`, node specs and an `AGENTS.md` "Building a node" section that `check-regime.py` passes with PROBLEMS 0. *Verify:* the recorded dry run and its checker output.
- **A01-AC-3** — A real run opens one PR on a `spec/adopt` branch and asks the owner, through QUESTION.md, for what the code cannot show, before drafting nodes. *Verify:* the recorded run and the PR URL.

## Risks
- The first adoption of a real repository is where the skill's gaps show; expect a follow-up.
