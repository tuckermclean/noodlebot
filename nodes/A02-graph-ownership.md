# A02 — graph-ownership

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | A03, A08 | M |

**Owns:** `plugin/skills/node/owns.py` (new: the one glob matcher every ownership tool uses),
`plugin/skills/node/check-regime.py` (the new fields), `plugin/skills/node/check-regime.test.sh` and its fixtures under
`plugin/skills/node/testdata/regime/`; in `scheduler/ready.py`, imported and pinned nodes as done, with their cases in
`scheduler/ready.test.sh`; the node states `imported` and `pinned` in `scheduler/api.py`, its node schema under
`scheduler/api-schema/`, `scheduler/report.py` and `scheduler/site.py`, with their cases in the existing API, report and
site tests.

## Purpose
After this node `docs/graph.yaml` can describe a repository's existing code, not only the work still to build. A node
says whether it is work to build (`planned`), code that already exists (`imported`) or existing code whose behaviour
tests pin (`pinned`), and names the files it owns. The graph names the repository's test command and the failures it
already has, the paths it leaves out on purpose, and the areas an adoption has still to map. The checker validates
all of it, and the scheduler treats imported and pinned nodes as done. noodlebot's own graph, which uses none of the
new fields, is checked and scheduled exactly as before.

## Tests
- `plugin/skills/node/check-regime.test.sh` (extended), fixtures under `plugin/skills/node/testdata/regime/`: one valid
  adopted graph (a `gate` with `known_red`, imported, pinned and planned nodes with `owns`, an `out_of_scope` entry, an
  `adoption` with two areas) and one fixture per problem of change 3, each asserting its line and exit 1; this
  repository's graph (the same output as before this node, `PROBLEMS 0`).
- `owns.py`'s matching, in the same test: `*`, `**` at the start, middle and end, a trailing `/`, a literal path, and
  a glob with no wildcard that names a folder.
- `scheduler/ready.test.sh` (extended): an imported and a pinned node are never printed, with or without markers, and
  a planned node whose deps are imported or pinned is ready.
- The existing API, report and site tests (extended): an imported and a pinned node show their own state and are
  counted as done, not as waiting or ready.

## Changes
1. **One matcher.** `plugin/skills/node/owns.py` matches root-relative paths against `owns:` globs: `*` matches within
   one path component, `**` matches zero or more components, a trailing `/` (or a glob naming a folder) means the
   folder and everything under it. Every ownership check (A04, A05, A03's `--unowned`) uses it. *A02-AC-2.*
2. **The fields.**
   - A node may have `status` (`planned` by default, `imported` or `pinned`) and `owns` (a list of globs).
   - An imported or pinned node needs a non-empty `owns`, has `track: done` (its header row says `done`), and each of
     its criteria's *Verify* either names the test that shows it or reads `unpinned` followed by how it could be
     shown. A pinned node has no `unpinned` criterion.
   - A node with `owns` names each of its globs in backticks on its spec's **Owns:** line.
   - Top-level `gate: {command, known_red}`: `command` a non-empty string run from the repository root;
     `known_red` a list of strings naming the failures the command already had. It is required once any node is
     imported or pinned, or an `adoption` is present.
   - Top-level `out_of_scope: [{glob, reason}]`, each with a non-empty reason.
   - Top-level `adoption: {areas: [{name, glob}]}`: the areas still to map, each with a kebab-case `name` and a glob.
   *A02-AC-1, A02-AC-3.*
3. **The checker** names each problem on its own line: an unknown status; an imported or pinned node without `owns`,
   with a track other than `done`, or (pinned) with an `unpinned` criterion; an `owns` glob missing from the spec's
   **Owns:** line; one glob string listed by two nodes; a missing `gate` where it is required, or an empty
   `gate.command`; a malformed `known_red`, `out_of_scope` or `adoption` entry. It reads only the graph and the specs,
   never the repository's files (file-level overlap and coverage are A04's). *A02-AC-1.*
4. **Done means done.** `ready.py` never prints an imported or pinned node and counts it as merged for its dependants.
   The API's node state, the status issue and the status site show `imported` and `pinned` and count them as done.
   *A02-AC-4.*
5. **Nothing changes for a graph without the fields.** No `status` is `planned`; a graph with no new field gives the
   same output and exit code as before. *A02-AC-3.*

## Gate
- **A02-AC-1** — The valid adopted fixture reports `PROBLEMS 0`, and each problem of change 3 is named on its own line with exit 1. *Verify:* `sh plugin/skills/node/check-regime.test.sh`.
- **A02-AC-2** — `owns.py` matches `*`, `**`, a trailing `/`, a folder name and a literal path as change 1 says. *Verify:* `sh plugin/skills/node/check-regime.test.sh`.
- **A02-AC-3** — This repository's graph, which has none of the new fields, gives the same checker output and exit code as before this node. *Verify:* `sh plugin/skills/node/check-regime.test.sh` and `python3 -I plugin/skills/node/check-regime.py`.
- **A02-AC-4** — `ready.py` never prints an imported or pinned node and treats it as merged for its dependants; the API, the status issue and the site show the two states and count them as done. *Verify:* `sh scheduler/ready.test.sh` and the extended API, report and site tests.

## Risks
- `owns.py`'s glob rules are this regime's own, not `.gitignore`'s or `fnmatch`'s; its tests pin them, and every
  ownership tool shares the one module so they cannot drift apart.
- `known_red` names failures as the gate command prints them; a command whose failure names change from run to run
  (random order, timestamps) needs the names A06 chose to stay stable. The checker checks only the list's shape.
- An imported node is done by declaration: nothing checks that its code works. The gate and its `known_red` are what
  say how healthy the imported code is.
