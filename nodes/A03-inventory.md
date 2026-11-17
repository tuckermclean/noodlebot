# A03 — inventory

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A02 | A06 | S |

**Owns:** `plugin/skills/adopt/inventory.py` (new), `plugin/skills/adopt/inventory.test.sh` (new) and its line in the
`Makefile`'s `TESTS`, the fixture repository under `plugin/skills/adopt/testdata/inventory/`.

## Purpose
After this node an adoption starts from a summary of the repository, not from reading all of it. A deterministic
script lists what is there (files, languages, sizes, entrypoints, tests, CI files, vendored and generated folders, and
the import links between files) and proposes how to split the repository into areas small enough for one session
each. An adoption session reads that summary and then only the files of the area it maps, so a large repository no
longer overflows it. The script proposes; the owner and the sessions decide.

## Tests
- `plugin/skills/adopt/inventory.test.sh` (new): a fixture repository (made with `git init` in a temporary folder from
  `testdata/inventory/`) with a Python package, a JavaScript file, a shell script, a test folder, a CI workflow, a
  README, an `AGENTS.md`, a `vendor/` and a `node_modules/` folder (created by the test at run time and added with
  `git add -f`, so no ignore file drops them), and a folder of flat files larger than a small `--max-lines`; once with
  a graph whose one node owns `src/core/`, once with no `docs/graph.yaml` at all. Cases: the summary and `--json`; the
  three kinds of import link, and one that resolves to nothing; `--unowned`; `--glob`; `--areas` with the default and
  with a small `--max-lines`, and the order of two areas where one imports from the other.

## Changes
1. **List.** `python3 -I plugin/skills/adopt/inventory.py <checkout> [--json] [--glob GLOB] [--unowned] [--areas
   [--max-lines N]]` lists tracked files with `git ls-files` and reports each one's language (by extension, or by the
   interpreter its shebang names), its non-blank line count, entrypoints (a shebang, `if __name__ == "__main__"`, a
   package manifest's `main` or `bin`, an executable script), test files (`test_*`, `*_test.*`, `*.test.*`, files
   under `tests/`, `test/`, `spec/`, `testdata/`, `fixtures/`), CI files (`.github/workflows/*`, `.gitlab-ci.yml`,
   `Jenkinsfile`, `.circleci/`) and candidate out-of-scope paths (`vendor/`, `node_modules/`, `.venv/`, `dist/`,
   `build/`, files with a "generated" header line), each with its reason. It imports A02's `owns.py` from
   `../node/`, putting that folder on `sys.path` itself (it runs under `python3 -I`). *A03-AC-1.*
2. **Links.** Python `import` and `from … import`, JavaScript and TypeScript `import … from` and `require(`, and shell
   `source` and `. path`, resolved to tracked paths; a link that resolves to nothing keeps its raw text with a null
   target. *A03-AC-2.*
3. **Output.** By default a short summary (files and lines by language, the largest files, entrypoints, tests, CI,
   candidates); `--json` the same as one object with the keys `files`, `languages`, `entrypoints`, `tests`, `ci`,
   `candidates`, `links`, `unowned`, `areas`. `--glob` limits every list to the files the glob matches (A02's
   matcher), for a session that maps one area. *A03-AC-1.*
4. **`--unowned`** lists the tracked files that no node's `owns` and no `out_of_scope` glob covers and that are not
   the regime's own files (A02's list), one per line, sorted; with no ownership in the graph, or no graph at all, it
   lists nothing. A missing `docs/graph.yaml` is a repository with no ownership, not an error. *A03-AC-3.*
5. **`--areas`** proposes areas covering every tracked file that is not a candidate, not already owned and not one of
   the regime's own files (code, tests, docs, CI and configuration alike), with or without a graph: one area per folder, a folder over `--max-lines` (default 4000) split into
   its subfolders, and a folder whose own files are over the limit split into groups of files; small sibling folders
   may be merged. Each area has a kebab-case name (never `scaffold` or `plan`), a list of globs, its files and its
   lines, in an order where an area comes after the areas it imports from where possible. *A03-AC-4.*

## Gate
- **A03-AC-1** — On the fixture, the summary and `--json` report every tracked file with its language and lines, the four kinds of entrypoint, the tests, the CI file and the vendored folders as candidates with a reason, and `--glob` limits them to one folder. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.
- **A03-AC-2** — Import, require and source links carry their resolved path, and one that resolves to nothing keeps its raw text with a null target. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.
- **A03-AC-3** — `--unowned` lists exactly the tracked files no `owns` and no `out_of_scope` glob covers, leaving out the regime's own files, and nothing for a graph without ownership or with no graph. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.
- **A03-AC-4** — `--areas`, with the graph and with none, puts every tracked file that is not a candidate, not owned and not a regime file in exactly one area, none over `--max-lines` unless it is a single file; the flat folder over the limit is split into groups of files, and an area comes after the area it imports from. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.

## Risks
- Best effort by design: dynamic imports, computed `require` names and shell globs are invisible. Links only inform
  the areas' order and the sessions' reading; deps in the graph stay the sessions' judgement.
- Language by extension misses some files; they are `other` unless a shebang names an interpreter.
- A submodule is one entry and is not descended; the session that maps its area says so.
- Area sizes are a heuristic: the owner can rename, merge or split the proposed areas in the answer A06 asks for.
