# tallyho: specification

## What this is

`tallyho` counts lines, words and bytes of text files and prints a tidy table: one row per file, and a
total row. With no file it reads standard input. It is a small command-line tool, not a text-analysis
suite.

**Already built and tested, so not nodes:** counting lines, words and bytes, and the stdin mode
(`bin/tallyho`, `lib/count.sh`, `tests/test_count.sh`). The total row the README describes is not
printed yet; it is built by the `--json` node.

## Principles

1. POSIX `sh`, runs under `dash`. No dependency beyond coreutils and `awk`. No new runtime dependency.
2. The default output format does not change, byte for byte.
3. Every option has a test in `tests/`, reached by `make test`.
4. Errors go to stderr; the exit status is non-zero only when an input is unreadable.
5. Non-goals: stemming, languages, network access, a GUI.

## Architecture

- `bin/tallyho`: the entry point; parses arguments and calls the library.
- `lib/count.sh`: the counting functions, sourced by `bin/tallyho`.
- `tests/test_*.sh`: one script per feature; `make test` runs them all; CI runs `make test`.

## Node spec template

Each node spec `nodes/<ID>-<name>.md` has these headings, in order: `## Purpose`, `## Tests`,
`## Changes`, `## Gate`, `## Risks`. The title is `# <ID> — <name>`, followed by a header row
`| Track | Deps | Unlocks | Size |`, a line `**Owns:**` and, for work that fixes an issue, a line
`**Resolves:** #<n>`. The Gate lists criteria `**<ID>-AC-<n>**`, numbered from 1, each testable with
*Verify:*.

## Open decisions (with defaults)

- **Configuration file format** (node T04): `key=value` lines, one per line; the file is read as data
  and never sourced as shell.
- **Binary detection** (node T01): a file is binary when a NUL byte occurs in its first 8 KiB.

## Conventions

- Branches: `node/<ID>-<name>` for a node, `spec/<topic>` for a spec change.
- Sizes: S under a day, M two or three days, L more.
- A node is done when its Gate criteria hold, `make test` passes and the PR is merged by the owner.
- The nodes' PRs, not the spec PR, fix the issues they list under **Resolves:**.
