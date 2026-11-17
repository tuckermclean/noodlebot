# A04 — coverage

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A03 | A05, A07 | S |

**Owns:** `plugin/skills/node/check-coverage.py` (new), `plugin/skills/node/check-coverage.test.sh` (new) and its line
in the `Makefile`'s `TESTS`, its fixtures under `plugin/skills/node/testdata/coverage/`.

## Purpose
After this node "the graph knows every part of the code" is a command, not a hope. A checker compares the files the
repository tracks with the graph's ownership: every file must belong to exactly one node, be left out on purpose with a
reason, or lie in an area an adoption has still to map. A file no node owns is context a session would have to find
by itself, which is what the regime exists to avoid. A graph that declares no ownership (noodlebot's own) passes
unchanged.

## Tests
- `plugin/skills/node/check-coverage.test.sh` (new), fixture repositories made with `git init` from
  `testdata/coverage/`: fully owned; one file no one owns; one file two nodes own through different globs (`src/*.py`
  and `src/x.py`); an imported node's glob that matches nothing; a planned node's glob that matches nothing yet; a
  file covered only by a pending adoption area; an `out_of_scope` entry; a graph with no ownership; `--ref` on a commit
  whose files differ from the working tree.

## Changes
1. **Compare.** `python3 -I plugin/skills/node/check-coverage.py [--root DIR] [--ref REV]` lists the tracked files
   (`git ls-files`, or `git ls-tree -r --name-only REV` with `--ref`) and matches each against every node's `owns`,
   the `out_of_scope` globs and the pending `adoption` areas, with A02's matcher. Nothing is skipped by name: vendored
   and generated folders are left out only through `out_of_scope`. *A04-AC-1.*
2. **Problems**, one per line, then `PROBLEMS <n>` and exit 1 when n > 0, in `check-regime.py`'s shape: a file no node
   owns that is neither out of scope nor in a pending area; a file two nodes own (both named, whatever their glob
   strings); a glob of an imported or pinned node, or of a merged planned node, that matches no file (a planned node
   not yet merged may name files it will create). *A04-AC-2.*
3. **No ownership, no problem.** A graph with no `owns`, `out_of_scope` or `adoption` prints `no ownership declared`
   and `PROBLEMS 0`. *A04-AC-3.*

## Gate
- **A04-AC-1** — A fully owned fixture, one with out-of-scope files and one with pending areas report `PROBLEMS 0`, and `--ref` judges that commit's files. *Verify:* `sh plugin/skills/node/check-coverage.test.sh`.
- **A04-AC-2** — An unowned file, a file two nodes own through different globs, and an imported node's glob matching nothing are each named on their own line with exit 1; a planned unmerged node's glob matching nothing is not a problem. *Verify:* `sh plugin/skills/node/check-coverage.test.sh`.
- **A04-AC-3** — A graph without ownership prints `no ownership declared` and `PROBLEMS 0`, and this repository's graph passes. *Verify:* `sh plugin/skills/node/check-coverage.test.sh` and `python3 -I plugin/skills/node/check-coverage.py`.

## Risks
- Coverage proves the claims are complete, not that a session respects them: A05 checks each node's diff.
- A large repository has many files; the check is one `git ls-files` and in-memory matching, and its test pins the
  cost on the fixtures.
- "Merged" for a planned node comes from the same sources `ready.py` uses (the PR list and `origin/main`'s subjects);
  where the checker runs without them (a session's worktree), it reads the subjects of `git log` only.
