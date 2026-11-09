# F03 — config-file

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | F01, F02 | none | M |

**Owns:** `lib/config.sh`, `bin/tallyho`, `README.md`, `tests/test_config.sh`
**Resolves:** #4

## Purpose

Issue 4: default flags from `~/.tallyhorc`. The owner settled the format (`key=value`, never
sourced) and that the file waits until the options exist; this node's Verify lines use `--json` and
`--top`, so it depends on F01 and F02. Keys, the unknown-key and unreadable-file behaviour are open
decision D6.

## Tests

`tests/test_config.sh` sets `HOME` to a temporary directory holding a `.tallyhorc`. Red target:
`sh tests/test_config.sh`.

## Changes

1. `lib/config.sh`: `read_config FILE` parses `key=value` lines with `read` and `case`, never `.` or `eval`. *F03-AC-1.* *F03-AC-2.* *F03-AC-4.* *F03-AC-5.* *F03-AC-6.*
2. `bin/tallyho`: read `$HOME/.tallyhorc` before the arguments; flags override it. *F03-AC-1.* *F03-AC-2.* *F03-AC-3.* *F03-AC-7.*
3. `README.md`: document the file, keys and precedence. *F03-AC-8.*
4. `tests/test_config.sh`: the cases in the Gate. *F03-AC-1.* *F03-AC-2.* *F03-AC-3.* *F03-AC-4.* *F03-AC-5.* *F03-AC-6.* *F03-AC-7.* *F03-AC-8.*

## Gate

- **F03-AC-1** — `json=1` in the file makes `bin/tallyho FILE` print JSON. *Verify:* `sh tests/test_config.sh` exits 0; with `json=1` in `$HOME/.tallyhorc` the output equals that of `bin/tallyho --json FILE`.
- **F03-AC-2** — `top=N` in the file acts as `--top N`. *Verify:* `sh tests/test_config.sh` exits 0; with `top=2` the output equals that of `bin/tallyho --top 2 FILE`.
- **F03-AC-3** — A flag on the command line overrides the file. *Verify:* `sh tests/test_config.sh` exits 0; with `top=2` in the file, `bin/tallyho --top 1 FILE` prints one word line.
- **F03-AC-4** — The file is never sourced or evaluated. *Verify:* `sh tests/test_config.sh` exits 0; a line `top=1; touch "$HOME/x"` and a line `$(touch "$HOME/y")` leave neither `x` nor `y` behind.
- **F03-AC-5** — Blank lines and lines starting with `#` are ignored. *Verify:* `sh tests/test_config.sh` exits 0; a file of only comments gives the same output as no file.
- **F03-AC-6** — An unknown key or a malformed line is a warning on stderr; the other lines apply and the exit status is 0. *Verify:* `sh tests/test_config.sh` exits 0; `bogus=1` and `top=1` together give the one word line, a warning naming `bogus`, and status 0.
- **F03-AC-7** — A missing file changes nothing, and an unreadable one is a warning with exit status 0. *Verify:* `sh tests/test_config.sh` exits 0; with no file, or a file of mode 000 (skipped when run as root), the output equals that without a config.
- **F03-AC-8** — The README documents the file, its keys and the precedence. *Verify:* `grep -c tallyhorc README.md` is at least 1.

## Risks

Parsing with `read` strips backslashes unless `-r` is used; the test includes a value with a
backslash. D6 may change (more keys); the parser keeps one `case` branch per key.
