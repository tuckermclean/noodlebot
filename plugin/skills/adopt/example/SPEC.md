# tallyho: specification

## 1. What this is

tallyho counts lines, words and bytes of text files and prints a table (`bin/tallyho FILE...`, or
standard input when no file is given). It is not a text-analysis suite: no stemming, no languages, no
network, no GUI. It stays POSIX sh with no dependencies beyond coreutils and awk.

Already built and tested, so not nodes: counting lines, words and bytes (`lib/count.sh`), the stdin
mode, and `tests/test_count.sh`. Everything on the README's "Planned" list is not started; the nodes
below build it.

## 2. Principles

1. POSIX sh only; every script runs under dash. No new runtime dependencies.
2. The default output (no options) of a text file does not change, byte for byte.
3. Every option gets a test in `tests/`.
4. Errors go to stderr. The exit status is non-zero only on unreadable input; a skipped file, a bad
   option value or a bad config line is a warning on stderr with exit status 0.
5. User files are data, never code: nothing a user supplies is sourced or evaluated.

## 3. Architecture

- `bin/tallyho`: argument handling and the loop over files.
- `lib/count.sh`: counting (`count_stream FILE`, `-` is stdin). New helpers go in `lib/`, one file
  per concern (binary detection, JSON output, word frequencies, config).
- `tests/test_<topic>.sh`: one POSIX sh test per topic; each exits non-zero on failure.
- CI: `.github/workflows/ci.yml` runs `make test`.

## 4. Node spec template

Every node spec `nodes/<ID>-<name>.md` has the title `# <ID> — <name>`, the header row
`| Track | Deps | Unlocks | Size |`, a line `**Owns:**` (the paths the node creates or changes), a line
`**Resolves:** #<n>` when the node is drafted from an issue, and these headings:

- `## Purpose`: why the node exists and what it builds on.
- `## Tests`: the test files the node adds and the red target (a command that exits non-zero before
  the node's change and 0 after).
- `## Changes`: numbered, each naming the criterion it produces (`*<ID>-AC-n.*`).
- `## Gate`: the criteria, one line each, `- **<ID>-AC-<n>** — <statement> *Verify:* <command>`,
  numbered from 1.
- `## Risks`.

A node's `deps` lists only what its Gate needs; a Verify that uses another node's change names that
node in `deps`.

## 5. Open decisions (defaults apply until the owner changes them)

- **D1. Total row.** The README promises "a total row"; the code prints none, and principle 2 forbids
  changing the default output. Default: the total appears in `--json` output only (node F01); the
  default table is unchanged and F01 corrects the README sentence. Owner's alternative: print a total
  row in the table when two or more files are given (breaks principle 2 for that case).
- **D2. JSON shape.** Default: JSON Lines on stdout, one object per file
  `{"file":"NAME","lines":N,"words":N,"bytes":N}`, then `{"total":{"lines":N,"words":N,"bytes":N}}`;
  the name is JSON-escaped; stdin is `"-"`. (node F01)
- **D3. What `--top` prints and what a word is.** Default: a word is a whitespace-separated token of
  `wc -w`, folded to lower case, punctuation kept; after each file's table row, up to N lines
  `<count> <word>`, most frequent first, ties alphabetical; with `--json` the object gains
  `"top":[{"word":"…","count":N}]`. (node F02)
- **D4. Bad option values.** Principle 4 allows a non-zero exit only on unreadable input. Default: a
  missing or non-numeric N for `--top` is a warning on stderr and the option is ignored, exit status
  0. Owner's alternative: exit 2, which needs principle 4 to be widened. (node F02)
- **D5. Binary detection.** Default: a file with a NUL byte in its first 8 KiB is binary; it is
  skipped with a warning on stderr naming the file, exit status 0, no row and no share in the total.
  Standard input is not checked, because it cannot be read twice. (node B01)
- **D6. Config file.** Default: `~/.tallyhorc` (under `$HOME`), `key=value` lines, never sourced;
  keys `json` (`1`) and `top` (a number); blank lines and `#` comments ignored; an unknown key, a bad
  line or an unreadable file is a warning on stderr and exit status 0; command-line flags override
  the file. (node F03)
- **D7. A test runner node.** `make test` runs only `tests/test_count.sh`, so new test files would not
  run in CI. Default: node T01 makes `make test` run every `tests/test_*.sh`. Each other node's
  Verify runs its own test file directly, so none of them depends on T01 to be checked, but their
  tests reach CI only once T01 is done.
- **D8. Unreadable input today.** The code exits 0 even when a file cannot be read (the status is
  that of the last `awk`), while principle 4 says non-zero on unreadable input. The answers do not ask
  for a fix, so no node changes it. Default: leave the exit status as it is; a node must not report
  an unreadable file as binary. Owner's alternative: add a node that exits non-zero on an unreadable
  file. (node B01 only touches it)

## 6. Conventions

- Branches: `node/<ID>-<name>` for a node, `spec/<topic>` for a spec change.
- Sizes: S under a day, M two or three days, L more.
- Order: T01, B01, F01 and F02 are `track: now` (binary files first, then `--json`, then `--top`);
  F03 is `track: later` and depends on the options it configures.
- A node is done when its Gate's criteria pass, `make test` passes locally and in CI, and the spec
  checker prints `PROBLEMS 0`.
