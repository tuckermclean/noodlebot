# T04 — config-file

| Track | Deps | Unlocks | Size |
|---|---|---|---|
| later | T02, T03 | none | M |

**Owns:** `bin/tallyho`, `lib/config.sh`, `tests/test_config.sh`, `README.md`
**Resolves:** #4

## Purpose

Users set default flags in `~/.tallyhorc`. It waits for `--json` and `--top`, the options it
configures. The format is `key=value` lines, read as data and never sourced as shell (the default
decision in `SPEC.md`; the owner's answer settles issue #4's question).

## Tests

`tests/test_config.sh` sets `HOME` to a temporary directory holding a `.tallyhorc` and runs
`bin/tallyho`. `make test` runs every `tests/test_*.sh`.

## Changes

- `lib/config.sh`: read `key=value` lines (keys `json`, `top`), ignoring blank lines and `#` comments,
  without evaluating the file.
- `bin/tallyho`: apply the defaults before the command line, so flags given on the command line win.
- `README.md`: document the file.

## Gate

- **T04-AC-1** — `top=3` in `$HOME/.tallyhorc` acts as `--top 3`, and `json=1` as `--json`. *Verify:* `make test` runs `tests/test_config.sh`, which compares the output with and without the file.
- **T04-AC-2** — A flag on the command line overrides the file. *Verify:* `make test` runs `tests/test_config.sh`, which sets `top=3` in the file and passes `--top 1`.
- **T04-AC-3** — The file is never executed: a line such as `top=$(touch marker)` creates no marker file. *Verify:* `make test` runs `tests/test_config.sh`, which checks the marker is absent.
- **T04-AC-4** — With no file the behaviour is unchanged, and an unknown key is a warning on stderr, not an error. *Verify:* `make test` runs `tests/test_config.sh`, which checks both.

## Risks

Reading a file as data in POSIX sh needs `read -r` with `IFS` set, and quoting mistakes can turn data
into code; the executed-marker criterion guards this. If the owner prefers another format, this node's
decision must be reopened before it starts.
