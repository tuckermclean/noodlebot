# A02 — graph-ownership

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | A03, A04 | L |

**Owns:** `plugin/skills/node/owns.py` (new: the one glob matcher and the list of the regime's own files that every ownership
tool uses),
`plugin/skills/node/check-regime.py` (the new fields), `plugin/skills/node/check-regime.test.sh` and its fixtures under
`plugin/skills/node/testdata/regime/`; in `scheduler/ready.py`, imported and pinned nodes as done, with their cases in
`scheduler/ready.test.sh` and its new fixture `scheduler/testdata/graph-adopted.yaml`; the node states `imported` and `pinned` in `scheduler/api.py` and its node schema under
`scheduler/api-schema/`, in `scheduler/report.py`'s `merged_ids` and `start_info`, in `scheduler/site.py`, and in the
explorer's `site/explorer/graph.js`, `site/explorer/view.js` and `site/style.css`, and in the repositories card of
`site/views.js`, with their cases (and any new fixtures) in `scheduler/api.test.sh`, `scheduler/report.test.sh`,
`scheduler/site.test.sh`, `site/site.test.sh`, `site/test/views.test.mjs` and `site/test/explorer-graph.test.mjs`; in `plugin/skills/node/SKILL.md`, the deps precondition, with its case in
`plugin/skills/node/skill.test.sh`; in `plugin/skills/triage/`, the state column of `nodes.py` and the placement rules of
`SKILL.md` for imported and pinned nodes and for `owns`, with their cases in `plugin/skills/triage/nodes.test.sh`.

## Purpose
After this node `docs/graph.yaml` can describe a repository's existing code, not only the work still to build. A node
says whether it is work to build (`planned`), code that already exists (`imported`) or existing code whose behaviour
tests pin (`pinned`), and names the files it owns. The graph names the repository's test command and the failures it
already has, the paths it leaves out on purpose, and the areas an adoption has still to map. The checker validates all
of it; the scheduler, the node and triage skills, the API, the status issue and the site treat imported and pinned
nodes as done. noodlebot's own graph, which uses none of the new fields, is checked and scheduled exactly as before.

## Tests
- `plugin/skills/node/check-regime.test.sh` (extended), fixtures under `plugin/skills/node/testdata/regime/`: one valid
  adopted graph and one whose `adoption` has no area left (a `gate` with `known_red`, imported, pinned and planned nodes with `owns`, an `out_of_scope` entry, an
  `adoption` with two areas, specs whose **Owns:** paragraph wraps over several lines) and one fixture per problem of
  change 3, each asserting its line and exit 1; the existing fixture cases with the same output as before this node;
  this repository's graph (exit 0, `PROBLEMS 0`).
- `owns.py`'s matching, in the same test: `*`, `**` at the start, middle and end, a trailing `/`, a literal path, and a
  glob with no wildcard that names a folder.
- `scheduler/ready.test.sh` (extended, on the new fixture `scheduler/testdata/graph-adopted.yaml`; the existing
  fixture and its cases are unchanged): an imported and a pinned node are never printed, with or without markers, and a
  planned node whose deps are imported or pinned is ready.
- The existing API, report and site tests (extended): an imported and a pinned node have their own state, count as
  done in the API, in `report.py`'s `merged_ids` and start clause, in the explorer's remaining work and longest
  chain, and in the repositories card's count.
- `plugin/skills/node/skill.test.sh` (extended): the deps precondition accepts an imported or pinned dep.
- `plugin/skills/triage/nodes.test.sh` (extended): `nodes.py` shows `imported` and `pinned`; the skill's rules never
  amend an imported or pinned node and give a new node `owns` in a graph with ownership.

## Changes
1. **One matcher.** `plugin/skills/node/owns.py` matches root-relative paths against globs: `*` matches within one path
   component, `**` matches zero or more components, a trailing `/` (or a glob with no wildcard that names a folder) means the folder and
   everything under it. It also gives the regime's own files, which no node owns: the repository's spec files as
   `check-spec-diff.py` reads them (the **Spec files:** line of `AGENTS.md`, else `SPEC.md`, `docs/graph.yaml` and
   `nodes/`), plus `AGENTS.md` and `.noodlebot/roles.yaml`. Every ownership tool (A03, A04, A05) imports it.
   *A02-AC-2.*
