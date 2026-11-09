# F02 — top-words

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | F01 | F03 | M |

**Owns:** `lib/top.sh`, `lib/json.sh`, `bin/tallyho`, `README.md`, `tests/test_top.sh`
**Resolves:** #2

## Purpose

Issue 2: show the N most frequent words of each file, case-insensitive, ties alphabetical. Word,
format and bad-value handling are open decisions D3 and D4. It depends on F01 because its output
under `--json` extends F01's objects.

## Tests

`tests/test_top.sh` runs `bin/tallyho --top` on temporary files. Red target: `sh tests/test_top.sh`.

## Changes

1. `lib/top.sh`: `top_words FILE N` prints `<count> <word>` lines using `tr` to fold case and `LC_ALL=C sort`. *F02-AC-1.* *F02-AC-2.* *F02-AC-3.*
2. `bin/tallyho`: accept `--top N`; print the lines after the file's row; ignore a bad N with a warning. *F02-AC-1.* *F02-AC-5.* *F02-AC-6.*
3. `lib/json.sh`: add the `"top"` array to a file's object when `--top` is given. *F02-AC-4.*
4. `README.md`: document `--top N`. *F02-AC-7.*
5. `tests/test_top.sh`: the cases in the Gate. *F02-AC-1.* *F02-AC-2.* *F02-AC-3.* *F02-AC-4.* *F02-AC-5.* *F02-AC-6.* *F02-AC-7.*

## Gate

- **F02-AC-1** — `--top N FILE` prints the file's row, then up to N lines `<count> <word>`, most frequent first. *Verify:* `sh tests/test_top.sh` exits 0; for `a b a c a b` and N 2 it expects the lines `3 a` and `2 b` after the row.
- **F02-AC-2** — Words are case-insensitive and ties break alphabetically. *Verify:* `sh tests/test_top.sh` exits 0; for `B a b A c` and N 3 it expects `2 a`, `2 b`, `1 c` in that order.
- **F02-AC-3** — A file with fewer than N distinct words prints all of them, and an empty file prints none. *Verify:* `sh tests/test_top.sh` exits 0 on `x` with N 5 (one line) and on an empty file (no line).
- **F02-AC-4** — With `--json` the file's object gains `"top":[{"word":"…","count":N}]`. *Verify:* `sh tests/test_top.sh` exits 0; `bin/tallyho --json --top 1` on `a a b` expects `"top":[{"word":"a","count":2}]`.
- **F02-AC-5** — A missing or non-numeric N is a warning on stderr, the option is ignored and the exit status is 0. *Verify:* `sh tests/test_top.sh` exits 0; `bin/tallyho --top abc FILE` prints the plain row and exits 0.
- **F02-AC-6** — Without `--top` the output is unchanged. *Verify:* `sh tests/test_count.sh` exits 0.
- **F02-AC-7** — The README describes `--top N`. *Verify:* `grep -c -e '--top' README.md` is at least 1.

## Risks

Word boundaries differ between `wc -w` and `tr`; D3 pins them to whitespace. A file with very many
distinct words makes `sort | uniq -c` slow; acceptable for a small tool.
