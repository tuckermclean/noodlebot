# T01 — skip-binary-files

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | none | S |

**Owns:** `lib/count.sh`, `bin/tallyho`, `tests/test_binary.sh`, `Makefile`
**Resolves:** #3

## Purpose

Running `tallyho` on a PNG prints nonsense word counts. A binary file must be skipped with a warning
on stderr. A file is binary when a NUL byte occurs in its first 8 KiB (the default decision in
`SPEC.md`). Text files, and standard input, behave as before.

## Tests

`tests/test_binary.sh` builds a text file and a binary file (with `printf '\0'`) in a temporary
directory and runs `bin/tallyho` on them. The `Makefile`'s `test` target runs every `tests/test_*.sh`.

## Changes

- `lib/count.sh`: a function that tells whether a file is binary; `count_stream` skips a binary file
  and writes `tallyho: skipping binary file: <name>` to stderr.
- `Makefile`: `make test` runs all `tests/test_*.sh`, not only `test_count.sh`.

## Gate

- **T01-AC-1** — A file with a NUL byte in its first 8 KiB prints no row on stdout and one warning line naming the file on stderr. *Verify:* `make test` runs `tests/test_binary.sh`, which checks stdout has no row for the binary file and stderr contains its name.
- **T01-AC-2** — A text file next to a binary file is still counted, and the exit status is 0. *Verify:* `make test` runs `tests/test_binary.sh`, which checks the text file's row and the exit status.
- **T01-AC-3** — The output for text files is unchanged byte for byte. *Verify:* `make test` still passes `tests/test_count.sh` unmodified.
- **T01-AC-4** — `make test` runs every `tests/test_*.sh`. *Verify:* `make test` prints the `PASS` lines of both `tests/test_count.sh` and `tests/test_binary.sh`.

## Risks

A NUL byte after the first 8 KiB is not detected; that is the accepted default. Portable detection
without non-POSIX tools needs care (`head -c` is not POSIX; use `dd` and `tr`).
