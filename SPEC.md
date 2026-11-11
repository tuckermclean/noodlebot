# noodlebot — Specification

## 0. What this is

noodlebot is the n00dl3b0t's automation. A scheduler builds a repository's planned work, its node
graph, with unattended Claude Code sessions, test-first, and hands every result to the owner as a pull
request or a question. It runs on one machine, for several repositories, as the GitHub App
`n00dl3b0t`. noodlebot is itself one of those repositories: its own work is planned and built the same
way.

## 1. Principles

1. **The owner merges.** Bots never merge, approve, push to `main`, or change branch protection or
   repository settings. Every result reaches the owner as a PR, a comment or a question.
2. **Not precious.** Every piece can be thrown away and rebuilt from Git and GitHub: a closed status
   issue is replaced, a lost worktree recreated, a restarted loop takes over running sessions. A failing
   part logs its failure and the rest carries on.
3. **Repository-agnostic.** Nothing in the scheduler or the plugin names one repository. A
   repository's own facts (its documents' authority, role agents, commands, porting rules) live in that
   repository's `AGENTS.md`, section "Building a node".
4. **Credentials stay outside.** They live in `~/.config/noodlebot/`, are fetched per command, and are
   never printed, logged, committed or stored in Git configuration. Sessions get them only through the
   token script.
5. **Tested.** `make test` covers every scheduler path end to end, with fake `gh` and `claude`, and runs
   in CI on every PR.
6. **Safe to change while running.** Scripts a running loop or session executes are replaced (write a
   new file, then rename it), never edited in place: bash reads a script as it runs it.
7. **Forge- and harness-agnostic.** The scheduler, the skills and the session templates reach the code
   forge and the agent harness only through backend interfaces. GitHub and Claude Code are backends like
   any other, chosen per loop (default `github`, `claude-code`).

## 2. Architecture

- `scheduler/`: `loop.sh` (one loop per repository: `loop.sh <owner/name>`), `run-session.sh` (one
  unattended session), `ready.py` (which nodes may start), `release-markers.sh` (answers and merged
  spec PRs), `issues.py` (issues the owner labels `noodlebot`), `report.py` (the status issue),
  `status.sh` (a terminal view), `move-runtime.sh` (the one-time move of an older installation's runtime
  folders to the runtime root), and the session templates `unattended.md` and
  `unattended-triage.md`.
- `plugin/`: the Claude Code plugin every session loads (`--plugin-dir`): the skills
  `/noodlebot:node` (build a node) and `/noodlebot:triage` (fit an issue into the graph), and the graph
  regime's spec checker `plugin/skills/node/check-regime.py`.
- Runtime, outside any checkout: the runtime root `$NOODLEBOT_DATA` (default `~/.local/share/noodlebot`)
  holds `repos/<name>` (a clone per repository), `worktrees/<name>/<ID>` (one per running node) and
  `state/<name>/` (logs, markers, the status issue's state, archived evidence). Every loop and helper
  must see the same `NOODLEBOT_DATA`; the root may not lie inside a Git working tree.
- **The graph regime.** A repository under it has `docs/graph.yaml` (nodes with id, name, deps,
  track, summary), one spec per node `nodes/<ID>-<name>.md`, and an `AGENTS.md` "Building a node"
  section. `check-regime.py` checks the first two.
- **Backends.** The forge interface (`scheduler/forge.py`, node G04) and the harness interface
  (`scheduler/harness.py`, node S08) are core's only way to the code forge and the agent harness; what
  only makes sense for one backend (the GitHub App token script, gist publishing and the Pages
  workflow, Claude Code's plugin manifest and hook wiring, the parsing of stream-json) lives in that
  backend, and core turns a capability off, with one logged line, when the loop's backend lacks it.

## 3. Node spec template

Every `nodes/<ID>-<name>.md` follows this template (`docs/graph.yaml` names its headings):

```markdown
# <ID> — <name>

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now / later | <deps or none> | <nodes that depend on this, or none> | S / M / L |

**Owns:** <paths this node creates or changes>

## Purpose
2–4 sentences: what exists afterwards that did not before.

## Tests
The tests this node adds (and existing tests it extends), and what each shows.

## Changes
Each change, numbered, with the criterion it produces.

## Gate
- **<ID>-AC-1** — <one testable statement>. *Verify:* <the test, reached by `make test`, or a recorded run>.

## Risks
Bullets: unverified behaviour, what could go wrong in production.
```

- AC ids are `<ID>-AC-<n>`, numbered from 1 and never reused. Sizes: S is under a day, M two or three
  days, L more.
- A node is done when every criterion passes in CI on `main` and the owner has merged its PR.

## 4. Open decisions

None.

## 5. Conventions

- Branches `node/<ID>-<name>` (one node per PR, squash-merged) and `spec/<topic>` (spec changes).
- A PR body or commit message names an issue with a closing keyword only where it is meant to close it.
- Write specs and docs as the current state; change notes go in commit messages.
