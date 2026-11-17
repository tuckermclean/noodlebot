# A03 — inventory

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | A02 | A04, A06 | S |

**Owns:** `plugin/skills/adopt/inventory.py` (new), `plugin/skills/adopt/inventory.test.sh` (new) and its line in the
`Makefile`'s `TESTS`, the fixture repository under `plugin/skills/adopt/testdata/inventory/`.

## Purpose
After this node an adoption starts from a summary of the repository, not from reading all of it. A deterministic
script lists what is there (files, languages, sizes, entrypoints, tests, CI files, vendored and generated folders, and
the import links between files) and proposes how to split the code into areas small enough for one session each. An
adoption session reads that summary and then only the files of the area it maps, so a large repository no longer
overflows it. The script proposes; the owner and the sessions decide.

## Tests
- `plugin/skills/adopt/inventory.test.sh` (new): a fixture repository (made with `git init` in a temporary folder from
  `testdata/inventory/`) with a Python package, a JavaScript file, a shell script, a test folder, a CI workflow, a
  `vendor/` folder and a `node_modules/` folder, and a graph whose one node owns `src/core/`. Cases: the summary and
  `--json` (every tracked file with its language and line count; the three kinds of entrypoint; the tests; the CI file;
  the vendored folders listed as candidates, not as source); the three kinds of import link, and one that resolves to
  nothing kept with a null target; `--unowned`; `--areas` on the fixture and with a small `--max-lines`.

## Changes
1. **List.** `python3 -I plugin/skills/adopt/inventory.py <checkout> [--json] [--unowned] [--areas [--max-lines N]]`
   lists tracked files with `git ls-files` and reports each one's language (by extension, or by the interpreter its
   shebang names), its non-blank line count, entrypoints (a shebang, `if __name__ == "__main__"`, a package
   manifest's `main` or `bin`, an executable script), test files (`test_*`, `*_test.*`, `*.test.*`, files under
   `tests/`, `test/`, `spec/`, `testdata/`, `fixtures/`), CI files (`.github/workflows/*`, `.gitlab-ci.yml`,
   `Jenkinsfile`, `.circleci/`) and candidate out-of-scope folders (`vendor/`, `node_modules/`, `.venv/`, `dist/`,
   `build/`, generated files with a "generated" header line), each with its reason. *A03-AC-1.*
2. **Links.** Python `import` and `from … import`, JavaScript and TypeScript `import … from` and `require(`, and shell
   `source` and `. path`, resolved to tracked paths; a link that resolves to nothing keeps its raw text with a null
   target. *A03-AC-2.*
3. **Output.** By default a short summary (files and lines by language, the largest files, entrypoints, tests, CI,
   candidates); `--json` the same as one object with the keys `files`, `languages`, `entrypoints`, `tests`, `ci`,
   `candidates`, `links`, `unowned`, `areas`. *A03-AC-1.*
4. **`--unowned`** lists the tracked files that no node's `owns` (A02's matcher) and no `out_of_scope` glob covers,
   one per line, sorted; with no ownership in the graph it lists nothing. *A03-AC-3.*
5. **`--areas`** proposes areas: folders of source files (candidates and already-owned files left out), a folder over
   `--max-lines` (default 4000) split into its subfolders, small sibling folders merged, each area with a kebab-case
   name, a glob, its files and its lines, in an order where an area comes after the areas it imports from where
   possible. Every source file is in exactly one proposed area. *A03-AC-4.*

## Gate
- **A03-AC-1** — On the fixture, the summary and `--json` report every tracked file with its language and lines, the three kinds of entrypoint, the tests, the CI file, and the vendored folders as candidates with a reason. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.
- **A03-AC-2** — Import, require and source links carry their resolved path, and one that resolves to nothing keeps its raw text with a null target. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.
- **A03-AC-3** — `--unowned` lists exactly the tracked files no `owns` and no `out_of_scope` glob covers, and nothing for a graph without ownership. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.
- **A03-AC-4** — `--areas` puts every source file in exactly one area, none over `--max-lines` unless it is a single file, and leaves out candidates and owned files. *Verify:* `sh plugin/skills/adopt/inventory.test.sh`.

## Risks
- Best effort by design: dynamic imports, computed `require` names and shell globs are invisible. Links only inform
  the areas' order and the sessions' reading; deps in the graph stay the sessions' judgement.
- Language by extension misses some files; they are `other` unless a shebang names an interpreter.
- A submodule is one entry and is not descended; the session that maps its area says so.
- Area sizes are a heuristic: the owner can rename, merge or split the proposed areas in the answer A06 asks for.
