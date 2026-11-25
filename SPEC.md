# noodlebot — Specification

## 0. What this is

noodlebot is the n00dl3b0t's automation. A scheduler builds a repository's planned work, its node
graph, with unattended Claude Code sessions, test-first, and hands every result to the owner as a pull
request or a question. It runs on one machine, for several repositories, as the GitHub App
`n00dl3b0t`. noodlebot is itself one of those repositories: its own work is planned and built the same
way.

## 1. Principles

1. **The owner sets the rules and merges the plan.** Bots never push to `main`, change branch protection
   or repository settings, or merge a spec or adoption PR. Only the reviewer App may approve or request
   changes on a PR, and only for the exact head it reviewed. A node PR is merged by the forge's own
   auto-merge, under the branch protection the owner sets, once the auto-gate holds at its head (the
   reviewer App's approval at that head is one of its points); the loop only turns auto-merge on. Spec
   and adoption PRs, and approvals of frozen-test changes, stay the owner's alone. Every result reaches
   the owner as a PR, a comment or a question.
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
- `container/`: the image (`Containerfile`, the entrypoint that puts the live checkout on the home volume and starts the
  loops), `compose.yaml` for one host and `k8s/` for a cluster (one replica), with `.containerignore` and the image
  workflow `.github/workflows/image.yml`.
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
- **Adopted repositories** (nodes A02–A08). A repository brought into the regime by `/noodlebot:adopt` has its whole
  existing code in the graph, not only the work still to do. A node has a `status`: `planned` (work to build, the
  default), `imported` (code that already exists, described by its spec) or `pinned` (imported, with every criterion
  shown by a test or superseded by a later node's). It names the files it owns as `owns:` globs, and every tracked file is owned by exactly one node or
  listed under `out_of_scope:` with a reason, lies in an adoption area still to map, or is one of the
  regime's own files. The graph's `gate:` names the repository's one test command and the
  failures it already had when adopted (`known_red`). While an adoption is in progress, `adoption: {areas: [...]}` lists
  the parts of the code still to map; the graph itself is the record of what has been mapped. Imported and pinned
  nodes are done: they are never started and they satisfy deps. A node's change stays within its own files and its
  deps' files; behaviour of imported code it keeps is pinned by a test before the code is changed, and behaviour it
  changes is superseded by its own criteria. A graph with none of
  these fields means what it always has.
- **The reviewer** (nodes G12, S16, S17, G13, U08). A second GitHub App, separate from `n00dl3b0t` and with its own
  token script, reviews every open PR at each new head once the head has settled and its CI has finished. A read-only
  session with no forge credential writes a JSON review that `scheduler/reviewer.py draft` checks (the verdict
  follows the findings), and the loop posts it as one review at that head through a forge profile that allows only
  reviews and the reviewer's own threads. Its `request_changes` at a PR's current head is feedback like the owner's.
  It never approves a frozen-test change the owner has not approved, nor a change that needs the owner's decision.
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
- A node is done when every criterion passes in CI on `main` and the owner has merged its PR. An imported or pinned
  node (an adopted repository's existing code) is done by declaration.

## 4. Open decisions

None.

## 5. Conventions

- Branches `node/<ID>-<name>` (one node per PR, squash-merged) and `spec/<topic>` (spec changes).
- A PR body or commit message names an issue with a closing keyword only where it is meant to close it.
- Write specs and docs as the current state; change notes go in commit messages.
