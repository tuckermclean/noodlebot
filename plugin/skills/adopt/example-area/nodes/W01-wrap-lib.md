# W01 — wrap-lib

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| done | none | W02 | S |

**Owns:** `lib/wrap.sh`

## Purpose

Imported from the code. `lib/wrap.sh` defines `wrap_line <width>`, which reads standard input and folds each
line at spaces so that the output line is as long as the words allow without passing the width. It is
a small awk program: words are appended to the current output line while the line stays within the width, and
a word that does not fit starts a new line. A word longer than the width is not split and stays on a line of
its own (the README lists this as a known gap).

## Tests

Existing, run by `make test` through `tests/run.sh`: `tests/t_basic.sh` (a short line is printed unchanged),
`tests/t_fold.sh` (a long line is folded at a space) and `tests/t_narrow.sh` (a word longer than the width is
split; it fails today and is listed in the graph's `known_red`).

## Changes

none: imported

## Gate

- **W01-AC-1** — A single-spaced line no longer than the width is printed unchanged. *Verify:* `sh tests/t_basic.sh` exits 0.
- **W01-AC-2** — A longer line is broken at a space, the first output line being the longest run of words that fits. *Verify:* `sh tests/t_fold.sh` exits 0.
- **W01-AC-3** — A word longer than the width is not split: it is printed whole on its own line. *Verify:* unpinned (`tests/t_narrow.sh` expects the opposite and fails; no test shows the current behaviour).
- **W01-AC-4** — Blank lines and runs of spaces: a blank input line prints one empty line and the spaces between words are collapsed to one. *Verify:* unpinned.

## Risks

- The width test counts characters as awk's `length` does, which depends on the locale for multibyte text.
- `tests/t_narrow.sh` asks for behaviour the code does not have, so a node that changes `lib/wrap.sh` will
  meet that known failure.
