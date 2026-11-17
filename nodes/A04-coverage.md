# A04 — coverage

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A02 | A05, A06, A07 | S |

**Owns:** `plugin/skills/node/check-coverage.py` (new), `plugin/skills/node/check-coverage.test.sh` (new) and its line
in the `Makefile`'s `TESTS`, its fixtures under `plugin/skills/node/testdata/coverage/`.

## Purpose
After this node "the graph knows every part of the code" is a command, not a hope. A checker compares the files the
repository tracks with the graph's ownership: every file must belong to exactly one node, be left out on purpose with a
reason, lie in an area an adoption has still to map, or be one of the regime's own files. A file no node owns is
context a session would have to find by itself, which is what the regime exists to avoid. A graph that declares no
ownership (noodlebot's own) passes unchanged.

## Tests
- `plugin/skills/node/check-coverage.test.sh` (new), fixture repositories made with `git init` from
  `testdata/coverage/`: fully owned; one file no one owns; one file two nodes own through different globs (`src/*.py`
  and `src/x.py`); an imported node's glob that matches nothing; a planned node's glob that matches nothing, before and
  after a commit whose subject marks it merged; a file covered only by a pending adoption area; an `out_of_scope`
  entry; the regime files (`SPEC.md`, `AGENTS.md`, `docs/graph.yaml`, `nodes/*.md`, `.noodlebot/roles.yaml`) owned by
  no node; a **Spec files:** line naming a further file; a graph with no ownership; `--ref` on a commit whose files and
  graph differ from the working tree.

## Changes
1. **Compare.** `python3 -I plugin/skills/node/check-coverage.py [--root DIR] [--ref REV]` reads the graph and lists
   the tracked files at the working tree (`git ls-files`), or both at `REV` with `--ref` (`git show REV:docs/graph.yaml`,
   `git ls-tree -r --name-only REV`), and matches each file against every node's `owns`, the `out_of_scope` globs and
   the pending `adoption` areas' globs, with A02's matcher. *A04-AC-1.*
2. **The regime's own files are exempt:** the repository's spec files as `check-spec-diff.py` reads them (the
   **Spec files:** line of `AGENTS.md`, else `SPEC.md`, `docs/graph.yaml` and `nodes/`), plus `AGENTS.md` and
   `.noodlebot/roles.yaml`. Nothing else is skipped by name: vendored and generated folders are left out only through
   `out_of_scope`. *A04-AC-1.*
3. **Problems**, one per line, then `PROBLEMS <n>` and exit 1 when n > 0, in `check-regime.py`'s shape: a file no node
   owns that is neither exempt, out of scope nor in a pending area; a file two nodes own (both named, whatever their
   glob strings); a glob of an imported or pinned node, or of a merged planned node, that matches no file. A planned
   node counts as merged when a line of `git log --format=%s` at the judged commit starts with `<ID> <name>:` (its
   squash subject); one not merged may name files it will create. *A04-AC-2.*
4. **No ownership, no problem.** A graph with no `owns`, `out_of_scope` or `adoption` prints `no ownership declared`
   and `PROBLEMS 0`. *A04-AC-3.*

## Gate
- **A04-AC-1** — A fully owned fixture, one with out-of-scope files, one with pending areas and one whose regime files no node owns report `PROBLEMS 0`, and `--ref` judges that commit's graph and files. *Verify:* `sh plugin/skills/node/check-coverage.test.sh`.
- **A04-AC-2** — An unowned file, a file two nodes own through different globs, an imported node's glob matching nothing and a merged planned node's glob matching nothing are each named on their own line with exit 1; an unmerged planned node's glob matching nothing is not a problem. *Verify:* `sh plugin/skills/node/check-coverage.test.sh`.
- **A04-AC-3** — A graph without ownership prints `no ownership declared` and `PROBLEMS 0`, and this repository's graph passes. *Verify:* `sh plugin/skills/node/check-coverage.test.sh` and `python3 -I plugin/skills/node/check-coverage.py`.

## Risks
- Coverage proves the claims are complete, not that a session respects them: A05 checks each node's diff.
- A large repository has many files; the check is one file listing and in-memory matching, and its test pins the cost
  on the fixtures.
- "Merged" from squash subjects relies on the regime's convention (SPEC §5); a planned node merged some other way
  shows as unmerged, which only relaxes the "matches nothing" check for it.
