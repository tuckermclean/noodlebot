# F01 — json-output

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| now | none | F02, F03 | M |

**Owns:** `lib/json.sh`, `bin/tallyho`, `README.md`, `tests/test_json.sh`
**Resolves:** #1

## Purpose

Issue 1: scripts need machine-readable output. `--json` prints JSON Lines (open decision D2): one
object per file, then a total. This also settles the README's "total row" (open decision D1): the
total exists in `--json` output, the default table stays unchanged, and the README sentence is
corrected. The counting this builds on is done and tested.

## Tests

`tests/test_json.sh` runs `bin/tallyho --json` on temporary files and compares the output with
fixed strings. Red target: `sh tests/test_json.sh`.

## Changes

1. `lib/json.sh`: `json_row NAME LINES WORDS BYTES` and `json_total LINES WORDS BYTES`, with JSON escaping of `"`, `\` and control characters. *F01-AC-1.* *F01-AC-2.* *F01-AC-3.*
2. `bin/tallyho`: accept `--json`, sum the counts, print the objects instead of the table; `-` for stdin. *F01-AC-1.* *F01-AC-2.* *F01-AC-4.* *F01-AC-5.*
3. `README.md`: document `--json`; say that the total row is part of `--json` output. *F01-AC-6.*
4. `tests/test_json.sh`: the cases in the Gate. *F01-AC-1.* *F01-AC-2.* *F01-AC-3.* *F01-AC-4.* *F01-AC-5.* *F01-AC-6.*

## Gate

- **F01-AC-1** — `--json FILE` prints one object per file with the keys `file`, `lines`, `words`, `bytes`. *Verify:* `sh tests/test_json.sh` exits 0; for a file holding `a b\nc\n` it expects `{"file":"<path>","lines":2,"words":3,"bytes":6}`.
- **F01-AC-2** — The last line is the total object over all files, and no total appears elsewhere. *Verify:* `sh tests/test_json.sh` exits 0; for two files it expects the last line `{"total":{"lines":…,"words":…,"bytes":…}}` with the sums, as the only line starting `{"total"`.
- **F01-AC-3** — File names are JSON-escaped. *Verify:* `sh tests/test_json.sh` exits 0; a file named `a"b\c` yields `"file":"a\"b\\c"`.
- **F01-AC-4** — Standard input with `--json` is named `-`. *Verify:* `sh tests/test_json.sh` exits 0; `printf 'a\n' | bin/tallyho --json` expects `"file":"-"`.
- **F01-AC-5** — Without `--json` the output is unchanged: one row per file, no total row. *Verify:* `sh tests/test_count.sh` exits 0, and `sh tests/test_json.sh` expects `bin/tallyho FILE FILE` to print exactly two lines.
- **F01-AC-6** — The README describes `--json` and no longer promises a table total row. *Verify:* `grep -c -e '--json' README.md` is at least 1 and `grep -c 'and a total row' README.md` prints 0.

## Risks

Open decision D1 may be reversed by the owner (a total row in the table); then AC-5 and AC-6
change. Escaping every control character in POSIX sh and awk is fiddly; the test covers quote,
backslash and tab only.
