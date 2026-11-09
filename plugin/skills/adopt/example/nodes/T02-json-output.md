# T02 — json-output

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | T04 | M |

**Owns:** `bin/tallyho`, `lib/count.sh`, `tests/test_json.sh`, `tests/test_total.sh`, `README.md`
**Resolves:** #1

## Purpose

Scripts need machine-readable output. `tallyho --json FILE...` prints one JSON object per file plus a
total. The README already says a total row is printed in the default table; the code does not print
it, so this node adds it (the owner's decision: follow the README).

## Tests

`tests/test_json.sh` and `tests/test_total.sh` run `bin/tallyho` on temporary files and compare the
output with the expected text. `make test` runs every `tests/test_*.sh`.

## Changes

- `bin/tallyho`: parse `--json`; accumulate totals across files.
- `lib/count.sh`: a JSON formatter with correct escaping of file names, written in `awk`.
- Default table: a total row after the file rows when more than one file is given.
- `README.md`: document `--json` and the total row.

## Gate

- **T02-AC-1** — `tallyho --json FILE...` prints one JSON object per file with `lines`, `words`, `bytes` and `name`, then one object for the total. *Verify:* `make test` runs `tests/test_json.sh`, which compares the exact text for two known files.
- **T02-AC-2** — File names with quotes or backslashes are escaped so the output is valid JSON. *Verify:* `make test` runs `tests/test_json.sh`, which checks the escaped form for a file named with a double quote.
- **T02-AC-3** — The default table prints a total row after the file rows when more than one file is given, and for one file the output is unchanged byte for byte. *Verify:* `make test` runs `tests/test_total.sh`, which compares both cases with the expected text.
- **T02-AC-4** — With no file, standard input is still read, with and without `--json`. *Verify:* `make test` runs `tests/test_json.sh`, which pipes text in.

## Risks

The total row changes the multi-file default output; the owner chose to follow the README, and a
single-file run stays byte for byte identical. The two nodes T01 and T02 both edit `bin/tallyho`: the
scheduler should build T01 first (priority) and rebase T02 on it.