2. **The fields.**
   - A node may have `status` (`planned` by default, `imported` or `pinned`) and `owns` (a list of globs).
   - An imported or pinned node needs a non-empty `owns`, has `track: done` (its header row says `done`), and each of
     its criteria's *Verify* either names the test that shows it, reads `unpinned` followed by how it could be shown,
     or reads `superseded by <ID>-AC-<n>` (A08). A pinned node has no `unpinned` criterion (superseded ones may stay).
   - A node with `owns` names each of its globs in backticks in its spec's **Owns:** paragraph (from **Owns:** to the
     next blank line or the next `**…:**` line).
   - Top-level `gate: {command, fail_pattern, known_red}`: `command` a non-empty string run from the repository root;
     `fail_pattern` a regular expression that matches the lines of its output that report a failure; `known_red` a
     list of strings, each a text that appears in such a line (A05). `fail_pattern` is required when `known_red` is
     not empty. The gate is required once any node is imported or pinned, or an `adoption` is present.
   - Top-level `out_of_scope: [{glob, reason}]`, each with a non-empty reason.
   - Top-level `adoption: {areas: [{name, globs}]}`: the areas still to map, each with a kebab-case `name` (not
     `scaffold` or `plan`, which A07 uses; unique among the areas) and a non-empty list of globs. `areas` may be empty:
     every area mapped, the plan still to come.
   - `nodes` may be an empty list.
   *A02-AC-1.*
3. **The checker** names each problem on its own line: an unknown status; an imported or pinned node without `owns`,
   with a track other than `done`, or (pinned) with an `unpinned` criterion; an `owns` glob missing from the spec's
   **Owns:** paragraph; one glob string listed by two nodes; a missing `gate` where it is required, or an empty
   `gate.command`; a missing or invalid `fail_pattern`; a malformed `known_red`, `out_of_scope` or `adoption` entry; a
   reserved or duplicate area name. It reads only
   the graph and the specs, never the repository's files (file-level ownership is A04's). *A02-AC-1.*
4. **Done means done, everywhere.**
   - `ready.py` never prints an imported or pinned node and counts it as merged for its dependants.
   - The node skill's precondition accepts a dep that is merged, imported or pinned.
   - Triage's `nodes.py` shows `imported` and `pinned`, and its rules treat them as done: work on their code is a new
     node depending on them, never a change to an imported or pinned node's criteria, Purpose or `owns` (its header
     row's Unlocks is kept in sync as for any node). In a graph with ownership the new node is placed: depending on the nodes whose files it changes and the nodes that own the folders where it will add files (test folders included), with `owns` only for added paths no existing glob matches.
   - The API's node state, `report.py`'s `merged_ids` and start clause, and the site (its explorer and its
     repositories card) show `imported` and `pinned` and count them as done.
   *A02-AC-4, A02-AC-5.*
5. **Nothing changes for a graph without the fields.** No `status` means `planned`; a graph with no new field gives the
   same output and exit code as before. *A02-AC-3.*

## Gate
- **A02-AC-1** — The valid adopted fixture, whose **Owns:** paragraphs wrap, reports `PROBLEMS 0`, and each problem of change 3 is named on its own line with exit 1. *Verify:* `sh plugin/skills/node/check-regime.test.sh`.
- **A02-AC-2** — `owns.py` matches `*`, `**`, a trailing `/`, a folder name and a literal path as change 1 says, and lists the regime's own files from the **Spec files:** line or the default. *Verify:* `sh plugin/skills/node/check-regime.test.sh`.
- **A02-AC-3** — The existing fixture cases give the same output and exit code as before this node, and this repository's graph, which has none of the new fields, reports `PROBLEMS 0` with exit 0. *Verify:* `sh plugin/skills/node/check-regime.test.sh` and `python3 -I plugin/skills/node/check-regime.py`.
- **A02-AC-4** — `ready.py` never prints an imported or pinned node and treats it as merged for its dependants; the API, `report.py`'s `merged_ids` and start clause, and the site's explorer and repositories card show the two states and count them as done. *Verify:* `sh scheduler/ready.test.sh`, `sh scheduler/api.test.sh`, `sh scheduler/report.test.sh`, `sh scheduler/site.test.sh` and `sh site/site.test.sh`.
- **A02-AC-5** — The node skill accepts an imported or pinned dep, and triage shows the two states, never amends such a node, and gives new nodes `owns` in a graph with ownership. *Verify:* `sh plugin/skills/node/skill.test.sh` and `sh plugin/skills/triage/nodes.test.sh`.

## Risks
- `owns.py`'s glob rules are this regime's own, not `.gitignore`'s or `fnmatch`'s; its tests pin them, and every
  ownership tool shares the one module so they cannot drift apart.
- An imported node is done by declaration: nothing checks that its code works. The gate and its `known_red` say how
  healthy the imported code is.
- Many places classify nodes; a reader this node misses would show imported nodes as remaining work. The tests cover
  the readers named here, and the reviewer looks for others.
