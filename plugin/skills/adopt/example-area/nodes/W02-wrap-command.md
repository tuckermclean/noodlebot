# W02 — wrap-command

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| done | W01 | none | S |

**Owns:** `bin/wrap`, `README.md`

## Purpose

Imported from the code. `bin/wrap [-w N] [file]` is the command: it loads `lib/wrap.sh` from the folder
above itself, takes the width from `-w N` (default 20), and folds the named file, or standard input when no
file is named, through `wrap_line`. `README.md` describes it, how to run the tests (`make test`) and the known
gap that a word longer than the width is not split. It relies on W01 for the folding.

## Tests

Existing: `tests/t_basic.sh` and `tests/t_fold.sh` run `bin/wrap` on standard input, with and without
`-w`. No test reads a file argument or passes an invalid width.

## Changes

none: imported

## Gate

- **W02-AC-1** — Without a file the command folds standard input at the default width of 20. *Verify:* `sh tests/t_basic.sh` exits 0.
- **W02-AC-2** — `-w N` sets the width. *Verify:* `sh tests/t_fold.sh` exits 0.
- **W02-AC-3** — A file named on the command line is folded instead of standard input. *Verify:* unpinned.
- **W02-AC-4** — The README names the command, its options and the known gap. *Verify:* unpinned.

## Risks

`-w` is read only as the first argument, and its value is not validated, so a non-number reaches awk
unchecked. The command has no usage message.
